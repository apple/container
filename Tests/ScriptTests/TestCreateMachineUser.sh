#!/bin/sh
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

#
# Tests for Sources/Plugins/MachineAPIServer/Resources/create-user.sh, exercised
# against a throwaway /etc via CONTAINER_ETC_ROOT.
#

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
create_user="${script_dir}/../../Sources/Plugins/MachineAPIServer/Resources/create-user.sh"

work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT

# create-user.sh chowns the home directory, so the cases have to provision a UID
# and GID this process can actually give files away to.
uid=$(id -u)
gid=$(id -g)
# A UID that is not `uid`, for the conflicting-name case.
other_uid=$((uid + 1))

failures=0
current_case=""

fail() {
    echo "  FAIL: $1" >&2
    failures=$((failures + 1))
}

# Builds a fresh fake root and echoes its path. Any arguments are appended to
# /etc/passwd as pre-existing image accounts.
new_root() {
    root=$(mktemp -d "${work_dir}/caseXXXXXX")
    mkdir -p "${root}/etc"
    printf 'root:x:0:0:root:/root:/bin/bash\n' > "${root}/etc/passwd"
    printf 'root:x:0:\n' > "${root}/etc/group"
    : > "${root}/etc/shadow"
    for entry in "$@"; do
        printf '%s\n' "${entry}" >> "${root}/etc/passwd"
    done
    echo "${root}"
}

# Runs create-user.sh against a fake root. Echoes nothing; sets run_status.
run_create_user() {
    root="$1"
    # create-user.sh runs as root in the guest, where rewriting the 0440 sudoers
    # file it left behind on an earlier boot is allowed. This suite runs
    # unprivileged, so restore the write bit to emulate that.
    [ -e "${root}/etc/sudoers.d" ] && chmod -R u+w "${root}/etc/sudoers.d"
    set +e
    CONTAINER_ETC_ROOT="${root}/etc" \
    CONTAINER_USER="${2}" \
    CONTAINER_UID="${3}" \
    CONTAINER_GID="${4}" \
    CONTAINER_HOME="${root}/home/${2}" \
    CONTAINER_SHELL="${5}" \
        sh "${create_user}" >"${root}/stdout" 2>"${root}/stderr"
    run_status=$?
    set -e
}

passwd_field() {
    awk -F: -v u="$2" -v f="$3" '$1 == u { print $f; exit }' "$1/etc/passwd"
}

count_entries() {
    awk -F: -v u="$2" '$1 == u { n++ } END { print n + 0 }' "$1/etc/passwd"
}

start_case() {
    current_case="$1"
    echo "- ${current_case}"
}

# ---------------------------------------------------------------------------
start_case "creates the account when neither the name nor the UID is taken"
root=$(new_root)
run_create_user "${root}" alice "${uid}" "${gid}" /bin/zsh
[ "${run_status}" -eq 0 ] || fail "exited ${run_status}: $(cat "${root}/stderr")"
[ "$(passwd_field "${root}" alice 3)" = "${uid}" ] || fail "expected UID ${uid}, got $(passwd_field "${root}" alice 3)"
[ "$(passwd_field "${root}" alice 7)" = "/bin/zsh" ] || fail "expected shell /bin/zsh, got $(passwd_field "${root}" alice 7)"
grep -q '^alice:' "${root}/etc/shadow" || fail "no shadow entry"
grep -q "^alice:x:${gid}:" "${root}/etc/group" || fail "no group entry"
[ -f "${root}/etc/sudoers.d/alice" ] || fail "no sudoers entry"

# ---------------------------------------------------------------------------
# The regression this suite exists for: the image already holds the requested
# UID under a different name, so keying on the UID would skip creation and
# leave the machine's username unresolvable.
start_case "creates a name alias when the UID belongs to another image account"
root=$(new_root "ubuntu:x:${uid}:${gid}:Ubuntu:/home/ubuntu:/bin/bash")
run_create_user "${root}" alice "${uid}" "${gid}" /bin/zsh
[ "${run_status}" -eq 0 ] || fail "exited ${run_status}: $(cat "${root}/stderr")"
[ "$(passwd_field "${root}" alice 3)" = "${uid}" ] || fail "alice did not resolve to UID ${uid}"
[ "$(passwd_field "${root}" ubuntu 3)" = "${uid}" ] || fail "pre-existing ubuntu entry was disturbed"
[ "$(passwd_field "${root}" alice 7)" = "/bin/zsh" ] || fail "alias did not keep its own shell"

# ---------------------------------------------------------------------------
start_case "is idempotent across repeated boots"
root=$(new_root "ubuntu:x:${uid}:${gid}:Ubuntu:/home/ubuntu:/bin/bash")
run_create_user "${root}" alice "${uid}" "${gid}" /bin/zsh
[ "${run_status}" -eq 0 ] || fail "first run exited ${run_status}: $(cat "${root}/stderr")"
run_create_user "${root}" alice "${uid}" "${gid}" /bin/zsh
[ "${run_status}" -eq 0 ] || fail "second run exited ${run_status}: $(cat "${root}/stderr")"
[ "$(count_entries "${root}" alice)" = "1" ] || fail "expected 1 passwd entry, got $(count_entries "${root}" alice)"
[ "$(grep -c '^alice:' "${root}/etc/shadow")" = "1" ] || fail "duplicate shadow entry"

# ---------------------------------------------------------------------------
start_case "fails loudly when the name exists under a different UID"
root=$(new_root "alice:x:${other_uid}:${gid}:Image account:/home/alice:/bin/sh")
run_create_user "${root}" alice "${uid}" "${gid}" /bin/zsh
[ "${run_status}" -ne 0 ] || fail "expected a non-zero exit"
grep -q "already exists" "${root}/stderr" || fail "expected an explanatory message, got: $(cat "${root}/stderr")"
[ "$(passwd_field "${root}" alice 3)" = "${other_uid}" ] || fail "the image account was modified"
[ "$(count_entries "${root}" alice)" = "1" ] || fail "a duplicate name entry was appended"

# ---------------------------------------------------------------------------
start_case "reuses an existing group with the requested GID"
root=$(new_root)
printf 'staff:x:%s:\n' "${gid}" >> "${root}/etc/group"
run_create_user "${root}" alice "${uid}" "${gid}" /bin/zsh
[ "${run_status}" -eq 0 ] || fail "exited ${run_status}: $(cat "${root}/stderr")"
! grep -q "^alice:x:${gid}:" "${root}/etc/group" || fail "appended a second group for GID ${gid}"
[ "$(passwd_field "${root}" alice 4)" = "${gid}" ] || fail "primary GID is not ${gid}"

# ---------------------------------------------------------------------------
if [ "${failures}" -eq 0 ]; then
    echo "create-user.sh: all cases passed"
    exit 0
fi
echo "create-user.sh: ${failures} failure(s)" >&2
exit 1
