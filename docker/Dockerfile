# The d2r-cdn CLI in a container: inspect/list/fetch/extract/mirror a build, or run
# the channel watcher as a long-lived service.
#   docker build -f docker/Dockerfile -t d2r-cdn .          (from the repo root)
#   docker run --rm d2r-cdn info
#   docker run --rm -v $PWD/data:/data d2r-cdn extract -o /data/osi
FROM alpine:3.22 AS build
ARG ZIG_VERSION=0.16.0
RUN apk add --no-cache curl tar xz && \
    arch="$(uname -m)" && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
      | tar -xJ -C /opt && \
    ln -s "/opt/zig-${arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
COPY example ./example
RUN zig build -Doptimize=ReleaseFast -Dtarget="$(uname -m)-linux-musl" --prefix /out && \
    zig build test

FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/bin/d2r-cdn /usr/local/bin/d2r-cdn
WORKDIR /data
VOLUME ["/data"]
ENTRYPOINT ["d2r-cdn"]
CMD ["--help"]
