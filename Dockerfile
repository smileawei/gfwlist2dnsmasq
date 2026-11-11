FROM alpine:3.24

RUN apk upgrade --no-cache \
    && apk add --no-cache \
        dnsmasq \
        bash \
        curl \
        ca-certificates \
        tzdata \
    && mkdir -p /etc/dnsmasq.d /opt/dnsmasq-chn/scripts /opt/dnsmasq-chn/conf/upstreams

COPY scripts/*.sh /opt/dnsmasq-chn/scripts/
COPY dnsmasq.conf /etc/dnsmasq.conf

RUN chmod +x /opt/dnsmasq-chn/scripts/*.sh

EXPOSE 53/udp 53/tcp

HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
    CMD nslookup baidu.com 127.0.0.1 >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/opt/dnsmasq-chn/scripts/entrypoint.sh"]
