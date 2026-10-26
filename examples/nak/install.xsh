#!/usr/bin/env xonsh
# Install nak (https://github.com/fiatjaf/nak), the nostr army knife, on this
# machine, by running the block over `ssh localhost`.
#
#   xonsh examples/nak/install.xsh              # this machine
#   xonsh examples/nak/install.xsh web1 web2    # any ssh hosts instead
#
# Safe to re-run: the binary is only downloaded when the installed one does not
# match the pinned release's checksum. Goes to ~/.local/bin/nak, no sudo.

import sys
from xonsible import on

HOSTS = sys.argv[1:] or ["localhost"]
VERSION = "v0.21.2"
# sha256 of each release asset, from the GitHub release's asset digests
SHA256 = {
    "darwin-arm64": "405cda08f961e00f29abcd151ed230a1505a87045b3ddaed1649c5e58db109ea",
    "darwin-amd64": "c1c957f8123f7aa24da1665ddada578c9636cd8e2dfde648306bea6a0eb78ad0",
    "linux-amd64":  "0acd56fea6ab1b9a0a68c8615670c6f8eff9e8878922442e387b94ee15266bb8",
    "linux-arm64":  "faab5bc77c5dd61bafb18b476ac410d266921c4765cc1faf42cbfaa3c7103b07",
}

with! on(HOSTS, version=VERSION, sha256=SHA256) as b:
    import hashlib, os, platform, tempfile
    from pathlib import Path

    system = platform.system().lower()
    machine = {"x86_64": "amd64", "aarch64": "arm64"}.get(platform.machine(), platform.machine())
    target = f"{system}-{machine}"
    if target not in sha256:
        raise SystemExit(f"no pinned nak build for {target}")
    want = sha256[target]

    def digest(p):
        return hashlib.sha256(p.read_bytes()).hexdigest()

    bindir = Path.home() / ".local/bin"
    dest = bindir / "nak"
    changed = False
    if not (dest.exists() and digest(dest) == want):
        print("installing nak", version, "for", target)
        bindir.mkdir(parents=True, exist_ok=True)
        # download next to dest, then rename: the swap is atomic
        fd, tmp = tempfile.mkstemp(dir=bindir, prefix=".nak-")
        os.close(fd)
        tmp = Path(tmp)
        try:
            curl -fsSL -o @(str(tmp)) @(f"https://github.com/fiatjaf/nak/releases/download/{version}/nak-{version}-{target}")
            got = digest(tmp)
            if got != want:
                raise SystemExit(f"checksum mismatch: {got} != {want}")
            tmp.chmod(0o755)
            tmp.replace(dest)
        finally:
            tmp.unlink(missing_ok=True)
        changed = True

    on_path = str(bindir) in os.environ.get("PATH", "").split(os.pathsep)
    ret({"changed": changed, "path": str(dest), "on_path": on_path,
         "version": $(@(str(dest)) --version).strip()})

results = b.result if len(HOSTS) > 1 else {HOSTS[0]: b.result}
print()
for host, r in results.items():
    print(f"{host}: {r['version']} at {r['path']}", "(updated)" if r["changed"] else "(already current)")
    if not r["on_path"]:
        print(f"  note: {r['path'].rsplit('/', 1)[0]} is not on $PATH there; add it to your shell rc")
