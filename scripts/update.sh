#!/bin/bash
set -euo pipefail

RUNTIME_ENV=/opt/dnsmasq-chn/runtime.env
[ -f "$RUNTIME_ENV" ] && . "$RUNTIME_ENV"

: "${GFW_UPSTREAM_IP:?GFW_UPSTREAM_IP not set (entrypoint should have written runtime.env)}"
: "${GFW_UPSTREAM_PORT:=53}"

CONF_DIR=/etc/dnsmasq.d
EXCLUDE=/opt/dnsmasq-chn/conf/ulock.list
OUT="$CONF_DIR/gfw.conf"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

EXCLUDE_ARG=()
[ -f "$EXCLUDE" ] && EXCLUDE_ARG=(--exclude-domain-file "$EXCLUDE")

echo "[update $(date -Iseconds)] generating gfw.conf (upstream=${GFW_UPSTREAM_IP}#${GFW_UPSTREAM_PORT})"
/opt/dnsmasq-chn/scripts/gfwlist2dnsmasq.sh \
  -o "$TMP" \
  -d "$GFW_UPSTREAM_IP" \
  -p "$GFW_UPSTREAM_PORT" \
  "${EXCLUDE_ARG[@]}"

if [ ! -s "$TMP" ]; then
  echo "[update] generated file is empty, aborting" >&2
  exit 2
fi

mv "$TMP" "$OUT"
echo "[update] wrote $OUT ($(wc -l < "$OUT") lines)"

# servers-file is re-read on SIGHUP. PID 1 is dnsmasq (see entrypoint.sh).
if kill -0 1 2>/dev/null; then
  kill -HUP 1
  echo "[update] sent SIGHUP to dnsmasq (PID 1)"
else
  echo "[update] dnsmasq not running yet, skipping reload"
fi
