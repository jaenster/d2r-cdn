# The d2r-cdn CLI as a container. Zig cross-compiles, so the build stage always runs
# on the native runner arch and emits a static musl binary for the target arch - a
# multi-arch image without QEMU.
#
#   docker build -f docker/Dockerfile -t d2r-cdn .     (from the repo root)
#   docker run --rm d2r-cdn info
FROM --platform=$BUILDPLATFORM alpine:3.22 AS build
ARG ZIG_VERSION=0.16.0
ARG BUILDARCH
ARG TARGETARCH
RUN apk add --no-cache curl tar xz && \
    case "$BUILDARCH" in \
      amd64) host=x86_64 ;; \
      arm64) host=aarch64 ;; \
      *) echo "no zig build for $BUILDARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${host}-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt && \
    ln -s "/opt/zig-${host}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
COPY example ./example
RUN case "$TARGETARCH" in \
      amd64) zt=x86_64-linux-musl ;; \
      arm64) zt=aarch64-linux-musl ;; \
      *) echo "no zig target for $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    zig build -Doptimize=ReleaseFast -Dtarget="$zt" --prefix /out

FROM alpine:3.22
LABEL org.opencontainers.image.source="https://github.com/jaenster/d2r-cdn" \
      org.opencontainers.image.description="Fetch and extract Diablo II: Resurrected files from Blizzard's CDN (NGDP/TACT)" \
      org.opencontainers.image.licenses="MIT"
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/bin/d2r-cdn /usr/local/bin/d2r-cdn
WORKDIR /data
VOLUME ["/data"]
ENTRYPOINT ["d2r-cdn"]
CMD ["--help"]
