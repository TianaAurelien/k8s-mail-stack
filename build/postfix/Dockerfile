FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    postfix \
    postfix-mysql \
    bsd-mailx \
    ca-certificates \
    libsasl2-modules \
    libsasl2-modules-db \
    mariadb-client \
    mariadb-common \
    netbase \
    iproute2 \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# On s'assure que Postfix tourne en avant-plan pour le container
CMD ["postfix", "start-fg"]
