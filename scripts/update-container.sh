#!/bin/bash
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

set -uo pipefail

INSTALL_DIR="/usr/local"
OPTS=0
LATEST=false
VERSION=
FORCE=false
TMP_DIR=

# Release Info
RELEASE_URL=
RELEASE_JSON=
RELEASE_VERSION=

# Package Info
PKG_URL=
PKG_FILE=
SIGNED_PRIMARY_PKG=
SIGNED_FALLBACK_PKG=
UNSIGNED_PRIMARY_PKG=
UNSIGNED_FALLBACK_PKG=

check_installed_version() {
    local target_version="$1"
    if command -v container &>/dev/null; then
        local installed_version
        installed_version=$(container --version | awk '{print $4}')
        installed_version=${installed_version%\)}
        if [[ "$installed_version" == "$target_version" ]]; then
            return 0
        fi
    fi
    return 1
}

usage() {
    echo "Usage: $0 {-v <version> | -f}"
    echo "Update container"
    echo
    echo "Options:"
    echo "v <version>     Update to a specific release version"
    echo "f               Force update"
    echo "No argument     Defaults to the latest release version"
    exit 1
}

while getopts ":v:f" arg; do
    case "$arg" in
        v)
            VERSION="$OPTARG"
            ((OPTS+=1))
            ;;
        f)
            FORCE=true
            ;;
        *)
            echo "Invalid option: -${OPTARG}"
            usage
            ;;
    esac
done

# Default to upgrade to the latest release version
if [[ -z "$VERSION" ]]; then
    LATEST=true
fi

# Check if container is still running
CONTAINER_RUNNING=$(launchctl list | grep -e 'com\.apple\.container\W')
if [ -n "$CONTAINER_RUNNING" ]; then
    echo '`container` is still running. Please ensure the service is stopped by running `container system stop`'
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "This script requires admin privileges to update files under $INSTALL_DIR"
fi

# Temporary directory creation for install/download
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
error() { echo "Error: $*" >&2; exit 1; }

# Determine the release URL and version
if [[ "$LATEST" == true ]]; then
    RELEASE_URL="https://api.github.com/repos/apple/container/releases/latest"
    RELEASE_VERSION=$(curl -fsSL "$RELEASE_URL" | jq -r '.tag_name')
    if check_installed_version "$RELEASE_VERSION" && [[ "$FORCE" != true ]]; then
        echo "Container is already on latest version $RELEASE_VERSION (use -f to force update)"
        exit 0
    else
        echo "Updating to latest version $RELEASE_VERSION"
    fi
elif [[ -n "$VERSION" ]]; then
    RELEASE_URL="https://api.github.com/repos/apple/container/releases/tags/$VERSION"
    RELEASE_VERSION="$VERSION"
    if check_installed_version "$RELEASE_VERSION" && [[ "$FORCE" != true ]]; then
        echo "Container is already on version $RELEASE_VERSION (use -f to force update)"
        exit 0
    else
        echo "Updating to release version $RELEASE_VERSION"
    fi
fi

# Fetch the release json
RELEASE_JSON=$(curl -fsSL "$RELEASE_URL") || {
    error $([[ "$LATEST" == true ]] && echo "Failed fetching latest release" || echo "Release '$VERSION' not found")
}

# Possible package names
SIGNED_PRIMARY_PKG="container-installer-signed.pkg"
SIGNED_FALLBACK_PKG="container-$RELEASE_VERSION-installer-signed.pkg"
UNSIGNED_PRIMARY_PKG="container-installer-unsigned.pkg"
UNSIGNED_FALLBACK_PKG="container-$RELEASE_VERSION-installer-unsigned.pkg"

# Find the signed package
PKG_URL=$(echo "$RELEASE_JSON" | jq -r \
    --arg primary "$SIGNED_PRIMARY_PKG" \
    --arg fallback "$SIGNED_FALLBACK_PKG" \
    '.assets[] | select(.name == $primary or .name == $fallback) | .browser_download_url' | head -n1)

# If no signed package found, prompt and try unsigned
if [[ -z "$PKG_URL" ]]; then
    read -r -p "No signed package found. Upgrade using the unsigned package instead? (Y/n): " confirm
    if [[ "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
        echo "NOTE: re-run this script to upgrade to the signed package, when it becomes available"
        PKG_URL=$(echo "$RELEASE_JSON" | jq -r \
            --arg u1 "$UNSIGNED_PRIMARY_PKG" \
            --arg u2 "$UNSIGNED_FALLBACK_PKG" \
            '.assets[] | select(.name == $u1 or .name == $u2) | .browser_download_url' | head -n1)
    else
        echo "Exiting without updating"
        exit 0
    fi
fi
[[ -n "$PKG_URL" ]] || error "No suitable package found"

PKG_FILE="$TMP_DIR/$(basename "$PKG_URL")"

echo "Downloading package from: $PKG_URL..."
curl -fSL "$PKG_URL" -o "$PKG_FILE"
[[ -s "$PKG_FILE" ]] || error "Downloaded package is empty"

echo "Installing package to $INSTALL_DIR..."
sudo installer -pkg "$PKG_FILE" -target / >/dev/null 2>&1 || error "Installer failed"

echo "Updated successfully"
container --version || error "'container' command not found"
