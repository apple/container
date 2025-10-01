//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
//===----------------------------------------------------------------------===//

import Testing
@testable import ComposePlugin

struct LogPrefixTests {

    @Test func testPlainPrefixPadding() {
        let s = LogPrefixFormatter.coloredPrefix(for: "api", width: 6, colorEnabled: false)
        #expect(s == "api    | ")
    }

    @Test func testPlainPrefixTruncate() {
        let name = String(repeating: "x", count: 50)
        // width param simulates the capped width TargetsUtil returns (<= 40)
        let s = LogPrefixFormatter.coloredPrefix(for: name, width: 40, colorEnabled: false)
        #expect(s == String(repeating: "x", count: 40) + " | ")
    }
}
