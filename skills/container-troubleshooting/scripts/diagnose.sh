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

smoke_test=false
last_status=0

usage() {
  cat <<'EOF'
Usage: diagnose.sh [--smoke-test] [--help]

Collect bounded diagnostics for Apple's container CLI.

The default run is read-only. --smoke-test may pull alpine:latest and runs a
disposable container to test its route, DNS, and HTTPS access.

Review output before sharing it. Names, image references, routes, IP addresses,
filesystem paths, and recent system logs can contain private information.
EOF
}

while (($# > 0)); do
  case "$1" in
    --smoke-test)
      smoke_test=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Error: unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

section() {
  printf '\n== %s ==\n' "$1"
}

run() {
  printf '$'
  printf ' %q' "$@"
  printf '\n'
  "$@" 2>&1
  last_status=$?
  if ((last_status != 0)); then
    printf '[exit %d]\n' "$last_status"
  fi
  return 0
}

section "Privacy notice"
printf '%s\n' \
  "Review this output before sharing it. It may include private environment details." \
  "The collector does not upload diagnostics."

section "Host"
run sw_vers
macos_status=$last_status
macos_version=$(sw_vers -productVersion 2>/dev/null || true)
run uname -m
arch_status=$last_status
host_arch=$(uname -m 2>/dev/null || true)
run launchctl managername

host_supported=true
if ((macos_status != 0)) || [[ ! "${macos_version%%.*}" =~ ^[0-9]+$ ]] ||
    ((10#${macos_version%%.*} < 26)); then
  host_supported=false
fi
if ((arch_status != 0)) || [[ "$host_arch" != "arm64" ]]; then
  host_supported=false
fi

section "Container CLI"
container_path=$(command -v container 2>/dev/null || true)
if [[ -z "$container_path" ]]; then
  printf 'container CLI not found on PATH\n'
  printf '\n== Summary ==\n'
  printf 'Host supported: %s\n' "$host_supported"
  printf 'CLI available: false\n'
  printf 'System service: not checked\n'
  printf 'Smoke test: not run\n'
  exit 0
fi
printf 'Path: %s\n' "$container_path"
run container --version

section "System service"
run container system status
service_status=$last_status
run container system version

if ((service_status == 0)); then
  run container system property list

  section "Resources"
  run container list --all
  run container network list
  run container network inspect default
  run container builder status
  run container machine list
else
  printf 'Skipping service-dependent resource checks because system status failed.\n'
fi

section "Host IPv4 routes"
run netstat -rn -f inet

section "Recent container system logs"
printf '$ container system logs --last 10m | tail -n 200\n'
container system logs --last 10m 2>&1 | tail -n 200
logs_status=${PIPESTATUS[0]}
if ((logs_status != 0)); then
  printf '[container system logs exited %d]\n' "$logs_status"
fi

smoke_result="not requested"
if $smoke_test; then
  section "Disposable container network smoke test"
  if ((service_status != 0)); then
    printf 'Skipped because container system status failed.\n'
    smoke_result="skipped: system service unavailable"
  else
    run container run --rm docker.io/library/alpine:latest sh -lc '
      echo "--- route ---"
      ip route 2>/dev/null || route -n 2>/dev/null || true
      echo "--- /etc/resolv.conf ---"
      cat /etc/resolv.conf
      echo "--- raw IP (ICMP advisory only) ---"
      ping -c 1 -W 3 1.1.1.1 || true
      echo "--- external DNS ---"
      nslookup github.com
      dns_status=$?
      echo "--- external HTTPS ---"
      wget -q -T 10 -O /dev/null https://github.com
      https_status=$?
      if [ "$dns_status" -ne 0 ] || [ "$https_status" -ne 0 ]; then
        exit 1
      fi
    '
    if ((last_status == 0)); then
      smoke_result="passed"
    else
      smoke_result="failed"
    fi
  fi
fi

section "Summary"
printf 'Host supported: %s\n' "$host_supported"
printf 'CLI available: true\n'
if ((service_status == 0)); then
  printf 'System service: healthy\n'
else
  printf 'System service: unavailable or unhealthy\n'
fi
printf 'Smoke test: %s\n' "$smoke_result"
