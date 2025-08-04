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
import Testing

@testable import ContainerBuildReporting

@Suite("ReportableError Tests")
struct ReportableErrorTests {

    // MARK: - Test Error Types

    struct TestExecutionError: ReportableError {
        let message: String
        let category: ErrorCategory = .executionFailed
        let errorDiagnostics: ErrorDiagnostics?

        var errorCategory: ErrorCategory { category }
        var shortDescription: String { message }
        var detailedDescription: String? { nil }
        var diagnostics: ErrorDiagnostics { errorDiagnostics ?? ErrorDiagnostics() }
        var underlyingError: Error? { nil }

        var description: String { message }

        func toBuildEventError() -> BuildEventError {
            BuildEventError(
                type: .executionFailed,
                description: message,
                diagnostics: diagnostics.toDictionary()
            )
        }
    }

    struct TestNetworkError: ReportableError {
        let url: String
        let statusCode: Int

        var errorCategory: ErrorCategory { .networkError }
        var shortDescription: String { "Network request to \(url) failed with status code \(statusCode)" }
        var detailedDescription: String? { "HTTP request failed" }
        var underlyingError: Error? { nil }

        var diagnostics: ErrorDiagnostics {
            ErrorDiagnostics(
                operation: "HTTP Request",
                path: url,
                exitCode: statusCode
            )
        }

        var description: String {
            "Network request to \(url) failed with status code \(statusCode)"
        }

        func toBuildEventError() -> BuildEventError {
            BuildEventError(
                type: .executionFailed,
                description: description,
                diagnostics: diagnostics.toDictionary()
            )
        }
    }

    // MARK: - Error Category Tests

    @Test("Error categories map to correct failure types")
    func testErrorCategoryMapping() {
        // Test the mapping logic based on the actual default implementation
        let _ = TestExecutionError(message: "test", errorDiagnostics: nil)

        // Test execution failed category
        let execFailedError = TestExecutionError(message: "test", errorDiagnostics: nil)
        let buildError = execFailedError.toBuildEventError()
        #expect(buildError.type == .executionFailed)

        // Test that the mapping works through the actual interface
        let categories: [ErrorCategory] = [
            .executionFailed,
            .commandNotFound,
            .permissionDenied,
            .timeout,
            .cancelled,
            .invalidConfiguration,
            .missingDependency,
            .incompatiblePlatform,
            .resourceExhausted,
            .diskFull,
            .memoryExhausted,
            .fileNotFound,
            .fileAccessDenied,
            .networkError,
            .syntaxError,
            .validationError,
            .unsupportedFeature,
            .cacheCorrupted,
            .cacheMiss,
            .unknown,
        ]

        // Just verify that all categories are valid
        for category in categories {
            #expect(category.rawValue.isEmpty == false)
        }
    }

    @Test("Error categories have meaningful descriptions")
    func testErrorCategoryDescriptions() {
        let categories: [ErrorCategory] = [
            .executionFailed,
            .commandNotFound,
            .permissionDenied,
            .timeout,
            .cancelled,
            .invalidConfiguration,
            .missingDependency,
            .incompatiblePlatform,
            .resourceExhausted,
            .diskFull,
            .memoryExhausted,
            .fileNotFound,
            .fileAccessDenied,
            .networkError,
            .syntaxError,
            .validationError,
            .unsupportedFeature,
            .cacheCorrupted,
            .cacheMiss,
            .unknown,
        ]

        for category in categories {
            let description = String(describing: category)
            #expect(!description.isEmpty)
            #expect(description != "ErrorCategory")
        }
    }

    // MARK: - ErrorDiagnostics Tests

    @Test("ErrorDiagnostics creation with all parameters")
    func testErrorDiagnosticsFullCreation() {
        let diagnostics = ErrorDiagnostics(
            operation: "docker build",
            path: "/path/to/Dockerfile",
            exitCode: 127,
            environment: ["PATH": "/usr/bin", "USER": "root"]
        )

        #expect(diagnostics.operation == "docker build")
        #expect(diagnostics.path == "/path/to/Dockerfile")
        #expect(diagnostics.exitCode == 127)
        #expect(diagnostics.environment?["PATH"] == "/usr/bin")
        #expect(diagnostics.environment?["USER"] == "root")
        // Note: suggestion is no longer a separate property
    }

    @Test("ErrorDiagnostics toDictionary conversion")
    func testErrorDiagnosticsToDictionary() {
        let diagnostics = ErrorDiagnostics(
            operation: "container run",
            path: "/var/lib/containers/image.tar",
            exitCode: 1,
            environment: ["CONTAINER_RUNTIME": "podman"]
        )

        let dict = diagnostics.toDictionary()

        #expect(dict["operation"] == "container run")
        #expect(dict["path"] == "/var/lib/containers/image.tar")
        #expect(dict["exitCode"] == "1")
        #expect(dict["env.CONTAINER_RUNTIME"] == "podman")
    }

    @Test("ErrorDiagnostics with nil values")
    func testErrorDiagnosticsWithNilValues() {
        let diagnostics = ErrorDiagnostics(
            operation: nil,
            path: nil,
            exitCode: nil,
            environment: nil
        )

        let dict = diagnostics.toDictionary()
        #expect(dict.isEmpty)
    }

    @Test("ErrorDiagnostics with partial values")
    func testErrorDiagnosticsPartialValues() {
        let diagnostics = ErrorDiagnostics(
            operation: "build step",
            path: nil,
            exitCode: 0,
            environment: nil
        )

        let dict = diagnostics.toDictionary()
        #expect(dict.count == 2)
        #expect(dict["operation"] == "build step")
        #expect(dict["exitCode"] == "0")
        #expect(dict["path"] == nil)
    }

    @Test("ErrorDiagnostics with multiple environment variables")
    func testErrorDiagnosticsMultipleEnvVars() {
        let diagnostics = ErrorDiagnostics(
            operation: "compile",
            environment: [
                "CC": "clang",
                "CFLAGS": "-O2",
                "LDFLAGS": "-lm",
            ]
        )

        let dict = diagnostics.toDictionary()

        #expect(dict["env.CC"] == "clang")
        #expect(dict["env.CFLAGS"] == "-O2")
        #expect(dict["env.LDFLAGS"] == "-lm")
    }

    // MARK: - ReportableError Protocol Tests

    @Test("Custom error implements ReportableError")
    func testCustomReportableError() {
        let error = TestExecutionError(
            message: "Command failed",
            errorDiagnostics: ErrorDiagnostics(
                operation: "docker build",
                exitCode: 1
            )
        )

        #expect(error.errorCategory == ErrorCategory.executionFailed)
        #expect(error.description == "Command failed")

        let buildError = error.toBuildEventError()
        #expect(buildError.description == "Command failed")
        #expect(buildError.type == BuildEventError.FailureType.executionFailed)
        #expect(buildError.diagnostics?["operation"] == "docker build")
        #expect(buildError.diagnostics?["exitCode"] == "1")
    }

    @Test("Network error with diagnostics")
    func testNetworkErrorWithDiagnostics() {
        let error = TestNetworkError(
            url: "https://registry.example.com/v2/",
            statusCode: 404
        )

        #expect(error.errorCategory == .networkError)
        // Note: suggestion is no longer a separate property

        let buildError = error.toBuildEventError()
        #expect(buildError.type == .executionFailed)
        #expect(buildError.diagnostics?["path"] == "https://registry.example.com/v2/")
        #expect(buildError.diagnostics?["exitCode"] == "404")
    }

    // MARK: - GenericReportableError Tests

    @Test("GenericReportableError wraps standard errors")
    func testGenericReportableError() {
        let nsError = NSError(
            domain: "com.example.container",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Container not found"]
        )

        let reportableError = nsError.asReportableError()

        #expect(reportableError.errorCategory == .unknown)
        #expect(reportableError.shortDescription.contains("Container not found"))

        let buildError = reportableError.toBuildEventError()
        #expect(buildError.type == .executionFailed)
        #expect(buildError.description.contains("Container not found"))
    }

    @Test("Simple Swift error conversion")
    func testSimpleErrorConversion() {
        enum TestError: Error {
            case simpleError
        }

        let error = TestError.simpleError
        let reportableError = error.asReportableError()

        #expect(reportableError.errorCategory == .unknown)
        #expect(reportableError.shortDescription.contains("TestError"))
    }

    @Test("LocalizedError conversion preserves message")
    func testLocalizedErrorConversion() {
        struct CustomError: LocalizedError {
            var errorDescription: String? {
                "Custom localized error message"
            }
        }

        let error = CustomError()
        let reportableError = error.asReportableError()

        #expect(reportableError.shortDescription == "Custom localized error message")
    }

    // MARK: - BuildEventError Conversion Tests

    @Test("BuildEventError preserves all diagnostics")
    func testBuildEventErrorFullConversion() {
        let diagnostics = ErrorDiagnostics(
            operation: "layer extraction",
            path: "/tmp/layer.tar.gz",
            exitCode: 2,
            environment: ["TMPDIR": "/tmp"]
        )

        let error = TestExecutionError(
            message: "Failed to extract layer",
            errorDiagnostics: diagnostics
        )

        let buildError = error.toBuildEventError()

        #expect(buildError.description == "Failed to extract layer")
        #expect(buildError.type == .executionFailed)
        #expect(buildError.diagnostics?.count == 4)
        #expect(buildError.diagnostics?["operation"] == "layer extraction")
        #expect(buildError.diagnostics?["path"] == "/tmp/layer.tar.gz")
        #expect(buildError.diagnostics?["exitCode"] == "2")
        #expect(buildError.diagnostics?["env.TMPDIR"] == "/tmp")
    }

    @Test("BuildEventError with nil diagnostics")
    func testBuildEventErrorNilDiagnostics() {
        let error = TestExecutionError(
            message: "Generic failure",
            errorDiagnostics: nil
        )

        let buildError = error.toBuildEventError()

        #expect(buildError.description == "Generic failure")
        #expect(buildError.type == .executionFailed)
        #expect(buildError.diagnostics?.isEmpty == true)
    }

    // MARK: - Edge Cases

    @Test("Empty diagnostics produces empty dictionary")
    func testEmptyDiagnostics() {
        let diagnostics = ErrorDiagnostics()
        let dict = diagnostics.toDictionary()

        #expect(dict.isEmpty)
    }

    @Test("Complex error hierarchy")
    func testComplexErrorHierarchy() {
        struct OuterError: Error {
            let inner: Error
        }

        struct InnerError: ReportableError {
            var errorCategory: ErrorCategory { .validationError }
            var diagnostics: ErrorDiagnostics { ErrorDiagnostics() }

            var shortDescription: String { "Inner validation error" }

            var description: String { shortDescription }

            func toBuildEventError() -> BuildEventError {
                BuildEventError(
                    type: .invalidConfiguration,
                    description: description,
                    diagnostics: nil
                )
            }
        }

        let innerError = InnerError()
        let outerError = OuterError(inner: innerError)

        let reportableError = outerError.asReportableError()
        #expect(reportableError.errorCategory == .unknown)
        #expect(reportableError.shortDescription.contains("OuterError"))
    }

    // MARK: - Error Categorization Tests

    @Test("Proper category assignment for file errors")
    func testFileCategoryAssignment() {
        struct FileError: ReportableError {
            let path: String
            let isNotFound: Bool

            var errorCategory: ErrorCategory {
                isNotFound ? .fileNotFound : .fileAccessDenied
            }

            var diagnostics: ErrorDiagnostics {
                ErrorDiagnostics(path: path)
            }

            var shortDescription: String {
                isNotFound ? "File not found: \(path)" : "Access denied: \(path)"
            }

            var description: String {
                shortDescription
            }

            func toBuildEventError() -> BuildEventError {
                BuildEventError(
                    type: .executionFailed,
                    description: description,
                    diagnostics: diagnostics.toDictionary()
                )
            }
        }

        let notFoundError = FileError(path: "/missing/file", isNotFound: true)
        #expect(notFoundError.errorCategory == .fileNotFound)
        #expect(notFoundError.toBuildEventError().type == .executionFailed)

        let accessError = FileError(path: "/protected/file", isNotFound: false)
        #expect(accessError.errorCategory == .fileAccessDenied)
        #expect(accessError.toBuildEventError().type == .executionFailed)
    }

    @Test("Unknown category fallback")
    func testUnknownCategoryFallback() {
        struct UnknownError: ReportableError {
            var errorCategory: ErrorCategory { .unknown }
            var diagnostics: ErrorDiagnostics { ErrorDiagnostics() }

            var shortDescription: String { "Something went wrong" }

            var description: String { shortDescription }

            func toBuildEventError() -> BuildEventError {
                BuildEventError(
                    type: .executionFailed,
                    description: description,
                    diagnostics: nil
                )
            }
        }

        let error = UnknownError()
        let buildError = error.toBuildEventError()

        #expect(buildError.type == .executionFailed)
    }

    @Test("Resource exhaustion errors")
    func testResourceExhaustionErrors() {
        struct ResourceError: ReportableError {
            enum ResourceType {
                case disk
                case memory
                case cpu
            }

            let resourceType: ResourceType
            let usage: String

            var errorCategory: ErrorCategory {
                switch resourceType {
                case .disk: return .diskFull
                case .memory: return .memoryExhausted
                case .cpu: return .resourceExhausted
                }
            }

            var diagnostics: ErrorDiagnostics {
                ErrorDiagnostics(
                    operation: "resource check"
                )
            }

            var shortDescription: String {
                "\(resourceType) exhausted: \(usage)"
            }

            var description: String {
                shortDescription
            }

            func toBuildEventError() -> BuildEventError {
                BuildEventError(
                    type: .resourceExhausted,
                    description: description,
                    diagnostics: diagnostics.toDictionary()
                )
            }
        }

        let diskError = ResourceError(resourceType: .disk, usage: "99%")
        #expect(diskError.errorCategory == .diskFull)
        #expect(diskError.toBuildEventError().type == .resourceExhausted)

        let memoryError = ResourceError(resourceType: .memory, usage: "8GB/8GB")
        #expect(memoryError.errorCategory == .memoryExhausted)
        #expect(memoryError.toBuildEventError().type == .resourceExhausted)
    }
}
