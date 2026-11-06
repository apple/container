//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

/// Container machine user setup, embedded as a literal and exec'd directly
/// inside the guest (as `sh -c "\(MachineUserSetup.script)"`) rather than
/// shipped as a file. Intended to be image-agnostic by directly manipulating
/// /etc/group, /etc/passwd, and /etc/shadow rather than relying on
/// image-specific tools (useradd, adduser, etc.).
///
/// Safe to run on every boot: user/shadow creation and home directory
/// population only happen once (guarded by looking the account up by both
/// uid and username), while the sudoers entry is cheaply reasserted every
/// run. If the image already has a *different* account using the requested
/// uid or username, or anything already exists at the requested home path,
/// setup fails loudly instead of silently skipping — proceeding could mean
/// resolving to the wrong account, creating a duplicate/ambiguous passwd
/// entry, or recursively chowning pre-existing content that isn't ours.
///
/// Expects CONTAINER_USER, CONTAINER_UID, CONTAINER_GID, and CONTAINER_HOME
/// to be set in the environment.
public enum MachineUserSetup {
    public static let script = #"""
        set -e

        . /etc/os-release 2>/dev/null || true
        case "${ID:-}" in
            ubuntu|debian)
                CONTAINER_SHELL=$(unset DSHELL; . /etc/adduser.conf 2>/dev/null \
                    && [ -n "${DSHELL:-}" ] \
                    && echo "${DSHELL}") || CONTAINER_SHELL=/bin/bash ;;
            *)
                CONTAINER_SHELL=$(unset SHELL; . /etc/default/useradd 2>/dev/null \
                    && [ -n "${SHELL:-}" ] \
                    && echo "${SHELL}") || CONTAINER_SHELL=/bin/sh ;;
        esac

        if ! getent group "${CONTAINER_GID}" >/dev/null 2>&1; then
            echo "${CONTAINER_USER}:x:${CONTAINER_GID}:" >> /etc/group
        fi

        existing_by_uid=$(getent passwd "${CONTAINER_UID}" 2>/dev/null) || true
        existing_by_name=$(getent passwd "${CONTAINER_USER}" 2>/dev/null) || true

        if [ -n "${existing_by_uid}" ] || [ -n "${existing_by_name}" ]; then
            if [ "${existing_by_uid}" != "${existing_by_name}" ]; then
                echo "container machine: refusing to provision user '${CONTAINER_USER}' (uid ${CONTAINER_UID}): a different account in this image already uses this uid or username" >&2
                exit 1
            fi
            # Otherwise this is our own account from a previous boot: nothing to do.
        else
            if [ -e "${CONTAINER_HOME}" ]; then
                echo "container machine: refusing to use existing path '${CONTAINER_HOME}' as the home directory for user '${CONTAINER_USER}'" >&2
                exit 1
            fi

            echo "${CONTAINER_USER}:x:${CONTAINER_UID}:${CONTAINER_GID}::${CONTAINER_HOME}:${CONTAINER_SHELL}" >> /etc/passwd
            echo "${CONTAINER_USER}:!:$(($(date +%s) / 86400)):0:99999:7:::" >> /etc/shadow

            mkdir -p "${CONTAINER_HOME}"
            if [ -d /etc/skel ]; then
                cp -a /etc/skel/. "${CONTAINER_HOME}"
            fi
            chown -R "${CONTAINER_UID}:${CONTAINER_GID}" "${CONTAINER_HOME}"
        fi

        mkdir -p /etc/sudoers.d
        sudoers_file=$(echo "${CONTAINER_USER}" | tr '.' '_')
        echo "${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${sudoers_file}"
        chmod 440 "/etc/sudoers.d/${sudoers_file}"
        """#
}
