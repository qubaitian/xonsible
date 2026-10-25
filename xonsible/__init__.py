"""xonsible: run blocks of xonsh code on remote hosts over ssh.

    from xonsible import on

    with! on("myserver", pkg="nginx"):
        apt install -y @(pkg)
        ret($(systemctl is-active @(pkg)).strip())

The body of a ``with!`` block is never executed locally: xonsh hands its
source text to ``on``, which ships it over ssh and runs it with the remote
xonsh.  Only the keyword arguments given to ``on`` travel with it (as JSON),
and the value passed to ``ret()`` comes back as ``block.result``.
"""

import json
import os
import shlex
import subprocess
import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor

__version__ = "0.1.0"
__all__ = ["on", "run", "bootstrap", "RemoteError", "Result", "config"]

config = {
    # Where the remote xonsh lives.  Non-interactive ssh does not read
    # ~/.zshrc / ~/.bashrc, so a bare "xonsh" is usually not on $PATH there.
    "xonsh": "$HOME/.local/xonsh-env/xbin/xonsh",
    # Reuse one ssh connection per host for a minute: consecutive blocks
    # skip the handshake.
    "ssh_opts": [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/xonsible-%C",
        "-o", "ControlPersist=60",
    ],
    "ssh": "ssh",
}

# Remote stdout lines starting with this carry the ret() value back.
_MARK = "\x1exonsible-ret:"

_PRELUDE = """\
import json as _xonsible_json
$XONSH_SUBPROC_CMD_RAISE_ERROR = True
globals().update(_xonsible_json.loads({vars!r}))
def ret(value, _dumps=_xonsible_json.dumps):
    print({mark!r} + _dumps(value), flush=True)
del _xonsible_json
"""


class RemoteError(Exception):
    """One or more hosts exited non-zero."""

    def __init__(self, failures):
        self.failures = failures  # {host: Result}
        lines = [f"{h}: exit {r.returncode}" for h, r in failures.items()]
        super().__init__("remote block failed on " + ", ".join(lines))


class Result:
    def __init__(self, host, returncode, value, stdout, stderr):
        self.host = host
        self.returncode = returncode
        self.value = value
        self.stdout = stdout
        self.stderr = stderr

    @property
    def ok(self):
        return self.returncode == 0

    def __repr__(self):
        return f"Result(host={self.host!r}, returncode={self.returncode}, value={self.value!r})"


def _remote_command(xonsh, sudo, rc):
    """Shell command run by ssh: save the script to a temp file, run it, clean up.

    The script goes through a file rather than straight into xonsh's stdin so
    that remote commands which read stdin cannot swallow the rest of it.
    """
    runner = xonsh if rc else f"{xonsh} --no-rc"
    if sudo:
        runner = f"sudo -n {runner}"
    inner = (
        'f=$(mktemp /tmp/xonsible.XXXXXX) || exit 1; '
        'cat > "$f"; '
        f'{runner} "$f" </dev/null; '
        'rc=$?; rm -f "$f"; exit $rc'
    )
    return "sh -c " + shlex.quote(inner)


def _pump(stream, sink, prefix, keep, on_mark=None):
    for line in iter(stream.readline, ""):
        if on_mark is not None and line.startswith(_MARK):
            on_mark(line[len(_MARK):])
            continue
        keep.append(line)
        if sink is not None:
            sink.write(prefix + line)
            sink.flush()
    stream.close()


def run(host, code, *, vars=None, sudo=False, rc=True, quiet=False,
        prefix="", xonsh=None, ssh_opts=None):
    """Run xonsh source ``code`` on ``host`` and return a :class:`Result`.

    Output is streamed to the local terminal as it arrives unless ``quiet``.
    Does not raise on failure; check ``Result.ok``.
    """
    script = _PRELUDE.format(vars=json.dumps(vars or {}), mark=_MARK) + code
    cmd = [config["ssh"], *(config["ssh_opts"] if ssh_opts is None else ssh_opts),
           host, _remote_command(xonsh or config["xonsh"], sudo, rc)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, bufsize=1)
    out, err, value = [], [], [None]

    def got(payload):
        value[0] = json.loads(payload)

    threads = [
        threading.Thread(target=_pump, args=(proc.stdout, None if quiet else sys.stdout, prefix, out, got)),
        threading.Thread(target=_pump, args=(proc.stderr, None if quiet else sys.stderr, prefix, err)),
    ]
    for t in threads:
        t.start()
    proc.stdin.write(script)
    proc.stdin.close()
    proc.wait()
    for t in threads:
        t.join()
    return Result(host, proc.returncode, value[0], "".join(out), "".join(err))


class on:
    """Context-manager macro: ``with! on(host_or_hosts, **vars) as b:``.

    One host -> ``b.result`` is the ``ret()`` value, ``b.results`` maps host to
    :class:`Result`.  Several hosts run in parallel, output lines are prefixed
    with ``[host]``, and ``b.result`` is ``{host: value}``.

    Raises :class:`RemoteError` if any host fails (unless ``check=False``).
    """

    __xonsh_block__ = str

    def __init__(self, hosts, *, sudo=False, rc=True, quiet=False, check=True,
                 parallel=16, xonsh=None, ssh_opts=None, **vars):
        self.hosts = [hosts] if isinstance(hosts, str) else list(hosts)
        self.vars = vars
        self.check = check
        self.parallel = parallel
        self.opts = dict(sudo=sudo, rc=rc, quiet=quiet, xonsh=xonsh, ssh_opts=ssh_opts)
        self.result = None
        self.results = {}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type is not None:
            return False
        code = getattr(self, "macro_block", None)
        if code is None:
            raise TypeError("use `with! on(...)` (with the !), not plain `with`")
        multi = len(self.hosts) > 1

        def one(host):
            return run(host, code, vars=self.vars, prefix=f"[{host}] " if multi else "", **self.opts)

        if multi:
            with ThreadPoolExecutor(max_workers=self.parallel) as pool:
                results = list(pool.map(one, self.hosts))
        else:
            results = [one(self.hosts[0])]
        self.results = {r.host: r for r in results}
        self.result = {r.host: r.value for r in results} if multi else results[0].value
        failures = {r.host: r for r in results if not r.ok}
        if failures and self.check:
            raise RemoteError(failures)
        return False


_INSTALL_URL = "https://xon.sh/install/mamba-install-xonsh.sh"


def bootstrap(host, *, python="3.11", xonsh_spec="xonsh[full]",
              target="$HOME/.local/xonsh-env", pip_install="", force=False,
              ssh_opts=None):
    """Install xonsh on ``host`` with the official independent (mamba) installer.

    Uses plain sh over ssh, so the host only needs bash and curl.  Skips the
    install if xonsh is already there unless ``force``.
    """
    env = {
        "TARGET_DIR": target,
        "PYTHON_VER": python,
        "XONSH_VER": xonsh_spec,
    }
    if pip_install:
        env["PIP_INSTALL"] = pip_install
    # TARGET_DIR is left unquoted-able ($HOME must expand remotely).
    assigns = " ".join(
        f'{k}="{v}"' if k == "TARGET_DIR" else f"{k}={shlex.quote(v)}"
        for k, v in env.items()
    )
    install = f'{assigns} /bin/bash -c "$(curl -fsSL {_INSTALL_URL})"'
    xbin = f'{target}/xbin/xonsh'
    if not force:
        install = f'if [ -x "{xbin}" ]; then echo "xonsh already installed: $({xbin} --version)"; else {install}; fi'
    cmd = [config["ssh"], *(config["ssh_opts"] if ssh_opts is None else ssh_opts),
           host, "sh -c " + shlex.quote(install)]
    return subprocess.run(cmd).returncode == 0
