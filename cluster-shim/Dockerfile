# Build image for cluster-shim: the Swift toolchain, the Static Linux SDK for
# static musl binaries, make, and protoc for generating the gRPC sources. The
# Makefile's `image` target passes the SDK URL and checksum and the protoc version.
ARG SWIFT_VERSION=6.3.0
FROM swift:${SWIFT_VERSION}-noble

ARG SWIFT_SDK_URL
ARG SWIFT_SDK_CHECKSUM
ARG PROTOC_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends make curl unzip \
    && rm -rf /var/lib/apt/lists/*

# protoc and its well-known types, installed under /usr/local.
RUN case "$(uname -m)" in \
        aarch64) arch=aarch_64 ;; \
        x86_64) arch=x86_64 ;; \
        *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/protoc.zip \
        "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-${arch}.zip" \
    && unzip -q -o /tmp/protoc.zip -d /usr/local bin/protoc 'include/*' \
    && rm /tmp/protoc.zip

RUN swift sdk install "${SWIFT_SDK_URL}" --checksum "${SWIFT_SDK_CHECKSUM}"
