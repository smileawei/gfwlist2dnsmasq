#!/bin/bash
set -euo pipefail

SCRIPT_DIR=${DNSMASQ_SCRIPT_DIR:-/opt/dnsmasq-chn/scripts}
UPSTREAM_RULES_DIR=${UPSTREAM_RULES_DIR:-/opt/dnsmasq-chn/conf/upstreams}

reload_rules() {
  if ! "$SCRIPT_DIR/reload.sh"; then
    echo "[watch] reload failed; keeping the active rules and watching for corrections" >&2
  fi
}

# BusyBox inotifyd invokes this script as: EVENTS WATCHED_DIRECTORY [CHILD].
if [ "$#" -gt 0 ]; then
  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 [EVENTS DIRECTORY [CHILD]]" >&2
    exit 1
  fi
  child=${3:-}
  case "$child" in
    ''|.*|*/*) exit 0 ;;
    *.conf) ;;
    *) exit 0 ;;
  esac
  # Directory events are not recursive. Ignore a new directory named *.conf;
  # deleted/moved-away files must still trigger a render even though absent.
  [ ! -d "$2/$child" ] || exit 0
  # Editors commonly save via several create/move/close events. Give the writes
  # a moment to settle before rendering and validating the current snapshot.
  sleep 0.2
  reload_rules
  exit 0
fi

WATCH_PID=''
cleanup() {
  if [ -n "$WATCH_PID" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM

while true; do
  if [ ! -d "$UPSTREAM_RULES_DIR" ]; then
    echo "[watch] waiting for upstream rules directory: $UPSTREAM_RULES_DIR" >&2
    sleep 1
    continue
  fi

  # w=close after writing (including new files); y/m=move in/out; d=delete. D/M/x are
  # changes to the watched directory itself. Periodically checking its inode
  # also catches an editor or deploy replacing the entire directory.
  identity=$(stat -c '%d:%i' "$UPSTREAM_RULES_DIR" 2>/dev/null) || {
    sleep 1
    continue
  }
  echo "[watch] watching $UPSTREAM_RULES_DIR/*.conf" >&2
  inotifyd "$SCRIPT_DIR/watch-upstreams.sh" "$UPSTREAM_RULES_DIR:wymdDMx" &
  WATCH_PID=$!

  # Reconcile changes made between the entrypoint render and watch startup.
  reload_rules
  while kill -0 "$WATCH_PID" 2>/dev/null; do
    current=$(stat -c '%d:%i' "$UPSTREAM_RULES_DIR" 2>/dev/null || true)
    if [ "$current" != "$identity" ]; then
      echo "[watch] upstream rules directory changed; rearming monitor" >&2
      kill "$WATCH_PID" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=''
  echo "[watch] monitor stopped; retrying in one second" >&2
  sleep 1
done
