# End-to-end check against `ssh localhost`. Run: xonsh tests/e2e_localhost.xsh
import sys
sys.path.insert(0, ".")
from xonsible import on, RemoteError

secret = "local-only"

# 1. vars travel, locals don't, ret() comes back, subprocess syntax works
with! on("localhost", pkg="nginx", n=3) as b:
    print("pkg =", pkg, "| secret visible:", "secret" in globals())
    files = $(ls /etc).split()[:n]
    for f in files:
        echo item @(f)
    ret({"files": files, "host": $(hostname).strip()})
assert b.result["files"] and len(b.result["files"]) == 3, b.result
print("1 ok:", b.result)

# 2. a failing command raises RemoteError (XONSH_SUBPROC_CMD_RAISE_ERROR)
try:
    with! on("localhost", quiet=True):
        false
        print("should not get here")
    raise SystemExit("2 FAILED: no error raised")
except RemoteError as e:
    assert "should not get here" not in e.failures["localhost"].stdout
    print("2 ok:", e)

# 3. a command reading stdin must not eat the rest of the script
with! on("localhost") as b:
    cat
    ret("after cat")
assert b.result == "after cat", b.result
print("3 ok")

# 4. several hosts in parallel, prefixed output, dict of results
with! on(["localhost", "127.0.0.1"]) as b:
    import os
    echo pid @(os.getpid())
    ret(os.getpid())
assert set(b.result) == {"localhost", "127.0.0.1"}, b.result
print("4 ok:", b.result)

# 5. check=False collects failures instead of raising
with! on("localhost", check=False, quiet=True) as b:
    exit 7
assert b.results["localhost"].returncode == 7, b.results
print("5 ok")

# 6. plain `with` (forgot the !) gives a clear error
try:
    with on("localhost"):
        pass
except TypeError as e:
    print("6 ok:", e)

print("ALL PASSED")
