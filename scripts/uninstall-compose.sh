@ -0,0 +1,41 @@
#!/bin/bash
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

set -e

echo "Uninstalling Compose plugin..."

COMPOSE_PLUGIN_DIR="/usr/local/libexec/container/plugins/compose"
COMPOSE_BIN="$COMPOSE_PLUGIN_DIR/bin/compose"
COMPOSE_CONFIG="$COMPOSE_PLUGIN_DIR/config.json"

if [ -f "$COMPOSE_BIN" ]; then
    echo "Removing compose binary: $COMPOSE_BIN"
    rm -f "$COMPOSE_BIN"
fi

if [ -f "$COMPOSE_CONFIG" ]; then
    echo "Removing compose config: $COMPOSE_CONFIG"
    rm -f "$COMPOSE_CONFIG"
fi

if [ -d "$COMPOSE_PLUGIN_DIR/bin" ]; then
    rmdir "$COMPOSE_PLUGIN_DIR/bin" 2>/dev/null || true
fi
if [ -d "$COMPOSE_PLUGIN_DIR" ]; then
    rmdir "$COMPOSE_PLUGIN_DIR" 2>/dev/null || true
fi

echo "Compose plugin has been removed."
