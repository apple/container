#! /bin/bash -e
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

SWIFT="/usr/bin/swift"
IMAGE_NAME="vminit:latest"
DESTDIR="${1:-$(git rev-parse --show-toplevel)/bin}"
mkdir -p "${DESTDIR}"

CONTAINERIZATION_VERSION="${CONTAINERIZATION_VERSION:-$(${SWIFT} package show-dependencies --format json | jq -r '.dependencies[] | select(.identity == "containerization") | .version')}"
if [ ! -z "${CONTAINERIZATION_PATH}" -o "${CONTAINERIZATION_VERSION}" == "unspecified" ] ; then
	CONTAINERIZATION_PATH="${CONTAINERIZATION_PATH:-$(${SWIFT} package show-dependencies --format json | jq -r '.dependencies[] | select(.identity == "containerization") | .path')}"
	echo "Creating InitImage"
	make -C ${CONTAINERIZATION_PATH} init
	${CONTAINERIZATION_PATH}/bin/cctl images save -o /tmp/init.tar ${IMAGE_NAME}
	# Sleep because commands after stop and start are racy.
	bin/container system stop && sleep 3 && bin/container system start && sleep 3
	bin/container i load -i /tmp/init.tar
	rm /tmp/init.tar
fi
