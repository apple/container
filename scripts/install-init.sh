#! /bin/bash -e
# Copyright © 2025-2026 Apple Inc. and the container project authors.
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

usage() {
    cat <<EOF
Usage: $(basename "$0") [-a APP_ROOT | --app-root APP_ROOT] [-l LOG_ROOT | --log-root LOG_ROOT] [-h | --help]

Install the init image for container system.

Options:
    -a, --app-root APP_ROOT    Install the init image under the APP_ROOT path
    -l, --log-root LOG_ROOT    Install the init image under the LOG_ROOT path
    -h, --help                 Show this help message

EOF
    exit 0
}

# Parse command line options
START_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--app-root)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Option $1 requires an argument." >&2
                usage
            fi
            START_ARGS+=(--app-root "$2")
            shift 2
            ;;
        -l|--log-root)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Option $1 requires an argument." >&2
                usage
            fi
            START_ARGS+=(--log-root "$2")
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Invalid option: $1" >&2
            usage
            ;;
    esac
done

SWIFT="/usr/bin/swift"
IMAGE_NAME="vminit:latest"

CONTAINERIZATION_VERSION="$(${SWIFT} package show-dependencies --format json | jq -r '.dependencies[] | select(.identity == "containerization") | .version')"
if [ "${CONTAINERIZATION_VERSION}" == "unspecified" ] ; then
	CONTAINERIZATION_PATH="$(${SWIFT} package show-dependencies --format json | jq -r '.dependencies[] | select(.identity == "containerization") | .path')"
	if [ ! -d "${CONTAINERIZATION_PATH}" ] ; then
		echo "editable containerization directory at ${CONTAINERIZATION_PATH} does not exist"
		exit 1
	fi
	echo "Creating InitImage"
	make -C ${CONTAINERIZATION_PATH} init
	${CONTAINERIZATION_PATH}/bin/cctl images save -o /tmp/init.tar ${IMAGE_NAME}

	# Sleep because commands after stop and start are racy.
	bin/container system stop
    sleep 3
	bin/container --debug system start "${START_ARGS[@]}"
	sleep 3
	bin/container i load -i /tmp/init.tar
	rm /tmp/init.tar
fi
