# syntax=docker/dockerfile:1
# Lumora push bridge (optional; wakes iPhones with content-free APNs pushes).
# Build context MUST be the Rust workspace (core/):
#   docker build -f relay/push/Dockerfile -t lumora-push core          (from repo root)
# See docs/src/ops/push.md.

FROM rust:1-bookworm AS build
WORKDIR /src
ARG JOBS=
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked -p lumora-push ${JOBS:+-j $JOBS} \
 && install -Dm755 target/release/lumora-push /out/lumora-push

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin lumora \
 && mkdir -p /data /keys && chown lumora /data
COPY --from=build /out/lumora-push /usr/local/bin/lumora-push
USER lumora
WORKDIR /data
# /data keeps the bridge key (bridge.key) and the dead-token list; mount the APNs .p8 at /keys.
ENV LUMORA_PUSH_LISTEN=0.0.0.0:8099 \
    LUMORA_PUSH_STATE=/data \
    RUST_LOG=info
EXPOSE 8099/tcp
VOLUME ["/data"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/lumora-push"]
