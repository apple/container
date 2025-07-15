//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import Testing

@testable import SocketForwarder

struct LRUCacheTest {
    @Test
    func testLRUCache() throws {
        let cache = LRUCache<String, String>()
        #expect(cache.count == 0)
        try cache.put(key: "foo", value: "1")
        try cache.put(key: "bar", value: "2")
        try cache.put(key: "baz", value: "3")
        #expect(throws: KeyExistsError.self) {
            _ = try cache.put(key: "bar", value: "4")
        }
        #expect(cache.count == 3)

        #expect(cache.get("foo") == "1")
        #expect(cache.get("bar") == "2")
        #expect(cache.get("baz") == "3")
        #expect(cache.get("qux") == nil)

        #expect(cache.evict() ?? ("nil", "nil") == ("foo", "1"))
        #expect(cache.evict() ?? ("nil", "nil") == ("bar", "2"))
        #expect(cache.evict() ?? ("nil", "nil") == ("baz", "3"))
        #expect(cache.evict() == nil)
        #expect(cache.count == 0)
    }
}
