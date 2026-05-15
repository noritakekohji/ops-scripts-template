FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

# Install tools required by the scripts
RUN apt-get update && apt-get install -y \
    bash \
    python3 \
    iputils-ping \
    iproute2 \
    net-tools \
    procps \
    util-linux \
    dnsutils \
    traceroute \
    netcat-openbsd \
    curl \
    lsblk \
    && rm -rf /var/lib/apt/lists/*

# Locale (for correct UTF-8 output)
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

WORKDIR /ops
