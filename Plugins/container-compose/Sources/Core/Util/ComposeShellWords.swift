//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
//===----------------------------------------------------------------------===//

import ContainerizationError
import Foundation

enum ComposeShellWords {
    private enum QuoteState {
        case single
        case double
    }

    static func split(_ input: String) throws -> [String] {
        guard !input.isEmpty else {
            return []
        }

        var result: [String] = []
        var current = ""
        var quoteState: QuoteState?
        var escaping = false
        var startedToken = false

        func finishToken() {
            guard startedToken || !current.isEmpty else {
                return
            }
            result.append(current)
            current.removeAll(keepingCapacity: true)
            startedToken = false
        }

        for character in input {
            if escaping {
                current.append(character)
                startedToken = true
                escaping = false
                continue
            }

            switch quoteState {
            case .single:
                if character == "'" {
                    quoteState = nil
                } else {
                    current.append(character)
                }
                startedToken = true
            case .double:
                if character == "\"" {
                    quoteState = nil
                } else if character == "\\" {
                    escaping = true
                    startedToken = true
                } else {
                    current.append(character)
                    startedToken = true
                }
            case nil:
                if character == "\\" {
                    escaping = true
                    startedToken = true
                } else if character == "'" {
                    quoteState = .single
                    startedToken = true
                } else if character == "\"" {
                    quoteState = .double
                    startedToken = true
                } else if character.isWhitespace {
                    finishToken()
                } else {
                    current.append(character)
                    startedToken = true
                }
            }
        }

        if escaping {
            throw ContainerizationError(.invalidArgument, message: "Invalid command string: trailing escape")
        }
        if quoteState != nil {
            throw ContainerizationError(.invalidArgument, message: "Invalid command string: unterminated quote")
        }

        finishToken()
        return result
    }
}
