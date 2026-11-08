#!/bin/bash
# Offline regression checks; never invokes update.sh or signals any process.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/output with spaces"
export FIXTURE="$TEST_DIR/source.base64"
export REAL_SORT
REAL_SORT=$(command -v sort)

cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/sh
set -e
output=''
fail_flag=0
timeout_flag=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --fail) fail_flag=1 ;;
        --max-time) timeout_flag=1; shift ;;
        -o) output=$2; shift ;;
    esac
    shift
done
[ "$fail_flag" -eq 1 ] && [ "$timeout_flag" -eq 1 ]
[ "${CURL_STATUS:-0}" -eq 0 ] || exit "$CURL_STATUS"
cp "$FIXTURE" "$output"
EOF
cat > "$TEST_DIR/bin/sort" <<'EOF'
#!/bin/sh
[ "${SORT_FAIL:-0}" -eq 0 ] || exit 1
exec "$REAL_SORT" "$@"
EOF
chmod +x "$TEST_DIR/bin/curl" "$TEST_DIR/bin/sort"
export PATH="$TEST_DIR/bin:$PATH"

cat > "$TEST_DIR/source.txt" <<'EOF'
[AutoProxy 0.2.9]
! fixture
||example.com
||sub.example.com^
||notexample.com
||go.com
||notgo.com
@@||ignored.example
EOF
base64 "$TEST_DIR/source.txt" > "$FIXTURE"
OUTPUT="$TEST_DIR/output with spaces/gfw.conf"

generate() {
    "${GENERATOR_SHELL:-sh}" "$ROOT/scripts/gfwlist2dnsmasq.sh" -d 192.0.2.53 -p 5353 -o "$OUTPUT" "$@" > "$TEST_DIR/run.log" 2>&1
}

generate
grep -Fxq 'server=/example.com/192.0.2.53#5353' "$OUTPUT"
grep -Fxq 'server=/sub.example.com/192.0.2.53#5353' "$OUTPUT"
if grep -Fq ignored.example "$OUTPUT"; then exit 1; fi
printf 'PASS: valid list conversion and Adblock suffix handling\n'

: > "$TEST_DIR/exclude.txt"
generate --exclude-domain-file "$TEST_DIR/exclude.txt"
grep -Fxq 'server=/example.com/192.0.2.53#5353' "$OUTPUT"
printf 'PASS: empty exclusion file\n'

printf '# exclusions\n\n example.com \r\ngo.com\n' > "$TEST_DIR/exclude.txt"
printf '# extras\n\n CUSTOM.Example \r\nexample.com # explicitly restore\n' > "$TEST_DIR/extra.txt"
generate --exclude-domain-file "$TEST_DIR/exclude.txt" --extra-domain-file "$TEST_DIR/extra.txt"
grep -Fxq 'server=/example.com/192.0.2.53#5353' "$OUTPUT"
grep -Fxq 'server=/notexample.com/192.0.2.53#5353' "$OUTPUT"
grep -Fxq 'server=/notgo.com/192.0.2.53#5353' "$OUTPUT"
grep -Fxq 'server=/custom.example/192.0.2.53#5353' "$OUTPUT"
if grep -Eq '^server=/(sub\.example\.com|go\.com)/' "$OUTPUT"; then exit 1; fi
printf 'PASS: domain boundaries, comments, CRLF and extra-domain precedence\n'

generate -s testset
grep -Fxq 'ipset=/example.com/testset' "$OUTPUT"
generate -l
grep -Fxq example.com "$OUTPUT"
if grep -q '^server=' "$OUTPUT"; then exit 1; fi
printf 'PASS: ipset and plain-domain output\n'

expect_preserved_failure() {
    printf 'existing valid rules\n' > "$OUTPUT"
    if generate "$@"; then
        cat "$TEST_DIR/run.log" >&2
        printf 'Expected generation to fail\n' >&2
        exit 1
    fi
    [ "$(cat "$OUTPUT")" = 'existing valid rules' ]
}

export CURL_STATUS=22
expect_preserved_failure
unset CURL_STATUS
printf 'PASS: HTTP/download failure preserves existing output\n'

printf 'not base64!' > "$FIXTURE"
expect_preserved_failure
printf 'PASS: decode failure preserves existing output\n'

printf '! metadata only\n[AutoProxy 0.2.9]\n' | base64 > "$FIXTURE"
expect_preserved_failure
printf 'PASS: empty upstream rules cannot be masked by built-in domains\n'

base64 "$TEST_DIR/source.txt" > "$FIXTURE"
printf 'not a domain\n' > "$TEST_DIR/extra.txt"
expect_preserved_failure --extra-domain-file "$TEST_DIR/extra.txt"
printf 'PASS: malformed extra domains preserve existing output\n'

# BusyBox ash may resolve sort to its built-in applet and bypass PATH mocks.
if "${GENERATOR_SHELL:-sh}" -c 'type sort' | grep -Fxq 'sort is sort'; then
    printf 'SKIP: sort failure injection (shell uses its built-in sort applet)\n'
else
    export SORT_FAIL=1
    expect_preserved_failure
    unset SORT_FAIL
    printf 'PASS: processing failure preserves existing output\n'
fi

if generate -p nope; then exit 1; fi
if generate -d; then exit 1; fi
printf 'PASS: invalid arguments fail\n'
