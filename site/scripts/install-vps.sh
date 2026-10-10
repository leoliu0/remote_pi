#!/bin/bash
set -euo pipefail
# Installs the web client + Caddy (HTTPS) on the relay VPS. Usage, from site/:
#   pnpm build && pack .next/standalone + .next/static + public into /tmp/rpsite.tgz on the VPS,
#   then run this script there as root. The relay on port 80/3000 is never touched.
HOST=178-157-59-181.sslip.io

# Node runtime (official tarball, no system packages touched)
if [ ! -x /opt/node/bin/node ]; then
  V=$(curl -s https://nodejs.org/dist/index.json | python3 -c 'import json,sys; print(next(r["version"] for r in json.load(sys.stdin) if r["lts"] and r["version"].startswith("v22")))')
  curl -sSL "https://nodejs.org/dist/$V/node-$V-linux-x64.tar.xz" | tar xJ -C /opt
  ln -sfn "/opt/node-$V-linux-x64" /opt/node
fi
/opt/node/bin/node --version

# Caddy binary
if [ ! -x /usr/local/bin/caddy ]; then
  curl -sSL -o /usr/local/bin/caddy "https://caddyserver.com/api/download?os=linux&arch=amd64"
  chmod +x /usr/local/bin/caddy
fi
/usr/local/bin/caddy version

# Site
id remotepi-site >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin remotepi-site
rm -rf /opt/remote-pi-site.new && mkdir -p /opt/remote-pi-site.new
tar xzf /tmp/rpsite.tgz -C /opt/remote-pi-site.new
rm -rf /opt/remote-pi-site.old; [ -d /opt/remote-pi-site ] && mv /opt/remote-pi-site /opt/remote-pi-site.old
mv /opt/remote-pi-site.new /opt/remote-pi-site
chown -R root:root /opt/remote-pi-site
rm -f /tmp/rpsite.tgz

cat > /etc/systemd/system/remote-pi-site.service <<'EOF'
[Unit]
Description=Remote Pi website (Next.js standalone)
After=network-online.target

[Service]
User=remotepi-site
WorkingDirectory=/opt/remote-pi-site
Environment=NODE_ENV=production
Environment=PORT=3100
Environment=HOSTNAME=127.0.0.1
# Server-side relay proxies may only reach this relay (no open proxy).
Environment=RELAY_PROXY_HOSTS=178.157.59.181,178-157-59-181.sslip.io
ExecStart=/opt/node/bin/node server.js
Restart=always
RestartSec=3
# Browser relay tunnels are long-lived SSE streams that never close by
# themselves, so a graceful stop waited for the 90 s default before SIGKILL:
# every deploy meant ~1.5 min of downtime. Clients reconnect on their own.
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/caddy /var/lib/caddy
id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --shell /sbin/nologin caddy
chown caddy:caddy /var/lib/caddy
cat > /etc/caddy/Caddyfile <<EOF
{
	# Port 80 is redirected to the relay by nftables; never touch it.
	http_port 8180
	auto_https disable_redirects
	cert_issuer acme {
		disable_http_challenge
	}
}

$HOST {
	encode gzip
	# Same-origin wss:// relay and mesh endpoint, so https pages need no tunnel.
	@relay_ws header Connection *Upgrade*
	handle @relay_ws {
		reverse_proxy 127.0.0.1:3000
	}
	handle /mesh/* {
		reverse_proxy 127.0.0.1:3000
	}
	handle {
		reverse_proxy 127.0.0.1:3100
	}
}
EOF

cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy (HTTPS for Remote Pi website)
After=network-online.target

[Service]
User=caddy
Environment=HOME=/var/lib/caddy
Environment=XDG_DATA_HOME=/var/lib/caddy
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# The relay listens on :3000 and nftables PREROUTING maps public :80 → :3000,
# which only applies to traffic arriving from outside. The site's relay proxies
# run on this host and dial the public relay URL, so map local traffic too;
# without it they fail and the web client shows no PCs.
PUBLIC_IP=178.157.59.181
if ! iptables -t nat -C OUTPUT -p tcp -d "$PUBLIC_IP" --dport 80 -j REDIRECT --to-ports 3000 2>/dev/null; then
  iptables -t nat -A OUTPUT -p tcp -d "$PUBLIC_IP" --dport 80 -j REDIRECT --to-ports 3000
  iptables-save > /etc/sysconfig/iptables
fi

systemctl daemon-reload
systemctl enable --now remote-pi-site
systemctl restart remote-pi-site
systemctl enable --now caddy
systemctl restart caddy
sleep 4
systemctl is-active remote-pi-site caddy remote-pi-relay
curl -s -o /dev/null -w "site local %{http_code}\n" http://127.0.0.1:3100/web
