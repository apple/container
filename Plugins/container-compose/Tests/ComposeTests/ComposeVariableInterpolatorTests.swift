//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
//===----------------------------------------------------------------------===//

import ContainerizationError
import Testing
@testable import ComposeCore

struct ComposeVariableInterpolatorTests {
    @Test
    func testInterpolateSupportsComposeDefaultOperators() throws {
        let values = [
            "SET": "value",
            "EMPTY": "",
            "PWD": "/workspace",
        ]

        let result = try ComposeVariableInterpolator.interpolate(
            "a=${UNSET-default} b=${UNSET:-fallback} c=${EMPTY-default} d=${EMPTY:-fallback} e=${MAIN_GIT_DIR:-$PWD/.git}"
        ) {
            values[$0]
        }

        #expect(result == "a=default b=fallback c= d=fallback e=/workspace/.git")
    }

    @Test
    func testInterpolateSupportsComposeAlternativeOperators() throws {
        let values = [
            "SET": "value",
            "EMPTY": "",
        ]

        let result = try ComposeVariableInterpolator.interpolate(
            "a=${SET+alt} b=${EMPTY+alt} c=${UNSET+alt} d=${SET:+alt} e=${EMPTY:+alt} f=${UNSET:+alt}"
        ) {
            values[$0]
        }

        #expect(result == "a=alt b=alt c= d=alt e= f=")
    }

    @Test
    func testInterpolateRejectsInvalidVariableName() throws {
        #expect {
            _ = try ComposeVariableInterpolator.interpolate("${$(echo hacked)}") { _ in nil }
        } throws: { error in
            guard let containerError = error as? ContainerizationError else { return false }
            return containerError.message.contains("Invalid environment variable name")
        }
    }
}
