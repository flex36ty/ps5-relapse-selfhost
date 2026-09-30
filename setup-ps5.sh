#!/usr/bin/env bash
# Run from an uploaded copy of this project: sudo bash setup-ps5.sh 192.168.0.23
set -Eeuo pipefail
trap 'echo "Setup failed at line $LINENO. Review the error above before retrying." >&2' ERR

[[ $EUID -eq 0 ]] || { echo "Run with sudo or as root." >&2; exit 1; }
command -v apt-get >/dev/null || { echo "Debian or Ubuntu is required." >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo "A running systemd is required." >&2; exit 1; }
SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DEST=/home/ps5
LAN_IP=${1:-$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')}
[[ $# -le 1 && -n $LAN_IP ]] || { echo "Usage: bash setup-ps5.sh CONTAINER_LAN_IP" >&2; exit 1; }
ip -o -4 addr show | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$LAN_IP" || {
    echo "IP $LAN_IP is not assigned to this container." >&2; exit 1;
}
for item in index.html serve.py serve_https.py src offsets payloads; do
    [[ -e "$SOURCE/$item" ]] || { echo "Missing project item: $SOURCE/$item" >&2; exit 1; }
done

# Do not kill manually started servers or unrelated services.
for port in 80 443; do
    unit=ps5-http.service
    [[ $port == 443 ]] && unit=ps5-https.service
    if ss -H -lnt "sport = :$port" | grep -q . && ! systemctl is-active --quiet "$unit"; then
        echo "Port $port is occupied. Stop the manually running server (Ctrl+C) or resolve the conflict, then rerun." >&2
        ss -lntp "sport = :$port"
        exit 1
    fi
done

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y dnsmasq dnsutils python3 openssl rsync curl

STAMP=$(date +%Y%m%d-%H%M%S)-$$
BACKUP=/var/backups/ps5-host/$STAMP
install -d -m 700 "$BACKUP"
install -d -m 755 "$DEST"
if [[ $(readlink -f "$SOURCE") != $(readlink -f "$DEST") ]]; then
    # Keep overwritten versions outside the web root; never delete extra files.
    rsync -a --backup --backup-dir="$BACKUP/site" \
        "$SOURCE/index.html" "$SOURCE/serve.py" "$SOURCE/serve_https.py" \
        "$SOURCE/src" "$SOURCE/offsets" "$SOURCE/payloads" "$DEST/"
fi
chmod a+rx /home "$DEST"
chmod a+r "$DEST/index.html" "$DEST/serve.py" "$DEST/serve_https.py"
chmod -R a+rX "$DEST/src" "$DEST/offsets" "$DEST/payloads"

backup_file() {
    if [[ -f $1 ]]; then
        cp --parents -- "$1" "$BACKUP/"
    fi
}

# Use the same config filename as the earlier manual setup.
install -d /etc/dnsmasq.d
backup_file /etc/dnsmasq.d/ps5.conf
cat > /etc/dnsmasq.d/ps5.conf <<EOF
listen-address=$LAN_IP
bind-interfaces
no-resolv
server=1.1.1.1
server=9.9.9.9
local=/manuals.playstation.net/
address=/manuals.playstation.net/$LAN_IP
EOF
dnsmasq --test

install -d -m 750 -o root -g www-data /etc/ps5-host
# Keep an existing valid certificate so reruns don't change its identity.
if [[ ! -s /etc/ps5-host/cert.pem || ! -s /etc/ps5-host/key.pem ]] || \
    ! openssl x509 -checkend 604800 -noout -in /etc/ps5-host/cert.pem >/dev/null 2>&1; then
    backup_file /etc/ps5-host/cert.pem
    backup_file /etc/ps5-host/key.pem
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /etc/ps5-host/key.pem -out /etc/ps5-host/cert.pem \
        -days 365 -subj '/CN=manuals.playstation.net' \
        -addext 'subjectAltName=DNS:manuals.playstation.net'
fi
chown root:www-data /etc/ps5-host/{cert,key}.pem
chmod 640 /etc/ps5-host/{cert,key}.pem

for kind in http https; do
    script=serve.py
    [[ $kind == https ]] && script=serve_https.py
    backup_file "/etc/systemd/system/ps5-$kind.service"
    cat > "/etc/systemd/system/ps5-$kind.service" <<EOF
[Unit]
Description=PS5 local $kind host
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/home/ps5
Environment=PS5_HTTP_PORT=80
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=/usr/bin/python3 -u /home/ps5/$script
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF
done

python3 -m py_compile "$DEST/serve.py" "$DEST/serve_https.py"
systemctl daemon-reload
systemctl enable dnsmasq ps5-http ps5-https
systemctl restart dnsmasq ps5-http ps5-https

# Retry briefly while the services start; test both guide redirection and assets.
curl --retry 10 --retry-connrefused --retry-delay 1 --max-time 5 \
    -fsS "http://$LAN_IP/" -o /dev/null
curl --retry 10 --retry-connrefused --retry-delay 1 --max-time 5 \
    -fkLsS --resolve "manuals.playstation.net:443:$LAN_IP" \
    'https://manuals.playstation.net/document/en/ps5/' -o /dev/null
curl -fkSs --resolve "manuals.playstation.net:443:$LAN_IP" \
    'https://manuals.playstation.net/src/kexp.js' -o /dev/null
dig +short +time=2 +tries=1 "@$LAN_IP" manuals.playstation.net A | grep -Fx "$LAN_IP"
systemctl is-active dnsmasq ps5-http ps5-https

echo
echo "Setup complete. Set the PS5 primary DNS to $LAN_IP and open User's Guide."
echo "HTTP and HTTPS now start automatically at boot. Backups: $BACKUP"
echo "Keep this LAN IP fixed using a static address or DHCP reservation."
echo "If a container/Proxmox firewall is enabled, allow LAN access to UDP/TCP 53 and TCP 80/443."
echo "Certificate expires in about a year; rerun setup to renew when close to expiry."
echo "Logs: journalctl -u ps5-https -u ps5-http -u dnsmasq -f"
