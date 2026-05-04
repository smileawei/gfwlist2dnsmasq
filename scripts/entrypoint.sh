#!/bin/bash
set -euo pipefail

CONF_DIR=/etc/dnsmasq.d
RUNTIME_ENV=/opt/dnsmasq-chn/runtime.env
mkdir -p "$CONF_DIR"

: "${DEFAULT_UPSTREAM:=223.5.5.5}"
: "${GFW_UPSTREAM_IP:=}"
: "${GFW_UPSTREAM_PORT:=53}"
: "${UPDATE_CRON:=0 4 * * *}"

if [ -z "$GFW_UPSTREAM_IP" ]; then
  echo "[entrypoint] ERROR: GFW_UPSTREAM_IP is required (set it in .env)" >&2
  exit 1
fi

# persist runtime env so cron-triggered update.sh can source it (busybox crond
# does not inherit the parent environment)
cat > "$RUNTIME_ENV" <<EOF
export GFW_UPSTREAM_IP='$GFW_UPSTREAM_IP'
export GFW_UPSTREAM_PORT='$GFW_UPSTREAM_PORT'
EOF

# write default upstream conf from env (dnsmasq has no env interpolation)
{
  echo "# managed by entrypoint.sh — regenerated on every container start"
  for ip in $DEFAULT_UPSTREAM; do
    echo "server=$ip"
  done
} > "$CONF_DIR/00-upstream.conf"
echo "[entrypoint] wrote 00-upstream.conf with: $DEFAULT_UPSTREAM"

# servers-file must exist before dnsmasq starts, even if empty
if [ ! -f "$CONF_DIR/gfw.conf" ] || [ ! -s "$CONF_DIR/gfw.conf" ]; then
  echo "[entrypoint] gfw.conf missing/empty, running initial update..."
  /opt/dnsmasq-chn/scripts/update.sh || {
    echo "[entrypoint] initial update failed; touching empty gfw.conf so dnsmasq can start"
    : > "$CONF_DIR/gfw.conf"
  }
fi

# install crontab for daily update; route stdout/stderr to PID 1's stderr
# so logs surface in `docker logs`
mkdir -p /etc/crontabs
cat > /etc/crontabs/root <<EOF
# dnsmasq-chn daily gfwlist refresh
$UPDATE_CRON /opt/dnsmasq-chn/scripts/update.sh >> /proc/1/fd/2 2>&1
EOF
echo "[entrypoint] crontab installed: $UPDATE_CRON"

crond -L /dev/stderr

echo "[entrypoint] starting dnsmasq..."
exec dnsmasq -k --conf-file=/etc/dnsmasq.conf "$@"
