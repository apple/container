#!/bin/bash 
# Copyright © 2025 Apple Inc. and the container project authors.
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

set -uo pipefail

INSTALL_DIR="/usr/local"
DELETE_DATA=
OPTS=0

usage() { 
    echo "Usage: $0 {-d | -k}"
    echo "Uninstall container" 
    echo 
    echo "Options:"
    echo "d     Delete user data directory."
    echo "k     Don't delete user data directory."
    echo 
    exit 1
}

while getopts ":dk" arg; do
    case "$arg" in
        d)
            DELETE_DATA=true
            ((OPTS+=1))
            ;;
        k)
            DELETE_DATA=false
            ((OPTS+=1))
            ;;
        *)
            echo "Invalid option: -${OPTARG}"
            usage
            ;;
    esac
done

if [ $OPTS != 1 ]; then 
    echo "Invalid number of options. Must provide either -d OR -k"
    usage
    exit 1
fi

# check if container is still running 
CONTAINER_RUNNING=$(launchctl list | grep -e 'com\.apple\.container\W')
if [ -n "$CONTAINER_RUNNING" ]; then
    echo '`container` is still running. Please ensure the service is stopped by running `container system stop`'
    exit 1
fi

FILES=$(pkgutil --only-files --files com.apple.container-installer)
for i in ${FILES[@]}; do
    # this command can fail for some of the reported files from pkgutil such as 
    # `/usr/local/bin/._uninstall-container.sh``
    sudo rm $INSTALL_DIR/$i &> /dev/null
done


DIRS=($(pkgutil --only-dirs --files com.apple.container-installer))
for ((i=${#DIRS[@]}-1; i>=0; i--)); do 
    # this command will fail when trying to remove `bin` and `libexec` since those directories
    # may not be empty
    sudo rmdir $INSTALL_DIR/${DIRS[$i]} &> /dev/null
done

sudo pkgutil --forget com.apple.container-installer > /dev/null
echo 'Removed `container` tool and helpers'

if [ "$DELETE_DATA" = true ]; then
    echo 'Removing `container` user data'
    sudo rm -rf ~/Library/Application\ Support/com.apple.container
fi
