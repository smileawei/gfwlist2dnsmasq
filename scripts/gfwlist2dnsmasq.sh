#!/bin/sh
set -e

# Name:        gfwlist2dnsmasq.sh
# Desription:  A shell script which convert gfwlist into dnsmasq rules.
# Version:     0.9.0 (2020.04.09)
# Author:      Cokebar Chi
# Website:     https://github.com/cokebar

_green() {
    printf '\033[1;31;32m'
    printf -- "%b" "$1"
    printf '\033[0m'
}

_red() {
    printf '\033[1;31;31m'
    printf -- "%b" "$1"
    printf '\033[0m'
}

_yellow() {
    printf '\033[1;31;33m'
    printf -- "%b" "$1"
    printf '\033[0m'
}

usage() {
    cat <<-EOF

Name:        gfwlist2dnsmasq.sh
Desription:  A shell script which convert gfwlist into dnsmasq rules.
Version:     0.8.0 (2017.12.25)
Author:      Cokebar Chi
Website:     https://github.com/cokebar

Usage: sh gfwlist2dnsmasq.sh [options] -o FILE
Valid options are:
    -d, --dns <dns_ip>
                DNS IP address for the GfwList Domains (Default: 127.0.0.1)
    -p, --port <dns_port>
                DNS Port for the GfwList Domains (Default: 5353)
    -s, --ipset <ipset_name>
                Ipset name for the GfwList domains
                (If not given, ipset rules will not be generated.)
    -o, --output <FILE>
                /path/to/output_filename
    -i, --insecure
                Force bypass certificate validation (insecure)
    -l, --domain-list
                Convert Gfwlist into domain list instead of dnsmasq rules
                (If this option is set, DNS IP/Port & ipset are not needed)
        --exclude-domain-file <FILE>
                Delete specific domains in the result from a domain list text file
                Please put one domain per line
        --extra-domain-file <FILE>
                Include extra domains to the result from a domain list text file
                This file will be processed after the exclude-domain-file
                Please put one domain per line
    -h, --help
                Usage
EOF
    exit $1
}

cleanup(){
    [ -z "${TMP_DIR:-}" ] || rm -rf -- "$TMP_DIR"
    [ -z "${OUT_STAGE:-}" ] || rm -f -- "$OUT_STAGE"
    return 0
}

clean_and_exit(){
    [ "$1" -eq 0 ] && _green 'Job Finished.\n\n' || _red "Exit with Error code $1.\n"
    exit "$1"
}

# Ignore blank lines/comments and normalize hand-maintained domain lists.
# The downloaded list may contain unsupported regex rules; skip those rather
# than turn them into malformed dnsmasq directives.
normalize_domains(){
    awk -v strict="${2:-0}" '
        {
            sub(/\r$/, "")
            sub(/#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if ($0 == "") next
            domain = tolower($0)
            count = split(domain, labels, ".")
            valid = count > 1 && length(domain) <= 253
            for (i = 1; i <= count; i++) {
                if (length(labels[i]) > 63 || labels[i] !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) valid = 0
            }
            if (valid) print domain
            else if (strict) {
                print "Invalid domain at " FILENAME ":" FNR ": " $0 > "/dev/stderr"
                exit 1
            }
        }
    ' "$1"
}

check_depends(){
    for dependency in sed base64 mktemp awk sort grep tr; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            _red "Error: Missing dependency: $dependency\n"
            exit 3
        fi
    done
    if ! command -v curl >/dev/null 2>&1; then
        if ! command -v wget >/dev/null 2>&1; then
            _red 'Error: Missing Dependency.\nEither curl or wget required.\n'
            exit 3
        fi
        USE_WGET=1
    else
        USE_WGET=0
    fi

    SYS_KERNEL=`uname -s`
    if [ $SYS_KERNEL = "Darwin"  -o $SYS_KERNEL = "FreeBSD" ]; then
        BASE64_DECODE='base64 -D'
        SED_ERES='sed -E'
    else
        BASE64_DECODE='base64 -d'
        SED_ERES='sed -r'
    fi
}

get_args(){
    OUT_TYPE='DNSMASQ_RULES'
    DNS_IP='127.0.0.1'
    DNS_PORT='5353'
    IPSET_NAME=''
    OUT_FILE=''
    CURL_EXTARG=''
    WGET_EXTARG=''
    WITH_IPSET=0
    EXTRA_DOMAIN_FILE=''
    EXCLUDE_DOMAIN_FILE=''
    IPV4_PATTERN='^((2[0-4][0-9]|25[0-5]|[01]?[0-9][0-9]?)\.){3}(2[0-4][0-9]|25[0-5]|[01]?[0-9][0-9]?)$'
    IPV6_PATTERN='^((([0-9A-Fa-f]{1,4}:){7}([0-9A-Fa-f]{1,4}|:))|(([0-9A-Fa-f]{1,4}:){6}(:[0-9A-Fa-f]{1,4}|((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3})|:))|(([0-9A-Fa-f]{1,4}:){5}(((:[0-9A-Fa-f]{1,4}){1,2})|:((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3})|:))|(([0-9A-Fa-f]{1,4}:){4}(((:[0-9A-Fa-f]{1,4}){1,3})|((:[0-9A-Fa-f]{1,4})?:((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}))|:))|(([0-9A-Fa-f]{1,4}:){3}(((:[0-9A-Fa-f]{1,4}){1,4})|((:[0-9A-Fa-f]{1,4}){0,2}:((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}))|:))|(([0-9A-Fa-f]{1,4}:){2}(((:[0-9A-Fa-f]{1,4}){1,5})|((:[0-9A-Fa-f]{1,4}){0,3}:((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}))|:))|(([0-9A-Fa-f]{1,4}:){1}(((:[0-9A-Fa-f]{1,4}){1,6})|((:[0-9A-Fa-f]{1,4}){0,4}:((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}))|:))|(:(((:[0-9A-Fa-f]{1,4}){1,7})|((:[0-9A-Fa-f]{1,4}){0,5}:((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}))|:)))(%.+)?$'

    while [ ${#} -gt 0 ]; do
        case "$1" in
            --dns|-d|--port|-p|--ipset|-s|--output|-o|--extra-domain-file|--exclude-domain-file)
                if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                    _red "Error: $1 requires a value.\n"
                    usage 1
                fi
                ;;
        esac
        case "${1}" in
            --help | -h)
                usage 0
                ;;
            --domain-list | -l)
                OUT_TYPE='DOMAIN_LIST'
                ;;
            --insecure | -i)
                CURL_EXTARG='--insecure'
                WGET_EXTARG='--no-check-certificate'
                ;;
            --dns | -d)
                DNS_IP="$2"
                shift
                ;;
            --port | -p)
                DNS_PORT="$2"
                shift
                ;;
            --ipset | -s)
                IPSET_NAME="$2"
                shift
                ;;
            --output | -o)
                OUT_FILE="$2"
                shift
                ;;
            --extra-domain-file)
                EXTRA_DOMAIN_FILE="$2"
                shift
                ;;
           --exclude-domain-file)
                EXCLUDE_DOMAIN_FILE="$2"
                shift
                ;;
            *)
                _red "Invalid argument: $1"
                usage 1
                ;;
        esac
        shift 1
    done

    # Check path & file name
    if [ -z "$OUT_FILE" ]; then
        _red 'Error: Please specify the path to the output file(using -o/--output argument).\n'
        exit 1
    else
        if [ -z "${OUT_FILE##*/}" ]; then
            _red 'Error: '$OUT_FILE' is a path, not a file.\n'
            exit 1
        else
            if [ "${OUT_FILE}a" != "${OUT_FILE%/*}a" ] && [ ! -d "${OUT_FILE%/*}" ]; then
                _red 'Error: Folder do not exist: '${OUT_FILE%/*}'\n'
                exit 1
            fi
        fi
    fi

    if [ $OUT_TYPE = 'DNSMASQ_RULES' ]; then
        # Check DNS IP
        IPV4_TEST=$(printf '%s\n' "$DNS_IP" | grep -E "$IPV4_PATTERN" || true)
        IPV6_TEST=$(printf '%s\n' "$DNS_IP" | grep -E "$IPV6_PATTERN" || true)
        if [ "$IPV4_TEST" != "$DNS_IP" -a "$IPV6_TEST" != "$DNS_IP" ]; then
            _red 'Error: Please enter a valid DNS server IP address.\n'
            exit 1
        fi

        # Check DNS port
        if ! printf '%s\n' "$DNS_PORT" | grep -Eq '^[0-9]{1,5}$' || [ "$DNS_PORT" -lt 1 ] || [ "$DNS_PORT" -gt 65535 ]; then
            _red 'Error: Please enter a valid DNS server port.\n'
            exit 1
        fi

        # Check ipset name
        if [ -z "$IPSET_NAME" ]; then
            WITH_IPSET=0
        else
            IPSET_TEST=$(printf '%s\n' "$IPSET_NAME" | grep -E '^\w+(,\w+)*$' || true)
            if [ "$IPSET_TEST" != "$IPSET_NAME" ]; then
                _red 'Error: Please enter a valid IP set name.\n'
                exit 1
            else
                WITH_IPSET=1
            fi
        fi
    fi

    if [ -n "$EXTRA_DOMAIN_FILE" ] && [ ! -f "$EXTRA_DOMAIN_FILE" ]; then
        _yellow 'WARNING:\nExtra domain file does not exist, ignored.\n\n'
        EXTRA_DOMAIN_FILE=''
    fi

    if [ -n "$EXCLUDE_DOMAIN_FILE" ] && [ ! -f "$EXCLUDE_DOMAIN_FILE" ]; then
        _yellow 'WARNING:\nExclude domain file does not exist, ignored.\n\n'
        EXCLUDE_DOMAIN_FILE=''
    fi
}

process(){
    # Set Global Var
    BASE_URL=${GFWLIST_URL:-https://warp.rm.do/wall-res/list}
    TMP_DIR=$(mktemp -d /tmp/gfwlist2dnsmasq.XXXXXX)
    BASE64_FILE="$TMP_DIR/base64.txt"
    GFWLIST_FILE="$TMP_DIR/gfwlist.txt"
    DOMAIN_TEMP_FILE="$TMP_DIR/gfwlist2domain.tmp"
    DOMAIN_FILE="$TMP_DIR/gfwlist2domain.txt"
    CONF_TMP_FILE="$TMP_DIR/gfwlist.conf.tmp"
    OUT_TMP_FILE="$TMP_DIR/gfwlist.out.tmp"

    # Fetch GfwList and decode it into plain text
    printf 'Fetching GfwList... '
    if [ $USE_WGET = 0 ]; then
        if ! curl --fail --silent --show-error --location --connect-timeout 15 --max-time 120 \
            --retry 2 $CURL_EXTARG -o "$BASE64_FILE" "$BASE_URL"; then
            _red '\nFailed to fetch gfwlist.txt.\n'
            clean_and_exit 2
        fi
    else
        if ! wget -q -T 120 $WGET_EXTARG -O "$BASE64_FILE" "$BASE_URL"; then
            _red '\nFailed to fetch gfwlist.txt.\n'
            clean_and_exit 2
        fi
    fi
    if ! $BASE64_DECODE "$BASE64_FILE" > "$GFWLIST_FILE"; then
        _red 'Failed to decode gfwlist.txt. Quit.\n'
        clean_and_exit 2
    fi
    _green 'Done.\n\n'

    # Convert
    IGNORE_PATTERN='^\!|\[|^@@|(https?://){0,1}[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
    HEAD_FILTER_PATTERN='s#^(\|\|?)?(https?://)?##g'
    TAIL_FILTER_PATTERN='s#/.*$|%2F.*$##g'
    DOMAIN_PATTERN='([a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+)'
    HANDLE_WILDCARD_PATTERN='s#^(([a-zA-Z0-9]*\*[-a-zA-Z0-9]*)?(\.))?([a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+)(\*[a-zA-Z0-9]*)?#\4#g'

    printf 'Converting GfwList to ' && _green $OUT_TYPE && printf ' ...\n' 
    _yellow '\nWARNING:\nThe following lines in GfwList contain regex, and might be ignored:\n\n'
    grep -n '^/.*$' "$GFWLIST_FILE" || true
    _yellow "\nThis script will try to convert some of the regex rules. But you should know this may not be a equivalent conversion.\nIf there's regex rules which this script do not deal with, you should add the domain manually to the list.\n\n"
    tr -d '\r' < "$GFWLIST_FILE" | grep -vE "$IGNORE_PATTERN" | $SED_ERES "$HEAD_FILTER_PATTERN" | $SED_ERES "$TAIL_FILTER_PATTERN" | grep -E "$DOMAIN_PATTERN" | $SED_ERES "$HANDLE_WILDCARD_PATTERN" | $SED_ERES 's/[|^]+$//' > "$TMP_DIR/domains.raw"
    normalize_domains "$TMP_DIR/domains.raw" > "$DOMAIN_TEMP_FILE"
    if [ ! -s "$DOMAIN_TEMP_FILE" ]; then
        _red 'Downloaded gfwlist contains no valid domains; keeping the existing output.\n'
        clean_and_exit 2
    fi

    printf 'google.com\ngoogle.ad\ngoogle.ae\ngoogle.com.af\ngoogle.com.ag\ngoogle.com.ai\ngoogle.al\ngoogle.am\ngoogle.co.ao\ngoogle.com.ar\ngoogle.as\ngoogle.at\ngoogle.com.au\ngoogle.az\ngoogle.ba\ngoogle.com.bd\ngoogle.be\ngoogle.bf\ngoogle.bg\ngoogle.com.bh\ngoogle.bi\ngoogle.bj\ngoogle.com.bn\ngoogle.com.bo\ngoogle.com.br\ngoogle.bs\ngoogle.bt\ngoogle.co.bw\ngoogle.by\ngoogle.com.bz\ngoogle.ca\ngoogle.cd\ngoogle.cf\ngoogle.cg\ngoogle.ch\ngoogle.ci\ngoogle.co.ck\ngoogle.cl\ngoogle.cm\ngoogle.cn\ngoogle.com.co\ngoogle.co.cr\ngoogle.com.cu\ngoogle.cv\ngoogle.com.cy\ngoogle.cz\ngoogle.de\ngoogle.dj\ngoogle.dk\ngoogle.dm\ngoogle.com.do\ngoogle.dz\ngoogle.com.ec\ngoogle.ee\ngoogle.com.eg\ngoogle.es\ngoogle.com.et\ngoogle.fi\ngoogle.com.fj\ngoogle.fm\ngoogle.fr\ngoogle.ga\ngoogle.ge\ngoogle.gg\ngoogle.com.gh\ngoogle.com.gi\ngoogle.gl\ngoogle.gm\ngoogle.gp\ngoogle.gr\ngoogle.com.gt\ngoogle.gy\ngoogle.com.hk\ngoogle.hn\ngoogle.hr\ngoogle.ht\ngoogle.hu\ngoogle.co.id\ngoogle.ie\ngoogle.co.il\ngoogle.im\ngoogle.co.in\ngoogle.iq\ngoogle.is\ngoogle.it\ngoogle.je\ngoogle.com.jm\ngoogle.jo\ngoogle.co.jp\ngoogle.co.ke\ngoogle.com.kh\ngoogle.ki\ngoogle.kg\ngoogle.co.kr\ngoogle.com.kw\ngoogle.kz\ngoogle.la\ngoogle.com.lb\ngoogle.li\ngoogle.lk\ngoogle.co.ls\ngoogle.lt\ngoogle.lu\ngoogle.lv\ngoogle.com.ly\ngoogle.co.ma\ngoogle.md\ngoogle.me\ngoogle.mg\ngoogle.mk\ngoogle.ml\ngoogle.com.mm\ngoogle.mn\ngoogle.ms\ngoogle.com.mt\ngoogle.mu\ngoogle.mv\ngoogle.mw\ngoogle.com.mx\ngoogle.com.my\ngoogle.co.mz\ngoogle.com.na\ngoogle.com.nf\ngoogle.com.ng\ngoogle.com.ni\ngoogle.ne\ngoogle.nl\ngoogle.no\ngoogle.com.np\ngoogle.nr\ngoogle.nu\ngoogle.co.nz\ngoogle.com.om\ngoogle.com.pa\ngoogle.com.pe\ngoogle.com.pg\ngoogle.com.ph\ngoogle.com.pk\ngoogle.pl\ngoogle.pn\ngoogle.com.pr\ngoogle.ps\ngoogle.pt\ngoogle.com.py\ngoogle.com.qa\ngoogle.ro\ngoogle.ru\ngoogle.rw\ngoogle.com.sa\ngoogle.com.sb\ngoogle.sc\ngoogle.se\ngoogle.com.sg\ngoogle.sh\ngoogle.si\ngoogle.sk\ngoogle.com.sl\ngoogle.sn\ngoogle.so\ngoogle.sm\ngoogle.sr\ngoogle.st\ngoogle.com.sv\ngoogle.td\ngoogle.tg\ngoogle.co.th\ngoogle.com.tj\ngoogle.tk\ngoogle.tl\ngoogle.tm\ngoogle.tn\ngoogle.to\ngoogle.com.tr\ngoogle.tt\ngoogle.com.tw\ngoogle.co.tz\ngoogle.com.ua\ngoogle.co.ug\ngoogle.co.uk\ngoogle.com.uy\ngoogle.co.uz\ngoogle.com.vc\ngoogle.co.ve\ngoogle.vg\ngoogle.co.vi\ngoogle.com.vn\ngoogle.vu\ngoogle.ws\ngoogle.rs\ngoogle.co.za\ngoogle.co.zm\ngoogle.co.zw\ngoogle.cat\n' >> $DOMAIN_TEMP_FILE
    printf 'Google search domains... ' && _green 'Added\n'

    # Add blogspot domains
    printf 'blogspot.ca\nblogspot.co.uk\nblogspot.com\nblogspot.com.ar\nblogspot.com.au\nblogspot.com.br\nblogspot.com.by\nblogspot.com.co\nblogspot.com.cy\nblogspot.com.ee\nblogspot.com.eg\nblogspot.com.es\nblogspot.com.mt\nblogspot.com.ng\nblogspot.com.tr\nblogspot.com.uy\nblogspot.de\nblogspot.gr\nblogspot.in\nblogspot.mx\nblogspot.ch\nblogspot.fr\nblogspot.ie\nblogspot.it\nblogspot.pt\nblogspot.ro\nblogspot.sg\nblogspot.be\nblogspot.no\nblogspot.se\nblogspot.jp\nblogspot.in\nblogspot.ae\nblogspot.al\nblogspot.am\nblogspot.ba\nblogspot.bg\nblogspot.ch\nblogspot.cl\nblogspot.cz\nblogspot.dk\nblogspot.fi\nblogspot.gr\nblogspot.hk\nblogspot.hr\nblogspot.hu\nblogspot.ie\nblogspot.is\nblogspot.kr\nblogspot.li\nblogspot.lt\nblogspot.lu\nblogspot.md\nblogspot.mk\nblogspot.my\nblogspot.nl\nblogspot.no\nblogspot.pe\nblogspot.qa\nblogspot.ro\nblogspot.ru\nblogspot.se\nblogspot.sg\nblogspot.si\nblogspot.sk\nblogspot.sn\nblogspot.tw\nblogspot.ug\nblogspot.cat\n' >> $DOMAIN_TEMP_FILE
    printf 'Blogspot domains... ' && _green 'Added\n'

    # Add twimg.edgesuite.net
    printf 'twimg.edgesuite.net\n' >> $DOMAIN_TEMP_FILE
    printf 'twimg.edgesuite.net... ' && _green 'Added\n'

    # Delete exclude domains
    if [ -n "$EXCLUDE_DOMAIN_FILE" ]; then
        normalize_domains "$EXCLUDE_DOMAIN_FILE" 1 > "$TMP_DIR/exclude.txt"
        awk '
            FILENAME == ARGV[1] { excluded[$0] = 1; next }
            {
                domain = $0
                while (1) {
                    if (domain in excluded) next
                    if (!sub(/^[^.]+\./, "", domain)) break
                }
                print
            }
        ' "$TMP_DIR/exclude.txt" "$DOMAIN_TEMP_FILE" > "$DOMAIN_FILE"
        printf 'Domains in exclude domain file %s... ' "$EXCLUDE_DOMAIN_FILE" && _green 'Deleted\n'
    else
        cp "$DOMAIN_TEMP_FILE" "$DOMAIN_FILE"
    fi

    # Add extra domains
    if [ -n "$EXTRA_DOMAIN_FILE" ]; then
        normalize_domains "$EXTRA_DOMAIN_FILE" 1 >> "$DOMAIN_FILE"
        printf 'Extra domain file %s... ' "$EXTRA_DOMAIN_FILE" && _green 'Added\n'
    fi

    sort -u "$DOMAIN_FILE" > "$TMP_DIR/domains.sorted"
    if [ ! -s "$TMP_DIR/domains.sorted" ]; then
        _red 'No domains remain after filtering; keeping the existing output.\n'
        clean_and_exit 2
    fi

    if [ $OUT_TYPE = 'DNSMASQ_RULES' ]; then
    # Convert domains into dnsmasq rules
        if [ $WITH_IPSET -eq 1 ]; then
            _green 'Ipset rules included.'
            $SED_ERES 's#(.+)#server=/\1/'$DNS_IP'\#'$DNS_PORT'\
ipset=/\1/'$IPSET_NAME'#g' "$TMP_DIR/domains.sorted" > "$CONF_TMP_FILE"
        else
            _green 'Ipset rules not included.'
            $SED_ERES 's#(.+)#server=/\1/'$DNS_IP'\#'$DNS_PORT'#g' "$TMP_DIR/domains.sorted" > "$CONF_TMP_FILE"
        fi

        # Generate output file
        echo '# dnsmasq rules generated by gfwlist' > "$OUT_TMP_FILE"
        echo "# Last Updated on $(date "+%Y-%m-%d %H:%M:%S")" >> "$OUT_TMP_FILE"
        echo '# ' >> "$OUT_TMP_FILE"
        cat "$CONF_TMP_FILE" >> "$OUT_TMP_FILE"
    else
        cp "$TMP_DIR/domains.sorted" "$OUT_TMP_FILE"
    fi

    OUT_STAGE=$(mktemp "${OUT_FILE}.tmp.XXXXXX")
    cp "$OUT_TMP_FILE" "$OUT_STAGE"
    mv -f "$OUT_STAGE" "$OUT_FILE"
    OUT_STAGE=''
    printf '\nConverting GfwList to '$OUT_TYPE'... ' && _green 'Done\n\n'

    # Clean up
    clean_and_exit 0
}

main() {
    if [ "$#" -eq 0 ]; then
        usage 0
    else
        check_depends
        get_args "$@"
        _green '\nJob Started.\n\n'
        process
    fi
}

trap cleanup 0
trap 'exit 1' HUP INT TERM
main "$@"
