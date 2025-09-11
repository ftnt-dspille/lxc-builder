FROM debian:trixie AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies (cached layer)
RUN apt-get update && apt-get install -y --no-install-recommends \
    lxc lxc-templates debootstrap xz-utils tar zip ca-certificates gnupg \
    curl wget apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# Copy build script separately for better layer caching
COPY build-lxc.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/build-lxc.sh

# Set default build args with backwards compatibility
ARG DIST=debian
ARG RELEASE=trixie
ARG ARCH=amd64
ARG VARIANT=cloud

# Use build args as environment variables
ENV DIST=${DIST} \
    RELEASE=${RELEASE} \
    ARCH=${ARCH} \
    VARIANT=${VARIANT}

# Create necessary directories
RUN mkdir -p /out /var/cache/lxc /work

# Set working directory
WORKDIR /

ENTRYPOINT ["/usr/local/bin/build-lxc.sh"]