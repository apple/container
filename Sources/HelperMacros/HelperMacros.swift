//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

//
//  HelperMacros.swift
//  container
//
//  Created by Morris Richman on 10/3/25.
//

import Foundation

/// Creates a function in OptionGroups called `passThroughCommands` to return an array of strings to be appended and passed down for Plugin support.
@attached(member, names: named(passThroughCommands))
public macro OptionGroupPassthrough() = #externalMacro(module: "HelperMacrosMacros", type: "OptionGroupPassthrough")
