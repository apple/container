#! /bin/bash -e
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Records docs/assets/landing-movie.gif from docs/assets/demo/landing-movie.tape.
#
# Set CONTAINER_BIN_DIR to record with a local build (for example, ./bin)
# instead of the `container` on your PATH.
#
# VHS renders the terminal in a headless browser. If it can't find Chrome, it
# downloads Chromium to ~/.cache/rod the first time it runs.

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
DEMO_ASSETS="${ROOT_DIR}/docs/assets/demo"
DEMO_DIR="${HOME}/hello"
CONTAINER_NAME=web
MACHINE_NAME=ubuntu
MACHINE_IMAGE=ubuntu-machine:26.10

if [ -n "${CONTAINER_BIN_DIR}" ]; then
    PATH="$(cd "${CONTAINER_BIN_DIR}" && pwd):${PATH}"
    export PATH
fi

if ! command -v vhs >/dev/null; then
    echo "error: vhs is not installed. Install it with: brew install vhs"
    exit 1
fi

if ! command -v gifsicle >/dev/null; then
    echo "error: gifsicle is not installed. Install it with: brew install gifsicle"
    exit 1
fi

# The tape uses SF Mono, which browsers can only use once it's installed as a
# regular font (it isn't by default).
if ! compgen -G "/Library/Fonts/SF*Mono*" >/dev/null && ! compgen -G "${HOME}/Library/Fonts/SF*Mono*" >/dev/null; then
    echo "error: the SF Mono font is not installed. Download it from https://developer.apple.com/fonts/"
    exit 1
fi

if [ -e "${DEMO_DIR}" ]; then
    echo "error: the demo records in ${DEMO_DIR}, which already exists. Move it aside before recording."
    exit 1
fi

if ! command -v container >/dev/null; then
    echo "error: container is not on your PATH."
    exit 1
fi

echo "Recording with $(command -v container) ($(container --version))."
echo "This restarts the container system service."

container system start --enable-kernel-install
container builder stop >/dev/null 2>&1 || true

if [ -n "$(container ls -q)" ]; then
    echo "error: stop your running containers before recording, so they don't appear in the demo."
    exit 1
fi

if container ls -a -q | grep -qx "${CONTAINER_NAME}"; then
    echo "error: a container named '${CONTAINER_NAME}' already exists. Delete it before recording."
    exit 1
fi

if [ -n "$(container machine ls | awk 'NR > 1')" ]; then
    echo "error: delete your container machines before recording, so they don't appear in the demo."
    exit 1
fi

cleanup() {
    container stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    container rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    container machine rm "${MACHINE_NAME}" >/dev/null 2>&1 || true
    if [ -n "${DEMO_DIR_CREATED}" ]; then
        rm -rf "${DEMO_DIR}"
    fi
}
trap cleanup EXIT

echo "Pre-warming images..."
container image pull python:slim
container build -t "${MACHINE_IMAGE}" "${DEMO_ASSETS}"
container builder stop

# Stop the service so that the recorded `container system start` is real.
container system stop || echo "warning: couldn't stop the container system service; continuing."

# A small project in your home directory, so the container machine can see it:
# a Swift package, plus a Keynote file that's clearly from a Mac. Cleanup only
# removes the directory if it was created here.
mkdir "${DEMO_DIR}"
DEMO_DIR_CREATED=1
mkdir -p "${DEMO_DIR}/Sources/Hello" "${DEMO_DIR}/Tests/HelloTests"
cat >"${DEMO_DIR}/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hello",
    targets: [
        .executableTarget(name: "Hello"),
        .testTarget(name: "HelloTests", dependencies: ["Hello"]),
    ]
)
EOF
cat >"${DEMO_DIR}/Sources/Hello/main.swift" <<'EOF'
print("Hello, world!")
EOF
cat >"${DEMO_DIR}/README.md" <<'EOF'
# Hello
EOF
touch "${DEMO_DIR}/Design.key"

export DEMO_DIR
export DEMO_ENV="${DEMO_ASSETS}/demo-env.bash"

echo "Recording..."
cd "${ROOT_DIR}"
vhs "${DEMO_ASSETS}/landing-movie.tape"

# VHS writes a frame for every tick. Merge unchanged frames and store only
# what changes between frames. This is lossless, so the text stays sharp.
echo "Optimizing..."
gifsicle -O3 --batch docs/assets/landing-movie.gif

echo "Wrote docs/assets/landing-movie.gif ($(ls -lh docs/assets/landing-movie.gif | awk '{ print $5 }'))."
