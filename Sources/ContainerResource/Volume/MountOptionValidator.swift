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

/// Checks that the share and driver options of a network-backed volume are syntactically valid.
///
/// The options are joined into a comma-separated `key=value` string before they reach the guest
/// kernel's mount, so a value that contains a comma, whitespace, or a control character could smuggle
/// in extra options. The share is different: it is the mount source, which is passed to `mount(2)` as
/// its own argument and never joined into the options string, so it only needs to be a well-formed
/// string. The API server checks both when a volume is created and again when a container is created,
/// and the runtime checks them once more before mounting, so none of them takes values read from a
/// client or from storage on faith.
package enum MountOptionValidator {
    /// The key under which the share is carried in the driver options.
    package static let shareKey = "share"

    /// The most characters a key may have.
    package static let keyLengthMax = 64

    /// The most characters a value may have.
    package static let valueLengthMax = 1024

    /// The most characters a share may have.
    package static let shareLengthMax = 4096

    /// A rule that an option breaks. The description says which option and why.
    ///
    /// The description never includes the value, since a value may be a credential.
    package struct Violation: Error, CustomStringConvertible, Equatable {
        package let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    /// Checks that the share of a network mount is well formed.
    ///
    /// A share may contain spaces and commas, which are common in SMB share names, since it is never
    /// joined into the options string. It must not be empty or contain control characters, which would
    /// truncate or corrupt the C string handed to `mount(2)`.
    ///
    /// - Parameter share: The share, such as `//server/share` or `server:/export/path`.
    /// - Throws: `Violation` if the share breaks a rule.
    package static func validateShare(_ share: String) throws {
        guard !share.isEmpty else {
            throw Violation("share must not be empty")
        }
        let sharePattern = #/^[^\p{Cc}]{1,4096}$/#
        guard share.wholeMatch(of: sharePattern) != nil else {
            throw Violation("invalid share: must not contain control characters, with at most \(Self.shareLengthMax) characters")
        }
    }

    /// Checks that every key and value in `options` follows the rules.
    ///
    /// - A key starts with a letter and contains only letters, digits, `_`, and `-`, with at most
    ///   `keyLengthMax` characters.
    /// - A value contains no commas, whitespace, or control characters, with at most `valueLengthMax`
    ///   characters. An empty value denotes a bare flag such as `nolock`.
    ///
    /// The share, if present under `shareKey`, is checked with `validateShare` instead, since it is
    /// not joined into the options string. Options are checked in key order, so the same input always
    /// produces the same error.
    ///
    /// - Parameter options: The driver options, as parsed from `--opt key=value`.
    /// - Throws: `Violation` for the first option that breaks a rule.
    package static func validate(_ options: [String: String]) throws {
        let keyPattern = #/^[A-Za-z][A-Za-z0-9_-]{0,63}$/#
        let valuePattern = #/^[^,\s\p{Cc}]{0,1024}$/#

        for key in options.keys.sorted() {
            guard let value = options[key] else {
                continue
            }
            if key == Self.shareKey {
                try Self.validateShare(value)
                continue
            }
            guard key.wholeMatch(of: keyPattern) != nil else {
                throw Violation(
                    "invalid mount option key \"\(key)\": must start with a letter and contain only letters, digits, '_', or '-', with at most \(Self.keyLengthMax) characters"
                )
            }
            guard value.wholeMatch(of: valuePattern) != nil else {
                throw Violation(
                    "invalid value for mount option \"\(key)\": must not contain commas, whitespace, or control characters, with at most \(Self.valueLengthMax) characters"
                )
            }
        }
    }
}
