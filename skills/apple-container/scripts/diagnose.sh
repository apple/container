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

set -u

section() {
  printf '\n== %s ==\n' "$1"
}

run() {
  printf '$ %s\n' "$*"
  "$@" 2>&1 || true
}

section "Host"
run sw_vers
run uname -m

section "Container CLI"
if ! command -v container >/dev/null 2>&1; then
  echo "container CLI not found on PATH"
  exit 0
fi
run container --version

section "System Status"
run container system status

section "Networks"
run container network list
run container network inspect default

section "Host Routes"
netstat -rn -f inet 2>/dev/null | grep -E 'default|192\.168\.64|utun|bridge' || true

section "Container Network Smoke Test"
container run --rm docker.io/library/alpine:latest sh -lc '
  echo "--- /etc/resolv.conf ---"
  cat /etc/resolv.conf
  echo "--- route ---"
  (ip route 2>/dev/null || route -n 2>/dev/null || true)
  echo "--- ping gateway ---"
  ping -c 1 -W 3 "$(awk "/nameserver/ {print \$2; exit}" /etc/resolv.conf)" 2>&1 || true
  echo "--- ping public ip ---"
  ping -c 1 -W 3 1.1.1.1 2>&1 || true
  echo "--- dns ---"
  nslookup github.com 2>&1 || true
' || true

section "Recent System Logs"
container system logs --last 80 2>&1 | tail -80 || true

cat <<'EOF'

If images pull but ping/DNS fails inside containers, check for VPN or endpoint
security routes that overlap 192.168.64.0/24 or block vmnet NAT. Try disabling
the VPN, then run:

  container system stop
  container system start
  container run --rm docker.io/library/alpine:latest sh -lc 'nslookup github.com'
EOF
