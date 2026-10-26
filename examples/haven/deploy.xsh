#!/usr/bin/env xonsh
# Deploy the Haven nostr relay (https://github.com/bitvora/haven) to a server.
#
#   xonsh examples/haven/deploy.xsh
#
# Safe to re-run: every step checks before it changes anything, and Haven /
# nginx are only restarted when one of their files actually changed.
#
# Layout on the server:
#   /opt/haven                  binary, .env, npub lists, db/, blossom/ (user: haven)
#   haven.service               listens on 127.0.0.1:3355 only
#   nginx :PORT (TLS)  ->  127.0.0.1:3355     wss://DOMAIN:PORT
#   nginx :80                   only for certbot's http-01 renewal
# Port 443 is left alone: headscale owns it.
#
# Needs open in the cloud security group: tcp PORT and tcp 80.

from pathlib import Path
from xonsible import on

HOST = "root@qubaitian.duckdns.org"
DOMAIN = "qubaitian.duckdns.org"
PORT = 7443                      # public wss port
VERSION = "v1.2.2"
# sha256 of haven_Linux_x86_64.tar.gz from the release's checksums.txt
SHA256 = "8c0e6d7da6f9ea520b8e69b1089416eef9fc831e53e7dc9f5eac889d993d73aa"

OWNER = "npub1cstyf6uky6ejm2vznfz9u9mkp833y2qr7ehqg4j9kfjhhuh4qhasr29gyd"
AGENT = Path("~/.config/nostr/agent.npub").expanduser().read_text().strip()
WHITELIST = [OWNER, AGENT]
for npub in WHITELIST:
    assert npub.startswith("npub1") and len(npub) == 63, f"bad npub: {npub!r}"

NAME = "qubaitian"
ICON = ""

# Based on .env.example of Haven v1.2.2. S3 settings are omitted: backups are off.
ENV = f'''\
OWNER_NPUB="{OWNER}"
RELAY_URL="{DOMAIN}:{PORT}"
RELAY_PORT=3355
RELAY_BIND_ADDRESS="127.0.0.1"
DB_ENGINE="badger"
LMDB_MAPSIZE=0
BLOSSOM_PATH="blossom/"

PRIVATE_RELAY_NAME="{NAME}'s private relay"
PRIVATE_RELAY_NPUB="{OWNER}"
PRIVATE_RELAY_DESCRIPTION="drafts and private notes"
PRIVATE_RELAY_ICON="{ICON}"
PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=50
PRIVATE_RELAY_EVENT_IP_LIMITER_INTERVAL=1
PRIVATE_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=100
PRIVATE_RELAY_ALLOW_EMPTY_FILTERS=true
PRIVATE_RELAY_ALLOW_COMPLEX_FILTERS=true
PRIVATE_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=3
PRIVATE_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=5
PRIVATE_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=9

CHAT_RELAY_NAME="{NAME}'s chat relay"
CHAT_RELAY_NPUB="{OWNER}"
CHAT_RELAY_DESCRIPTION="a relay for private chats"
CHAT_RELAY_ICON="{ICON}"
CHAT_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=50
CHAT_RELAY_EVENT_IP_LIMITER_INTERVAL=1
CHAT_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=100
CHAT_RELAY_ALLOW_EMPTY_FILTERS=false
CHAT_RELAY_ALLOW_COMPLEX_FILTERS=false
CHAT_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=3
CHAT_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=3
CHAT_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=9

OUTBOX_RELAY_NAME="{NAME}'s outbox relay"
OUTBOX_RELAY_NPUB="{OWNER}"
OUTBOX_RELAY_DESCRIPTION="a relay and Blossom server for public messages and media"
OUTBOX_RELAY_ICON="{ICON}"
OUTBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=10
OUTBOX_RELAY_EVENT_IP_LIMITER_INTERVAL=60
OUTBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=100
OUTBOX_RELAY_ALLOW_EMPTY_FILTERS=false
OUTBOX_RELAY_ALLOW_COMPLEX_FILTERS=false
OUTBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=3
OUTBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=1
OUTBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=9

INBOX_RELAY_NAME="{NAME}'s inbox relay"
INBOX_RELAY_NPUB="{OWNER}"
INBOX_RELAY_DESCRIPTION="send your interactions with my notes here"
INBOX_RELAY_ICON="{ICON}"
INBOX_PULL_INTERVAL_SECONDS=600
INBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=10
INBOX_RELAY_EVENT_IP_LIMITER_INTERVAL=1
INBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=20
INBOX_RELAY_ALLOW_EMPTY_FILTERS=false
INBOX_RELAY_ALLOW_COMPLEX_FILTERS=false
INBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=3
INBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=1
INBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=9

IMPORT_START_DATE="2023-01-20"
IMPORT_OWNER_NOTES_FETCH_TIMEOUT_SECONDS=60
IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS=120
IMPORT_SEED_RELAYS_FILE="relays_import.json"

BACKUP_PROVIDER="none"
BACKUP_INTERVAL_HOURS=24

BLASTR_RELAYS_FILE="relays_blastr.json"
BLASTR_TIMEOUT_SECONDS=5

WOT_DEPTH=3
WOT_MINIMUM_FOLLOWERS=3
WOT_FETCH_TIMEOUT_SECONDS=30
WOT_REFRESH_INTERVAL="24h"

WHITELISTED_NPUBS_FILE="whitelisted_npubs.json"
BLACKLISTED_NPUBS_FILE="blacklisted_npubs.json"

HAVEN_LOG_LEVEL="INFO"
'''

# The box has ~950 MB RAM, so cap Haven well below it.
UNIT = '''\
[Unit]
Description=Haven nostr relay
After=network-online.target
Wants=network-online.target

[Service]
User=haven
Group=haven
WorkingDirectory=/opt/haven
ExecStart=/opt/haven/haven
MemoryMax=450M
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
'''

NGINX = '''\
# Managed by xonsible examples/haven/deploy.xsh
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
    # certbot's nginx authenticator answers http-01 renewals here.
    location / { return 404; }
}

server {
    listen __PORT__ ssl;
    listen [::]:__PORT__ ssl;
    server_name __DOMAIN__;

    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;

    client_max_body_size 100m;

    # extra services on this port (e.g. agent-hub drops agent.conf here)
    include /etc/nginx/haven.d/*.conf;

    location / {
        proxy_pass http://127.0.0.1:3355;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        # $remote_addr, not $proxy_add_x_forwarded_for: clients must not be
        # able to forge their address (Haven README).
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 1h;
    }
}
'''.replace("__DOMAIN__", DOMAIN).replace("__PORT__", str(PORT))

with! on(HOST, version=VERSION, sha256=SHA256, env_text=ENV, whitelist=WHITELIST,
         unit=UNIT, nginx_conf=NGINX, domain=DOMAIN, port=PORT) as b:
    import hashlib, json, pwd, shutil, subprocess, tempfile, time
    from pathlib import Path

    home = Path("/opt/haven")
    changed = set()   # "haven" / "nginx": which services need a restart

    def ok(*cmd):
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

    def put(path, text, mode=0o644, owner="root"):
        p = Path(path)
        if p.exists() and p.read_text() == text:
            return False
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        p.chmod(mode)
        shutil.chown(p, owner, owner)
        print("wrote", p)
        return True

    # 1. system user
    try:
        pwd.getpwnam("haven")
    except KeyError:
        useradd --system --home-dir /opt/haven --shell /usr/sbin/nologin haven
    home.mkdir(exist_ok=True)

    # 2. release tarball (binary + templates/), checksum-verified
    stamp = home / ".version"
    if not stamp.exists() or stamp.read_text().strip() != version:
        print("installing haven", version)
        tmp = Path(tempfile.mkdtemp())
        tgz = tmp / "haven.tar.gz"
        curl -fsSL -o @(str(tgz)) @(f"https://github.com/bitvora/haven/releases/download/{version}/haven_Linux_x86_64.tar.gz")
        got = hashlib.sha256(tgz.read_bytes()).hexdigest()
        if got != sha256:
            raise SystemExit(f"checksum mismatch: {got} != {sha256}")
        if ok("systemctl", "is-active", "--quiet", "haven"):
            systemctl stop haven   # a running binary can't be overwritten
        tar -xzf @(str(tgz)) -C @(str(home))
        shutil.rmtree(tmp)
        stamp.write_text(version + "\n")
        changed.add("haven")

    # 3. config. Relay lists are only seeded once, so manual edits survive.
    if put(home / ".env", env_text, mode=0o600, owner="haven"):
        changed.add("haven")
    if put(home / "whitelisted_npubs.json", json.dumps(whitelist, indent=2) + "\n", owner="haven"):
        changed.add("haven")
    if not (home / "blacklisted_npubs.json").exists():
        put(home / "blacklisted_npubs.json", "[]\n", owner="haven")
    for name in ("relays_import", "relays_blastr"):
        if not (home / f"{name}.json").exists():
            shutil.copy(home / f"{name}.example.json", home / f"{name}.json")
            changed.add("haven")
    chown -R haven:haven /opt/haven

    # 4. systemd unit
    if put("/etc/systemd/system/haven.service", unit):
        systemctl daemon-reload
        changed.add("haven")

    # 5. nginx: TLS on the public port, plain :80 for certbot
    if put("/etc/nginx/sites-available/haven.conf", nginx_conf):
        changed.add("nginx")
    link = Path("/etc/nginx/sites-enabled/haven.conf")
    if not link.is_symlink():
        link.symlink_to("/etc/nginx/sites-available/haven.conf")
        changed.add("nginx")
    nginx -t -q

    # 6. (re)start what changed; make sure both are enabled and running
    systemctl enable --quiet haven nginx
    for svc in ("haven", "nginx"):
        if not ok("systemctl", "is-active", "--quiet", svc):
            systemctl start @(svc)
        elif svc in changed:
            systemctl @("restart" if svc == "haven" else "reload") @(svc)

    # 7. health check: NIP-11 info through nginx, as a client would see it.
    # Haven builds its web of trust before it listens, so allow ~90 s.
    info = None
    for _ in range(45):
        r = subprocess.run(
            ["curl", "-fsS", "--resolve", f"{domain}:{port}:127.0.0.1",
             "-H", "Accept: application/nostr+json", f"https://{domain}:{port}/"],
            capture_output=True, text=True)
        if r.returncode == 0:
            info = json.loads(r.stdout)
            break
        time.sleep(2)
    if info is None:
        journalctl -u haven -n 30 --no-pager
        raise SystemExit("haven did not answer through nginx within 90 s")
    ret({"changed": sorted(changed), "name": info.get("name"),
         "software": info.get("software"), "version": info.get("version")})

print()
print("deployed:", b.result)
print(f"relay:    wss://{DOMAIN}:{PORT}   (private: /private  chat: /chat  inbox: /inbox)")
print("whitelist:", *WHITELIST, sep="\n  ")
