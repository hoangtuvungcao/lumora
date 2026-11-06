# syntax=docker/dockerfile:1
# Lumora relay image. Build context MUST be the Rust workspace (core/):
#   docker build -f ../relay/vps/Dockerfile -t lumora-relay ../../core      (from relay/vps)
#   docker build -f relay/vps/Dockerfile -t lumora-relay core              (from repo root)
# docker-compose.yml in this folder already does this.

FROM rust:1-bookworm AS build
WORKDIR /src
# Optional: limit parallel rustc jobs on small VPSes (docker build --build-arg JOBS=2 ...)
ARG JOBS=
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked -p lumora-relay ${JOBS:+-j $JOBS} \
 && install -Dm755 target/release/lumora-relay /out/lumora-relay

FROM debian:bookworm-slim
RUN useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin lumora \
 && mkdir -p /data && chown lumora /data
COPY --from=build /out/lumora-relay /usr/local/bin/lumora-relay
USER lumora
WORKDIR /data
ENV LUMORA_RELAY_LISTEN=0.0.0.0:8443 \
    LUMORA_RELAY_MAILBOX_FILE=/data/mailbox.bin \
    RUST_LOG=info
EXPOSE 8443/tcp 3478/udp
VOLUME ["/data"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/lumora-relay"]
