#!/bin/bash
set -euo pipefail

CONF_DIR=${DNSMASQ_CONF_DIR:-/etc/dnsmasq.d}
SCRIPT_DIR=${DNSMASQ_SCRIPT_DIR:-/opt/dnsmasq-chn/scripts}
RUNTIME_ENV=${DNSMASQ_RUNTIME_ENV:-/opt/dnsmasq-chn/runtime.env}
PID_FILE=${DNSMASQ_PID_FILE:-/var/run/dnsmasq.pid}
mkdir -p "$CONF_DIR"

: "${DEFAULT_UPSTREAM:=223.5.5.5}"
: "${GFW_UPSTREAM_IP:=}"
: "${GFW_UPSTREAM_PORT:=53}"
: "${UPDATE_CRON:=0 4 * * *}"

if [ -z "$GFW_UPSTREAM_IP" ]; then
  echo "[entrypoint] ERROR: GFW_UPSTREAM_IP is required (set it in .env)" >&2
  exit 1
fi

# Persist the settings used by cron, safely quoted for Bash.
{
  printf 'export GFW_UPSTREAM_IP=%q\n' "$GFW_UPSTREAM_IP"
  printf 'export GFW_UPSTREAM_PORT=%q\n' "$GFW_UPSTREAM_PORT"
  printf 'export DNSMASQ_PID_FILE=%q\n' "$PID_FILE"
  if [ -n "${GFWLIST_URL:-}" ]; then
    printf 'export GFWLIST_URL=%q\n' "$GFWLIST_URL"
  fi
} > "$RUNTIME_ENV"

# write default upstream conf from env (dnsmasq has no env interpolation)
{
  echo "# managed by entrypoint.sh — regenerated on every container start"
  for ip in $DEFAULT_UPSTREAM; do
    echo "server=$ip"
  done
} > "$CONF_DIR/00-upstream.conf"
echo "[entrypoint] wrote 00-upstream.conf with: $DEFAULT_UPSTREAM"

# Reuse the downloaded cache, or fetch it before the first startup.
if [ ! -f "$CONF_DIR/gfw.conf" ] || [ ! -s "$CONF_DIR/gfw.conf" ]; then
  echo "[entrypoint] gfw.conf missing/empty, running initial update..."
  "$SCRIPT_DIR/update.sh" --no-reload || {
    echo "[entrypoint] initial update failed; touching empty gfw.conf so dnsmasq can start"
    : > "$CONF_DIR/gfw.conf"
  }
fi
chmod 0644 "$CONF_DIR/gfw.conf"
# Always render the current manual files on startup, including when reusing a
# downloaded cache. Invalid files must never replace a working server snapshot.
if ! "$SCRIPT_DIR/reload.sh" --no-reload; then
  if [ -f "$CONF_DIR/servers.conf" ] &&
     dnsmasq --test --conf-file="$CONF_DIR/servers.conf"; then
    echo "[entrypoint] invalid new rules; starting with the previous servers.conf" >&2
  else
    echo "[entrypoint] no valid upstream rules are available" >&2
    exit 1
  fi
fi

# Keep watching saves, additions, removals and editor atomic renames.
"$SCRIPT_DIR/watch-upstreams.sh" &

# Keep crond in the foreground of its own process so its stderr remains the
# Docker log pipe. PID 1 becomes an unprivileged dnsmasq, whose /proc/1/fd/2
# cannot be opened by cron jobs under Docker's default capabilities.
mkdir -p /etc/crontabs
CROND_PID_FILE=/var/run/dnsmasq-chn-crond.pid
cat > /etc/crontabs/root <<EOF
# dnsmasq-chn daily gfwlist refresh
$UPDATE_CRON $SCRIPT_DIR/update.sh >> /proc/\$(cat $CROND_PID_FILE)/fd/2 2>&1
EOF
crond -f -d 8 -c /etc/crontabs &
printf '%s\n' "$!" > "$CROND_PID_FILE"
echo "[entrypoint] crontab installed: $UPDATE_CRON"

echo "[entrypoint] starting dnsmasq..."
exec dnsmasq -k --conf-file=/etc/dnsmasq.conf --pid-file="$PID_FILE" "$@"
