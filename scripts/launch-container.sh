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

error() {
    echo "Error: $1" >&2
    exit 1
}

# Add /usr/local/bin to PATH
PATH=$PATH:/usr/local/bin

# Check that required commands are installed
command -v container >/dev/null 2>&1 || error "container CLI is not installed"

# Start the container system
container system start || error "Failed to start container system"
