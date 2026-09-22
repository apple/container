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
# First-time container user setup. Intended to be container machine-agnostic
# by directly manipulating /etc/group, /etc/passwd, and /etc/shadow rather
# than relying on image-specific tools (useradd, adduser, etc.). Also
# populates the home directory from /etc/skel and grants passwordless sudo
# access.
#
# Expects CONTAINER_USER, CONTAINER_UID, CONTAINER_GID, and CONTAINER_HOME to
# be set in the environment.
#
# The account is keyed on CONTAINER_USER rather than CONTAINER_UID. An image
# may already ship an account holding the requested numeric UID under a
# different name (for example `ubuntu` at UID 1000), and the machine is run
# under CONTAINER_USER, so that name has to resolve in /etc/passwd. When the
# UID is already taken the entry is added as a second name for the same
# numeric identity, which is a valid and long-standing passwd arrangement.
#
# CONTAINER_ETC_ROOT overrides /etc, for testing. Lookups read the files
# directly instead of calling getent so that the override applies to them too;
# the guest resolves users and groups from files.
#

set -e

etc_root="${CONTAINER_ETC_ROOT:-/etc}"
passwd_file="${etc_root}/passwd"
group_file="${etc_root}/group"
shadow_file="${etc_root}/shadow"

# Print field $2 of the first line whose field $1 equals the given key.
lookup_field() {
    file="$1"
    key_field="$2"
    key="$3"
    out_field="$4"

    [ -f "${file}" ] || return 0
    awk -F: -v kf="${key_field}" -v k="${key}" -v of="${out_field}" \
        '$kf == k { print $of; exit }' "${file}"
}

if [ -z "$(lookup_field "${group_file}" 3 "${CONTAINER_GID}" 3)" ]; then
    echo "${CONTAINER_USER}:x:${CONTAINER_GID}:" >> "${group_file}"
fi

existing_uid=$(lookup_field "${passwd_file}" 1 "${CONTAINER_USER}" 3)
if [ -n "${existing_uid}" ] && [ "${existing_uid}" != "${CONTAINER_UID}" ]; then
    echo "container machine user '${CONTAINER_USER}' already exists in the image with UID ${existing_uid}, but the machine runs as UID ${CONTAINER_UID}" >&2
    echo "refusing to run as an unrelated account; use an image without a conflicting '${CONTAINER_USER}' account" >&2
    exit 1
fi

if [ -z "${existing_uid}" ]; then
    echo "${CONTAINER_USER}:x:${CONTAINER_UID}:${CONTAINER_GID}::${CONTAINER_HOME}:${CONTAINER_SHELL}" >> "${passwd_file}"
    echo "${CONTAINER_USER}:!:19000:0:99999:7:::" >> "${shadow_file}"
fi

mkdir -p "${CONTAINER_HOME}"
if [ -d "${etc_root}/skel" ]; then
    cp -a "${etc_root}/skel/." "${CONTAINER_HOME}"
fi
chown -R "${CONTAINER_UID}:${CONTAINER_GID}" "${CONTAINER_HOME}"

mkdir -p "${etc_root}/sudoers.d"
sudoers_file=$(echo "${CONTAINER_USER}" | tr '.' '_')
echo "${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL" > "${etc_root}/sudoers.d/${sudoers_file}"
chmod 440 "${etc_root}/sudoers.d/${sudoers_file}"
