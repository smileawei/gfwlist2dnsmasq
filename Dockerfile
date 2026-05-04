FROM alpine:3.21

RUN apk add --no-cache \
        dnsmasq \
        bash \
        curl \
        ca-certificates \
        tzdata \
        bind-tools \
    && mkdir -p /etc/dnsmasq.d /opt/dnsmasq-chn/scripts /opt/dnsmasq-chn/conf

COPY scripts/gfwlist2dnsmasq.sh scripts/update.sh scripts/entrypoint.sh /opt/dnsmasq-chn/scripts/
COPY dnsmasq.conf /etc/dnsmasq.conf

RUN chmod +x /opt/dnsmasq-chn/scripts/*.sh

EXPOSE 53/udp 53/tcp

HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
    CMD nslookup -timeout=3 baidu.com 127.0.0.1 >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/opt/dnsmasq-chn/scripts/entrypoint.sh"]
