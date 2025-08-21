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

/// Protocol for errors that can be reported through the build event system.
///
/// Design rationale:
/// - Enforces consistent error formatting across the system
/// - Provides structured error information for reporting
/// - Enables centralized error formatting control
public protocol ReportableError: Error {
    /// The category of the error
    var errorCategory: ErrorCategory { get }

    /// A short, user-friendly description of what went wrong
    var shortDescription: String { get }

    /// Detailed information about the error for debugging
    var detailedDescription: String? { get }

    /// Structured diagnostic information
    var diagnostics: ErrorDiagnostics { get }

    /// The underlying error that caused this error (if any)
    var underlyingError: Error? { get }

    /// Convert to BuildEventError for reporting
    func toBuildEventError() -> BuildEventError
}

/// Categories of errors that can occur during build
public enum ErrorCategory: String, Sendable, Codable {
    // Execution errors
    case executionFailed = "execution_failed"
    case commandNotFound = "command_not_found"
    case permissionDenied = "permission_denied"
    case timeout = "timeout"
    case cancelled = "cancelled"

    // Configuration errors
    case invalidConfiguration = "invalid_configuration"
    case missingDependency = "missing_dependency"
    case incompatiblePlatform = "incompatible_platform"

    // Resource errors
    case resourceExhausted = "resource_exhausted"
    case diskFull = "disk_full"
    case memoryExhausted = "memory_exhausted"

    // I/O errors
    case fileNotFound = "file_not_found"
    case fileAccessDenied = "file_access_denied"
    case networkError = "network_error"

    // Parse/validation errors
    case syntaxError = "syntax_error"
    case validationError = "validation_error"
    case unsupportedFeature = "unsupported_feature"

    // Cache errors
    case cacheCorrupted = "cache_corrupted"
    case cacheMiss = "cache_miss"

    // Unknown
    case unknown = "unknown"
}

/// Structured diagnostic information for errors
public struct ErrorDiagnostics: Sendable, Codable {
    /// The operation that was being performed
    public let operation: String?

    /// The file or resource involved
    public let path: String?

    /// Line number (for parse errors)
    public let line: Int?

    /// Column number (for parse errors)
    public let column: Int?

    /// Exit code (for execution errors)
    public let exitCode: Int?

    /// Working directory
    public let workingDirectory: String?

    /// Relevant environment variables
    public let environment: [String: String]?

    /// Recent log output
    public let recentLogs: [String]?

    /// Additional context-specific information
    public let additionalInfo: [String: String]?

    public init(
        operation: String? = nil,
        path: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        exitCode: Int? = nil,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        recentLogs: [String]? = nil,
        additionalInfo: [String: String]? = nil
    ) {
        self.operation = operation
        self.path = path
        self.line = line
        self.column = column
        self.exitCode = exitCode
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.recentLogs = recentLogs
        self.additionalInfo = additionalInfo
    }

    /// Convert to flat dictionary for BuildEventError
    func toDictionary() -> [String: String] {
        var dict: [String: String] = [:]

        if let operation = operation {
            dict["operation"] = operation
        }
        if let path = path {
            dict["path"] = path
        }
        if let line = line {
            dict["line"] = String(line)
        }
        if let column = column {
            dict["column"] = String(column)
        }
        if let exitCode = exitCode {
            dict["exitCode"] = String(exitCode)
        }
        if let workingDirectory = workingDirectory {
            dict["workingDirectory"] = workingDirectory
        }
        if let environment = environment {
            for (key, value) in environment {
                dict["env.\(key)"] = value
            }
        }
        if let recentLogs = recentLogs, !recentLogs.isEmpty {
            dict["recentLogs"] = recentLogs.joined(separator: "\n")
        }
        if let additionalInfo = additionalInfo {
            for (key, value) in additionalInfo {
                dict[key] = value
            }
        }

        return dict
    }
}

// MARK: - Default Implementation

extension ReportableError {
    /// Default implementation that converts to BuildEventError
    public func toBuildEventError() -> BuildEventError {
        // Map error category to BuildEventError.FailureType
        let failureType: BuildEventError.FailureType
        switch errorCategory {
        case .executionFailed, .commandNotFound, .permissionDenied:
            failureType = .executionFailed
        case .timeout:
            failureType = .timeout
        case .cancelled:
            failureType = .cancelled
        case .invalidConfiguration, .missingDependency, .incompatiblePlatform,
            .syntaxError, .validationError, .unsupportedFeature:
            failureType = .invalidConfiguration
        case .resourceExhausted, .diskFull, .memoryExhausted:
            failureType = .resourceExhausted
        case .fileNotFound, .fileAccessDenied, .networkError,
            .cacheCorrupted, .cacheMiss, .unknown:
            failureType = .executionFailed
        }

        // Build description
        var description = shortDescription
        if let detailed = detailedDescription {
            description += ". \(detailed)"
        }
        if let underlying = underlyingError {
            description += ". Caused by: \(underlying.localizedDescription)"
        }

        return BuildEventError(
            type: failureType,
            description: description,
            diagnostics: diagnostics.toDictionary()
        )
    }

    /// Default values for optional properties
    public var detailedDescription: String? { nil }
    public var underlyingError: Error? { nil }
}

// MARK: - Generic Error Extension

/// Extension to make any Error reportable with basic information
extension Error {
    /// Convert any error to a ReportableError
    public func asReportableError() -> ReportableError {
        if let reportable = self as? ReportableError {
            return reportable
        }
        return GenericReportableError(underlying: self)
    }
}

/// Wrapper for non-ReportableError errors
private struct GenericReportableError: ReportableError {
    let underlying: Error

    var errorCategory: ErrorCategory { .unknown }

    var shortDescription: String {
        (underlying as NSError).localizedDescription
    }

    var diagnostics: ErrorDiagnostics {
        var additionalInfo: [String: String] = [:]

        let nsError = underlying as NSError
        additionalInfo["domain"] = nsError.domain
        additionalInfo["code"] = String(nsError.code)

        for (key, value) in nsError.userInfo {
            if let stringValue = value as? String {
                additionalInfo["userInfo.\(key)"] = stringValue
            }
        }

        return ErrorDiagnostics(additionalInfo: additionalInfo)
    }

    var underlyingError: Error? { underlying }
}
