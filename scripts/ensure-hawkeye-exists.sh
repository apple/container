#!/usr/bin/env bash
# Copyright © 2025-2026 Apple Inc. and the container project authors.
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

set -e

auto_install=0

for arg in "$@"; do
    case "$arg" in
        --auto-install|-y)
            auto_install=1
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--auto-install|-y]

Checks for a working hawkeye installation under .local/bin/.
If hawkeye is missing, prompts before running scripts/install-hawkeye.sh.

Skip the prompt non-interactively in either of two ways:
  --auto-install, -y      pass on the command line
  HAWKEYE_AUTO_INSTALL=1  set in the environment
EOF
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            echo "see '$(basename "$0") --help' for usage" >&2
            exit 2
            ;;
    esac
done

if [[ "${HAWKEYE_AUTO_INSTALL:-}" == "1" ]]; then
    auto_install=1
fi

echo "Checking existence of hawkeye..."

if command -v .local/bin/hawkeye >/dev/null 2>&1; then
    echo "hawkeye found!"
    exit 0
fi

cat <<EOF

hawkeye is not installed.

scripts/install-hawkeye.sh will install it by running:

    curl -LsSf https://github.com/korandoru/hawkeye/releases/download/<version>/hawkeye-installer.sh | sh

and performs the installation by passing the downloaded content to \`sh\`.

(See scripts/install-hawkeye.sh for the pinned version.)
EOF

if [[ "$auto_install" -eq 1 ]]; then
    echo
    echo "Auto-install enabled; proceeding."
elif [[ ! -t 0 ]]; then
    echo
    echo "Non-interactive context detected. Refusing to install silently." >&2
    echo "Set HAWKEYE_AUTO_INSTALL=1 or pass --auto-install to proceed." >&2
    exit 1
else
    echo
    read -r -p "Proceed with install? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            ;;
        *)
            echo "please install hawkeye. For convenience, you can run scripts/install-hawkeye.sh"
            exit 1
            ;;
    esac
fi

exec "$(dirname "$0")/install-hawkeye.sh"
