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

set -e

if ! getent group "${CONTAINER_GID}" >/dev/null 2>&1; then
    echo "${CONTAINER_USER}:x:${CONTAINER_GID}:" >> /etc/group
fi

if ! getent passwd "${CONTAINER_UID}" >/dev/null 2>&1; then
    echo "${CONTAINER_USER}:x:${CONTAINER_UID}:${CONTAINER_GID}::${CONTAINER_HOME}:${CONTAINER_SHELL}" >> /etc/passwd
    echo "${CONTAINER_USER}:!:19000:0:99999:7:::" >> /etc/shadow
fi

mkdir -p "${CONTAINER_HOME}"
if [ -d /etc/skel ]; then
    cp -a /etc/skel/. "${CONTAINER_HOME}"
fi
chown -R "${CONTAINER_UID}:${CONTAINER_GID}" "${CONTAINER_HOME}"

mkdir -p /etc/sudoers.d
echo "${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${CONTAINER_USER}"
chmod 440 "/etc/sudoers.d/${CONTAINER_USER}"
