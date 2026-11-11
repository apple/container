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

# Check everything that can be checked quickly before the slow pre-warm, so a
# missing dependency fails here instead of on camera.
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "error: the demo must be recorded on a Mac with Apple silicon."
    exit 1
fi

# ttyd and ffmpeg are VHS dependencies, but VHS only reports them once it starts.
missing=()
for tool in vhs ttyd ffmpeg gifsicle; do
    if ! command -v "${tool}" >/dev/null; then
        missing+=("${tool}")
    fi
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "error: missing ${missing[*]}. Install with: brew install ${missing[*]}"
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

if ! container machine --help >/dev/null 2>&1; then
    echo "error: $(command -v container) doesn't support container machines. Use a newer build of container."
    exit 1
fi

# The demo publishes its web server on this port.
if listener=$(lsof -nP -iTCP:8080 -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 { print $1 " (pid " $2 ")" }') && [ -n "${listener}" ]; then
    echo "error: port 8080 is in use by ${listener}. Stop it before recording."
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

# The demo installs a package on camera, so make sure the Ubuntu archive is reachable.
if ! container run --rm "${MACHINE_IMAGE}" sh -c 'cd /tmp && apt-get download -q fastfetch' >/dev/null 2>&1; then
    echo "error: couldn't download packages from the Ubuntu archive. Check your network connection."
    exit 1
fi

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

# The tape records into .build/demo-gif. The committed GIF is only replaced
# once the recording passes the checks below.
SCRATCH_GIF=.build/demo-gif/landing-movie.gif
TRANSCRIPT=.build/demo-gif/landing-movie.txt
GIF=docs/assets/landing-movie.gif

echo "Recording..."
cd "${ROOT_DIR}"
vhs "${DEMO_ASSETS}/landing-movie.tape"

# The transcript has a snapshot of the screen after every tape command. Only
# check for things that mean the demo is broken, not for output that changes
# between versions.
echo "Checking the recording..."
problems=0
if errors=$(grep -E 'command not found|No such file or directory|Permission denied|^Error: |^E: |^curl: \(' "${TRANSCRIPT}"); then
    echo "error: the recording shows errors:"
    echo "${errors}" | sort -u
    problems=1
fi
for expected in 'Hello, world!' 'jappleseed@ubuntu:'; do
    if ! grep -qF "${expected}" "${TRANSCRIPT}"; then
        echo "error: the recording never shows \"${expected}\"."
        problems=1
    fi
done
if [ "$(whoami)" != jappleseed ]; then
    if grep -qw "$(whoami)" "${TRANSCRIPT}" || grep -qF "${HOME}" "${TRANSCRIPT}"; then
        echo "error: the recording shows your username or home directory."
        problems=1
    fi
fi
if [ ${problems} -ne 0 ]; then
    echo "The transcript is at ${TRANSCRIPT}. ${GIF} wasn't updated."
    exit 1
fi

# VHS writes a frame for every tick. Merge unchanged frames and store only
# what changes between frames. This is lossless, so the text stays sharp.
echo "Optimizing..."
gifsicle -O3 "${SCRATCH_GIF}" -o "${GIF}"

echo "Wrote ${GIF} ($(ls -lh "${GIF}" | awk '{ print $5 }'))."
