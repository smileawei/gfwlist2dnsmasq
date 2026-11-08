#!/bin/bash
set -euo pipefail

RUNTIME_ENV=${DNSMASQ_RUNTIME_ENV:-/opt/dnsmasq-chn/runtime.env}
[ -f "$RUNTIME_ENV" ] && . "$RUNTIME_ENV"

: "${GFW_UPSTREAM_IP:?GFW_UPSTREAM_IP not set (entrypoint should have written runtime.env)}"
: "${GFW_UPSTREAM_PORT:=53}"

RELOAD_ARGS=()
if [ "${1:-}" = --no-reload ] && [ "$#" -eq 1 ]; then
  RELOAD_ARGS=(--no-reload)
elif [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--no-reload]" >&2
  exit 1
fi

CONF_DIR=${DNSMASQ_CONF_DIR:-/etc/dnsmasq.d}
SCRIPT_DIR=${DNSMASQ_SCRIPT_DIR:-/opt/dnsmasq-chn/scripts}
TMP=$(mktemp "$CONF_DIR/.gfw.conf.XXXXXX")
trap 'rm -f "$TMP"' EXIT

# Keep the complete downloaded list. Removing a custom override must restore its
# GFW route immediately, without waiting for a new download.
echo "[update $(date -Iseconds)] generating complete gfw.conf (upstream=${GFW_UPSTREAM_IP}#${GFW_UPSTREAM_PORT})"
"$SCRIPT_DIR/gfwlist2dnsmasq.sh" \
  -o "$TMP" \
  -d "$GFW_UPSTREAM_IP" \
  -p "$GFW_UPSTREAM_PORT"

if ! grep -q '^server=/' "$TMP"; then
  echo "[update] generated file contains no DNS rules, keeping existing rules" >&2
  exit 2
fi

# The common reload path validates the manual rules and combined snapshot before
# publishing this cache and signalling dnsmasq. Failure leaves active rules intact.
"$SCRIPT_DIR/reload.sh" --gfw-file "$TMP" "${RELOAD_ARGS[@]}"
echo "[update] refreshed complete GFW cache and applied upstream rules"
