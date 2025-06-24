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

opts=()
if [ ! -z "${CURRENT_SDK}" ] ; then
    opts+=("-Xswiftc" "-DCURRENT_SDK")
fi
opts+=("--allow-writing-to-directory" "$1")
opts+=("generate-documentation")
opts+=("--target" "ContainerSandboxService")
opts+=("--target" "ContainerNetworkService")
opts+=("--target" "ContainerImagesService")
opts+=("--target" "ContainerClient")
opts+=("--target" "ContainerLog")
opts+=("--target" "ContainerPlugin")
opts+=("--target" "ContainerXPC")
opts+=("--target" "TerminalProgress")
opts+=("--output-path" "$1")
opts+=("--disable-indexing")
opts+=("--transform-for-static-hosting")
opts+=("--enable-experimental-combined-documentation")
opts+=("--experimental-documentation-coverage")

if [ ! -z "$2" ] ; then
    opts+=("--hosting-base-path" "$2")
fi

/usr/bin/swift package ${opts[@]}

echo '{}' > "$1/theme-settings.json"

cat > "$1/index.html" <<'EOF'
<html lang="en-US">
  <head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0; url=./documentation/">
  </head>
  <body>
    <p>If you are not redirected automatically, <a href="./documentation/">click here</a>.</p>
  </body>
</html>
EOF
