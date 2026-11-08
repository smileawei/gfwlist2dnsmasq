#!/bin/bash
set -euo pipefail

RUNTIME_ENV=${DNSMASQ_RUNTIME_ENV:-/opt/dnsmasq-chn/runtime.env}
[ ! -f "$RUNTIME_ENV" ] || . "$RUNTIME_ENV"

CONF_DIR=${DNSMASQ_CONF_DIR:-/etc/dnsmasq.d}
UPSTREAM_RULES_DIR=${UPSTREAM_RULES_DIR:-/opt/dnsmasq-chn/conf/upstreams}
PID_FILE=${DNSMASQ_PID_FILE:-/var/run/dnsmasq.pid}
RELOAD=1
NEW_GFW=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-reload) RELOAD=0; shift ;;
    --gfw-file)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "Usage: $0 [--no-reload] [--gfw-file FILE]" >&2
        exit 1
      fi
      NEW_GFW=$2
      shift 2
      ;;
    *)
      echo "Usage: $0 [--no-reload] [--gfw-file FILE]" >&2
      exit 1
      ;;
  esac
done

if [ ! -d "$UPSTREAM_RULES_DIR" ]; then
  echo "[reload] upstream rules directory is missing: $UPSTREAM_RULES_DIR" >&2
  exit 1
fi
mkdir -p "$CONF_DIR"
# Serialize the directory watcher, manual reloads and downloaded cache updates.
exec 9> "$CONF_DIR/.reload.lock"
flock 9

TEMP_FILES=()
trap 'rm -f -- "${TEMP_FILES[@]}"' EXIT
GFW_STAGE=$(mktemp "$CONF_DIR/.gfw-cache.XXXXXX")
TEMP_FILES+=("$GFW_STAGE")
MANUAL_STAGE=$(mktemp "$CONF_DIR/.manual.XXXXXX")
TEMP_FILES+=("$MANUAL_STAGE")
DOMAINS=$(mktemp "$CONF_DIR/.manual-domains.XXXXXX")
TEMP_FILES+=("$DOMAINS")
RULES_STAGE=$(mktemp "$CONF_DIR/.servers.XXXXXX")
TEMP_FILES+=("$RULES_STAGE")

GFW_SOURCE=${NEW_GFW:-$CONF_DIR/gfw.conf}
cp -- "$GFW_SOURCE" "$GFW_STAGE"

# Match the documented directory selection, including filenames with spaces.
RULE_FILES=()
shopt -s nullglob
for rule_file in "$UPSTREAM_RULES_DIR"/*.conf; do
  [ ! -f "$rule_file" ] || RULE_FILES+=("$rule_file")
done
shopt -u nullglob

if [ "${#RULE_FILES[@]}" -gt 0 ]; then
  # Preserve native directive syntax. servers-file only permits these two
  # options; --test alone would also accept unrelated global configuration.
  awk -v domains="$DOMAINS" '
    {
      sub(/\r$/, "")
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line == "" || line ~ /^#/) next
      if (line !~ /^(server|rev-server)[ \t]*=/) {
        print "[reload] " FILENAME ":" FNR ": only server= and rev-server= are supported" > "/dev/stderr"
        exit 1
      }
      print line
      if (line !~ /^server[ \t]*=/) next
      sub(/^server[ \t]*=[ \t]*/, "", line)
      gsub(/"/, "", line)
      if (line !~ /^\//) next
      sub(/^\//, "", line)
      count = split(line, parts, "/")
      for (i = 1; i < count; i++) {
        domain = tolower(parts[i])
        gsub(/^[ \t]+|[ \t]+$/, "", domain)
        sub(/^\./, "", domain)
        sub(/\.$/, "", domain)
        if (domain != "") print domain > domains
      }
    }
  ' "${RULE_FILES[@]}" > "$MANUAL_STAGE"
fi

echo "# managed by reload.sh; edit conf/upstreams/*.conf instead" > "$RULES_STAGE"
# Filter from the complete cache on every reload, so removing a manual override
# restores the GFW route without a download. Leading * selectors match suffixes
# without a label boundary, matching native dnsmasq wildcard semantics.
awk '
  FILENAME == ARGV[1] {
    if ($0 ~ /^\*/) wildcard[substr($0, 2)] = 1
    else suffix[$0] = 1
    next
  }
  {
    line = $0
    sub(/^[ \t]+/, "", line)
    if (line == "" || line ~ /^#/) { print; next }
    if (line !~ /^(server|rev-server)[ \t]*=/) {
      print "[reload] unsupported directive in GFW cache at line " FNR > "/dev/stderr"
      exit 1
    }
    if (line ~ /^server[ \t]*=/) {
      sub(/^server[ \t]*=[ \t]*/, "", line)
      gsub(/"/, "", line)
      if (line ~ /^\//) {
        sub(/^\//, "", line)
        split(line, fields, "/")
        domain = tolower(fields[1])
        sub(/\.$/, "", domain)
        candidate = domain
        while (1) {
          if (candidate in suffix) next
          if (!sub(/^[^.]+\./, "", candidate)) break
        }
        for (ending in wildcard) {
          if (length(domain) >= length(ending) &&
              substr(domain, length(domain) - length(ending) + 1) == ending) next
        }
      }
    }
    print
  }
' "$DOMAINS" "$GFW_STAGE" >> "$RULES_STAGE"
printf '\n# Manual upstream rules\n' >> "$RULES_STAGE"
cat "$MANUAL_STAGE" >> "$RULES_STAGE"

# Parse the actual directives as config: --test does not read servers-file.
dnsmasq --test --conf-file="$GFW_STAGE"
dnsmasq --test --conf-file="$RULES_STAGE"
chmod 0644 "$RULES_STAGE"
if [ -n "$NEW_GFW" ]; then
  chmod 0644 "$GFW_STAGE"
  mv -f -- "$GFW_STAGE" "$CONF_DIR/gfw.conf"
fi
mv -f -- "$RULES_STAGE" "$CONF_DIR/servers.conf"
echo "[reload] wrote $CONF_DIR/servers.conf from ${#RULE_FILES[@]} manual rule files"

if [ "$RELOAD" -eq 0 ]; then
  echo "[reload] initial generation complete, skipping reload"
elif [ -s "$PID_FILE" ]; then
  DNSMASQ_PID=$(cat "$PID_FILE")
  if [[ "$DNSMASQ_PID" =~ ^[0-9]+$ ]] &&
     [ "$(cat "/proc/$DNSMASQ_PID/comm" 2>/dev/null)" = dnsmasq ]; then
    kill -HUP "$DNSMASQ_PID"
    echo "[reload] sent SIGHUP to dnsmasq (PID $DNSMASQ_PID)"
  else
    echo "[reload] dnsmasq is not running yet, skipping reload"
  fi
else
  echo "[reload] dnsmasq is not running yet, skipping reload"
fi
