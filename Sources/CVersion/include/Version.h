/*
 * Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//===----------------------------------------------------------------------===//
//
// This source file is part of the container open source project
//
// Copyright (c) 2025 Apple Inc. and the container project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of container project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#ifndef CZ_VERSION
#define CZ_VERSION "latest"
#endif

#ifndef GIT_COMMIT
#define GIT_COMMIT "unspecified"
#endif

#ifndef RELEASE_VERSION
#define RELEASE_VERSION "0.0.0"
#endif

#ifndef BUILDER_SHIM_VERSION
#define BUILDER_SHIM_VERSION "0.0.0"
#endif

const char* get_git_commit();

const char* get_release_version();

const char* get_swift_containerization_version();

const char* get_container_builder_shim_version();
