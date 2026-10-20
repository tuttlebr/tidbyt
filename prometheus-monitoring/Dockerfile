ARG BASE_IMAGE=ubuntu:24.04

FROM $BASE_IMAGE

ARG PIXLET_VERSION=0.34.0
ARG TARGETARCH

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in amd64|arm64) ;; *) echo "Unsupported architecture: $arch"; exit 1 ;; esac; \
    archive="pixlet_${PIXLET_VERSION}_linux_${arch}.tar.gz"; \
    url="https://github.com/tidbyt/pixlet/releases/download/v${PIXLET_VERSION}"; \
    mkdir /tmp/pixlet; \
    cd /tmp/pixlet; \
    curl --fail --show-error --location --retry 3 --connect-timeout 10 --max-time 120 -o "$archive" "$url/$archive"; \
    curl --fail --show-error --location --retry 3 --connect-timeout 10 --max-time 120 -o checksums.txt "$url/checksums.txt"; \
    awk -v archive="$archive" '$2 == archive { print }' checksums.txt | sha256sum --check --strict -; \
    tar -xzf "$archive" pixlet; \
    install -m 0755 pixlet /usr/local/bin/pixlet; \
    rm -rf /tmp/pixlet

WORKDIR /workspace
COPY prometheus-monitoring.star ./
COPY --chmod=755 daemonize-push.sh ./
ENTRYPOINT ["/bin/bash", "/workspace/daemonize-push.sh"]
