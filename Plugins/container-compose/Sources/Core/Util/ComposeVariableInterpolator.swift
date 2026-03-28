//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
//===----------------------------------------------------------------------===//

import ContainerizationError
import Foundation

enum ComposeVariableInterpolator {
    private static let maxInterpolationDepth = 16

    static func interpolate(
        _ input: String,
        lookup: (String) -> String?
    ) throws -> String {
        try interpolate(input, lookup: lookup, depth: 0)
    }

    private static func interpolate(
        _ input: String,
        lookup: (String) -> String?,
        depth: Int
    ) throws -> String {
        guard depth < maxInterpolationDepth else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Variable interpolation nesting is too deep"
            )
        }

        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            guard character == "$" else {
                output.append(character)
                index = input.index(after: index)
                continue
            }

            let nextIndex = input.index(after: index)
            guard nextIndex < input.endIndex else {
                output.append(character)
                break
            }

            let nextCharacter = input[nextIndex]
            if nextCharacter == "$" {
                output.append("$")
                index = input.index(after: nextIndex)
                continue
            }

            if nextCharacter == "{" {
                let expressionStart = input.index(after: nextIndex)
                let expressionEnd = try findClosingBrace(in: input, from: expressionStart)
                let expression = String(input[expressionStart..<expressionEnd])
                let replacement = try resolve(expression: expression, lookup: lookup, depth: depth)
                output.append(replacement)
                index = input.index(after: expressionEnd)
                continue
            }

            if isValidNameStart(nextCharacter) {
                let nameEnd = scanNameEnd(in: input, from: nextIndex)
                let name = String(input[nextIndex..<nameEnd])
                output.append(lookup(name) ?? "")
                index = nameEnd
                continue
            }

            output.append(character)
            index = nextIndex
        }

        return output
    }

    private static func resolve(
        expression: String,
        lookup: (String) -> String?,
        depth: Int
    ) throws -> String {
        let parsed = try parse(expression: expression)
        let value = lookup(parsed.name)

        switch parsed.operator {
        case .none:
            return value ?? ""
        case .defaultIfUnset:
            if let value {
                return value
            }
            return try interpolate(parsed.operand, lookup: lookup, depth: depth + 1)
        case .defaultIfUnsetOrEmpty:
            if let value, !value.isEmpty {
                return value
            }
            return try interpolate(parsed.operand, lookup: lookup, depth: depth + 1)
        case .requiredIfUnset:
            if let value {
                return value
            }
            throw missingVariableError(name: parsed.name, message: parsed.operand)
        case .requiredIfUnsetOrEmpty:
            if let value, !value.isEmpty {
                return value
            }
            throw missingVariableError(name: parsed.name, message: parsed.operand)
        case .alternativeIfSet:
            guard value != nil else {
                return ""
            }
            return try interpolate(parsed.operand, lookup: lookup, depth: depth + 1)
        case .alternativeIfSetAndNotEmpty:
            guard let value, !value.isEmpty else {
                return ""
            }
            _ = value
            return try interpolate(parsed.operand, lookup: lookup, depth: depth + 1)
        }
    }

    private static func parse(expression: String) throws -> ParsedExpression {
        guard let first = expression.first, isValidNameStart(first) else {
            throw invalidVariableNameError(expression)
        }

        let nameEnd = scanNameEnd(in: expression, from: expression.startIndex)
        let name = String(expression[..<nameEnd])
        let suffix = String(expression[nameEnd...])

        if suffix.isEmpty {
            return ParsedExpression(name: name, operator: .none, operand: "")
        }
        if suffix.hasPrefix(":-") {
            return ParsedExpression(name: name, operator: .defaultIfUnsetOrEmpty, operand: String(suffix.dropFirst(2)))
        }
        if suffix.hasPrefix("-") {
            return ParsedExpression(name: name, operator: .defaultIfUnset, operand: String(suffix.dropFirst()))
        }
        if suffix.hasPrefix(":?") {
            return ParsedExpression(name: name, operator: .requiredIfUnsetOrEmpty, operand: String(suffix.dropFirst(2)))
        }
        if suffix.hasPrefix("?") {
            return ParsedExpression(name: name, operator: .requiredIfUnset, operand: String(suffix.dropFirst()))
        }
        if suffix.hasPrefix(":+") {
            return ParsedExpression(name: name, operator: .alternativeIfSetAndNotEmpty, operand: String(suffix.dropFirst(2)))
        }
        if suffix.hasPrefix("+") {
            return ParsedExpression(name: name, operator: .alternativeIfSet, operand: String(suffix.dropFirst()))
        }

        throw invalidVariableNameError(expression)
    }

    private static func scanNameEnd(in string: String, from start: String.Index) -> String.Index {
        var index = start
        while index < string.endIndex, isValidNameCharacter(string[index]) {
            index = string.index(after: index)
        }
        return index
    }

    private static func findClosingBrace(in string: String, from start: String.Index) throws -> String.Index {
        var index = start
        var nestedExpressions = 0

        while index < string.endIndex {
            let character = string[index]
            if character == "$" {
                let nextIndex = string.index(after: index)
                if nextIndex < string.endIndex, string[nextIndex] == "{" {
                    nestedExpressions += 1
                    index = string.index(after: nextIndex)
                    continue
                }
            }

            if character == "}" {
                if nestedExpressions == 0 {
                    return index
                }
                nestedExpressions -= 1
            }

            index = string.index(after: index)
        }

        throw ContainerizationError(
            .invalidArgument,
            message: "Unterminated variable expression"
        )
    }

    private static func isValidNameStart(_ character: Character) -> Bool {
        character == "_" || character.isASCIIUppercaseLetter || character.isASCIILowercaseLetter
    }

    private static func isValidNameCharacter(_ character: Character) -> Bool {
        isValidNameStart(character) || character.isASCIIDigit
    }

    private static func invalidVariableNameError(_ name: String) -> ContainerizationError {
        ContainerizationError(
            .invalidArgument,
            message: "Invalid environment variable name: '\(name)'"
        )
    }

    private static func missingVariableError(name: String, message: String) -> ContainerizationError {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMessage = trimmedMessage.isEmpty
            ? "Environment variable '\(name)' is required"
            : trimmedMessage
        return ContainerizationError(.invalidArgument, message: resolvedMessage)
    }
}

private struct ParsedExpression {
    let name: String
    let `operator`: ComposeVariableOperator
    let operand: String
}

private enum ComposeVariableOperator {
    case none
    case defaultIfUnset
    case defaultIfUnsetOrEmpty
    case requiredIfUnset
    case requiredIfUnsetOrEmpty
    case alternativeIfSet
    case alternativeIfSetAndNotEmpty
}

private extension Character {
    var isASCIIDigit: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return scalar.value >= 48 && scalar.value <= 57
    }

    var isASCIIUppercaseLetter: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return scalar.value >= 65 && scalar.value <= 90
    }

    var isASCIILowercaseLetter: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return scalar.value >= 97 && scalar.value <= 122
    }
}
