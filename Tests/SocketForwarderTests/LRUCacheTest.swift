//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
        let cache = LRUCache<String, String>(size: 3)
        #expect(cache.count == 0)

        #expect(cache.put(key: "foo", value: "1") == nil)
        #expect(cache.count == 1)

        #expect(cache.put(key: "bar", value: "2") == nil)
        #expect(cache.count == 2)

        #expect(cache.put(key: "baz", value: "3") == nil)
        #expect(cache.count == 3)

        let replaced = try #require(cache.put(key: "bar", value: "4"))
        #expect(replaced == ("bar", "2"))
        #expect(cache.count == 3)

        let firstEvicted = try #require(cache.put(key: "qux", value: "5"))
        #expect(firstEvicted == ("foo", "1"))
        #expect(cache.count == 3)

        let secondEvicted = try #require(cache.put(key: "quux", value: "6"))
        #expect(secondEvicted == ("baz", "3"))
        #expect(cache.count == 3)

        #expect(cache.get("foo") == nil)
        #expect(cache.get("bar") == "4")
        #expect(cache.get("baz") == nil)
        #expect(cache.get("qux") == "5")
        #expect(cache.get("quux") == "6")
    }
}
