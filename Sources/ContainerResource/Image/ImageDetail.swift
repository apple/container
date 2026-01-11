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

import Containerization
import ContainerizationOCI

public struct ImageDetail: Codable {
    public let name: String
    public let index: Descriptor
    public let variants: [Variants]

    public struct Variants: Codable {
        public let platform: Platform
        public let config: ContainerizationOCI.Image
        public let size: Int64

        public init(platform: Platform, size: Int64, config: ContainerizationOCI.Image) {
            self.platform = platform
            self.config = config
            self.size = size
        }
    }

    public init(name: String, index: Descriptor, variants: [Variants]) {
        self.name = name
        self.index = index
        self.variants = variants
    }
}
