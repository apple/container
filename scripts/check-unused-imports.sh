#!/bin/bash -e
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

echo "Checking existence of swiftlint..."

if ! command -v swiftlint >/dev/null; then
    echo "swiftlint not found in PATH"
    echo "please install swiftlint. You can run brew install swiftlint"
    exit 1
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
BUILD_LOG=${PROJECT_ROOT}/.build/build.log
LINT_LOG=${PROJECT_ROOT}/.build/swiftlint.log

echo 'Building `container` with verbose flag'
if [ ! -f ${BUILD_LOG} ];
then
    make -C ${PROJECT_ROOT} clean
    make -C ${PROJECT_ROOT} BUILD_OPTIONS="-v &>${BUILD_LOG}"
fi

# Get changed Swift files from git diff main
CHANGED_SWIFT_FILES=$(git diff main --name-only | grep '\.swift$' || true)

if [ -z "$CHANGED_SWIFT_FILES" ]; then
    echo "No Swift files changed, skipping swiftlint analysis"
    touch ${LINT_LOG}
else
    echo "Analyzing changed Swift files:"
    # Convert to absolute paths and pass to swiftlint
    ABSOLUTE_PATHS=()
    while IFS= read -r file; do
        if [ -n "$file" ]; then
            echo "  - $file"
            ABSOLUTE_PATHS+=("${PROJECT_ROOT}/${file}")
        fi
    done <<< "$CHANGED_SWIFT_FILES"
    swiftlint analyze --compiler-log-path ${BUILD_LOG} "${ABSOLUTE_PATHS[@]}" 2>/dev/null > ${LINT_LOG}

    echo -e "\nUnused imports:\n"
    cat ${LINT_LOG} | grep "Unused Import"
fi
