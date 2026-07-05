# Multi-stage build for VMaNGOS (mangosd + realmd), built from source —
# no Wine, no bundled Windows MySQL. Both stages use the same base image to
# avoid ABI mismatches between the compiled binaries and the runtime libs.
#
# Data (maps/vmaps/mmaps) and the database are never baked into this image —
# they're mounted at runtime (see entrypoint.sh and the server.sh
# run-docker/run-k8s commands). warden_modules is the exception: it's small
# (a few MB) and static like the compiled binaries themselves, not large or
# mutable like the game data, so it's simplest to just bake it in rather
# than add a third runtime mount/storage-source choice for it.

ARG SUPPORTED_CLIENT_BUILD=5875

FROM ubuntu:22.04 AS builder
ARG SUPPORTED_CLIENT_BUILD

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    g++ \
    openssl \
    libace-dev \
    libmysqlclient-dev \
    libssl-dev \
    libtbb-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

ENV ACE_ROOT=/usr/include/ace
ENV TBB_ROOT_DIR=/usr/include/tbb

COPY src /root/vmangos/src
RUN mkdir -p /root/vmangos/build /out \
    && cmake -S /root/vmangos/src -B /root/vmangos/build \
        -DDEBUG=0 \
        -DUSE_EXTRACTORS=0 \
        -DSUPPORTED_CLIENT_BUILD="${SUPPORTED_CLIENT_BUILD}" \
        -DCMAKE_INSTALL_PREFIX=/out \
    && make -C /root/vmangos/build -j"$(nproc)" \
    && make -C /root/vmangos/build install

FROM ubuntu:22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    libace-dev \
    libmysqlclient-dev \
    libssl-dev \
    libtbb-dev \
    zlib1g \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Note: -dev packages are kept in the runtime stage for now (pulls in the
# matching runtime .so without needing to pin exact versioned runtime
# package names, which vary by Ubuntu point release). Worth trimming to
# just the runtime libs once a working build is confirmed — see the
# "known risks" note in the implementation plan.

RUN useradd -r -m -d /app -s /usr/sbin/nologin vmangos
WORKDIR /app

COPY --from=builder /out/bin/mangosd /app/bin/mangosd
COPY --from=builder /out/bin/realmd  /app/bin/realmd
COPY warden_modules /app/bin/warden_modules
COPY entrypoint.sh /app/entrypoint.sh
# mangosd/realmd have their config-file path baked in at compile time from
# CMAKE_INSTALL_PREFIX (/out above) — they always look for
# /out/etc/{mangosd,realmd}.conf specifically, regardless of where the
# binaries are actually run from. /out/etc must pre-exist and be writable by
# the unprivileged runtime user, since entrypoint.sh copies the real config
# (mounted read-only at /app/etc) there at container start.
RUN mkdir -p /out/etc \
    && chmod +x /app/entrypoint.sh \
    && chown -R vmangos:vmangos /app /out

# realmd (login/realmlist) — hardcoded on the WoW client, always 3724.
EXPOSE 3724/tcp
# mangosd (world server) — configurable, but this repack defaults to 8085.
EXPOSE 8085/tcp

USER vmangos
ENTRYPOINT ["/app/entrypoint.sh"]
