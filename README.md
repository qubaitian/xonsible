# xonsible

Run blocks of [xonsh](https://xon.sh) code on remote hosts over ssh.

```xonsh
xontrib load xonsible

with! on("myserver", pkg="nginx") as b:
    apt install -y @(pkg)
    systemctl enable --now @(pkg)
    ret($(systemctl is-active @(pkg)).strip())

print(b.result)   # 'active'
```

The body of a `with!` block is **not executed locally**. xonsh hands its source
text to `on`, which sends it over ssh and runs it with the remote xonsh. The
remote side is plain xonsh, so you can use subprocess syntax, Python, and
whatever the remote `~/.xonshrc` sets up.

## Install

xonsible has to go into the Python that runs your xonsh. Install it with
xonsh's `xpip`, not plain `pip`:

```bash
git clone https://github.com/qubaitian/xonsible.git
xonsh -c 'xpip install -e ./xonsible'
```

A plain `pip` or `pip3` usually points at a different Python (Homebrew,
system), so `import xonsible` still fails inside xonsh afterwards. This is
always the case with the independent (mamba) installer, which ships its own
Python.

The remote host needs xonsh too. `bootstrap` installs it with the official
[independent (mamba) installer](https://xon.sh/install_mamba.html), using
only bash and curl:

```xonsh
bootstrap("myserver")                 # skipped if already installed
```

## Hosts

Hosts are plain ssh destinations. Put user, port, and key in `~/.ssh/config`
so scripts stay short:

```
Host myserver
    HostName qubaitian.duckdns.org
    User root
```

## Passing data in and out

- **In:** keyword arguments to `on(...)` become variables in the remote block.
  They are sent as JSON, so use str / int / float / bool / None / list / dict.
  Local variables are *not* visible remotely; pass what you need.
- **Out:** call `ret(value)` in the block (JSON-serializable; the last call
  wins). Read it from `b.result`. Full details are in `b.results[host]`:
  `.returncode`, `.stdout`, `.stderr`, `.ok`.

## Many hosts

```xonsh
with! on(["web1", "web2", "web3"]) as b:
    ret($(uptime).strip())

b.result    # {"web1": "...", "web2": "...", "web3": "..."}
```

Hosts run in parallel (`parallel=16` by default), and each output line is
prefixed with `[host]`.

## Errors

Inside the block, `$XONSH_SUBPROC_CMD_RAISE_ERROR = True` is set, so the first
failing command stops the block. If any host exits non-zero, `on` raises
`RemoteError`, and `e.failures` maps host to `Result`. Pass `check=False` to
collect failures in `b.results` instead.

## Options

| option | default | |
|---|---|---|
| `sudo` | `False` | run the remote xonsh via `sudo -n` |
| `rc` | `True` | load the remote xonshrc (`False` → `--no-rc`) |
| `quiet` | `False` | don't stream remote output (still kept in `Result`) |
| `check` | `True` | raise `RemoteError` on failure |
| `parallel` | `16` | max concurrent hosts |
| `xonsh` | `$HOME/.local/xonsh-env/xbin/xonsh` | remote xonsh path |
| `ssh_opts` | connection reuse (ControlMaster, 60 s) | extra ssh args |

Defaults live in `xonsible.config`, so you can change them once per script.
For example, `xonsible.config["xonsh"] = "/usr/bin/xonsh"`.

The remote xonsh path is absolute because a non-interactive ssh session does
not read `~/.zshrc` or `~/.bashrc`, so `xonsh` is usually not on its `$PATH`.

## How it works

1. `with!` captures the block source (`__xonsh_block__ = str`).
2. A short prelude is put in front of it. The prelude sets the vars, turns on
   raise-on-error, and defines `ret`.
3. `ssh host sh -c '…'` writes the script to a remote temp file, runs xonsh on
   it with stdin as `/dev/null`, then deletes the file. Because of this, a
   remote command that reads stdin can't swallow the script.
4. Remote stdout and stderr are streamed back live. `ret()` values arrive on a
   marked stdout line, which is filtered out of the visible output.

Tracebacks from the remote side show line numbers that are 6 lines higher
than in your block, because the prelude comes first.

## Not (yet) Ansible

This tool gives you no idempotency. Running a block twice runs it twice, so
write guards yourself, for example `if not p"/etc/foo".exists(): ...`.
There is no inventory, facts, dry-run, or file-transfer module. The design
keeps the remote side "just xonsh", so add these as small helper functions in
the remote environment as you need them.

## Test

```bash
xonsh tests/e2e_localhost.xsh   # needs `ssh localhost` to work
```
