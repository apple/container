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

import Foundation

/// DockerfileTokenizer takes as input a line from a dockerfile and outputs an array
/// of Tokens that represent the line's contents
struct DockerfileTokenizer {
    private let input: String
    private var position: String.Index
    private let endPosition: String.Index

    public init(_ from: String) {
        input = from
        position = input.startIndex
        endPosition = input.endIndex
    }

    mutating func getTokens() throws -> [Token] {
        var results = [Token]()

        while position < endPosition {
            let char = input[position]
            if char.isWhitespace {
                // ignore white spaces that are not part of other things
                position = input.index(after: position)
                continue
            }

            if char == "\"" || char == "'" {
                position = input.index(after: position)  // do not include the initial quote
                let start = position
                parseQuotedString()

                let quote = String(input[start..<position])
                if !quote.isEmpty {
                    results.append(.stringLiteral(quote))
                }
            } else if char == "[" {
                let listToken = try parseJSON()
                results.append(listToken)
            } else if char == "#" {
                parseComment()
            } else if char == "-" {
                results.append(parseOption())
            } else {
                let start = position
                parseWord()
                let word = String(input[start..<position])
                results.append(.stringLiteral(word))
            }

            if position < endPosition {
                position = input.index(after: position)
            }
        }

        return results
    }

    mutating private func parseWord() {
        while position < endPosition {
            let char = input[position]
            if char.isWhitespace {
                break
            }
            position = input.index(after: position)
        }
    }

    mutating private func parseQuotedString() {
        while position < endPosition {
            let char = input[position]
            if char == "\"" || char == "'" {
                break
            }
            position = input.index(after: position)
        }
    }

    mutating private func parseJSON() throws -> Token {
        let start = position
        while position < endPosition {
            let char = input[position]
            if char == "]" {
                // we want to include the ending ] in the rawJSON so that swift can
                // correctly handle decoding the value
                position = input.index(after: position)
                break
            }
            position = input.index(after: position)
        }
        let rawJSON = String(input[start..<position])

        let data = rawJSON.data(using: .utf8)
        guard let data = data else {
            throw ParseError.invalidSyntax
        }

        let list = try JSONDecoder().decode([String].self, from: data)
        return .stringList(list)
    }

    mutating private func parseComment() {
        while position < endPosition {
            // continue until the end of the line
            position = input.index(after: position)
        }
    }

    mutating private func parseOption() -> Token {
        let wordStart = position
        parseWord()

        let rawWord = input[wordStart..<position]
        guard rawWord.contains("=") else {
            // skip whitespace
            while position < endPosition && input[position].isWhitespace {
                position = input.index(after: position)
                continue
            }
            let valueStart = position
            parseWord()
            let rawValue = input[valueStart..<position]
            let raw = input[wordStart..<position]
            return .option(Option(key: String(rawWord), value: String(rawValue), raw: String(raw)))
        }
        // split by equal
        let optionComponents = rawWord.split(separator: "=", maxSplits: 1)
        return .option(Option(key: String(optionComponents[0]), value: String(optionComponents[1]), raw: String(rawWord)))
    }
}
