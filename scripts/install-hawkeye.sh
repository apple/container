#!/usr/bin/env bash 
# Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

if command -v .local/bin/hawkeye >/dev/null 2>&1; then
    echo "hawkeye already installed"
else
    echo "Installing hawkeye"
    export VERSION=v6.1.0
    curl --proto '=https' --tlsv1.2 -LsSf https://github.com/korandoru/hawkeye/releases/download/${VERSION}/hawkeye-installer.sh | CARGO_HOME=.local sh -s -- --no-modify-path
fi
