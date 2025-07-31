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

import ContainerBuildIR
import ContainerBuildSnapshotter
import Foundation

/// Executes ImageOperation (FROM instructions).
public struct ImageOperationExecutor: OperationExecutor {
    public let capabilities: ExecutorCapabilities

    public init() {
        self.capabilities = ExecutorCapabilities(
            supportedOperations: [.image],
            maxConcurrency: 3
        )
    }

    public func execute(_ operation: ContainerBuildIR.Operation, context: ExecutionContext) async throws -> ExecutionResult {
        guard let imageOp = operation as? ImageOperation else {
            throw ExecutorError(
                type: .invalidConfiguration,
                context: ExecutorError.ErrorContext(
                    operation: operation, underlyingError: NSError(domain: "Executor", code: 1),
                    diagnostics: ExecutorError.Diagnostics(environment: [:], workingDirectory: "", recentLogs: [])))
        }

        do {
            // Stub implementation
            // In a real implementation, this would:
            // 1. Pull the image from registry (if needed)
            // 2. Verify the image (if verification specified)
            // 3. Extract the image filesystem
            // 4. Create initial snapshot

            let startTime = Date()

            // Simulate image pull
            let imageSize: Int64
            let imageDigest: Digest

            switch imageOp.source {
            case .registry(let reference):
                // Simulate pulling from registry
                imageSize = 100 * 1024 * 1024  // 100MB
                let fakeDataString = "fake-image-\(reference.stringValue)"
                guard let fakeData = fakeDataString.data(using: .utf8) else {
                    throw ExecutorError(
                        type: .executionFailed,
                        context: ExecutorError.ErrorContext(
                            operation: operation,
                            underlyingError: NSError(domain: "ImageOperationExecutor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode fake image data as UTF-8"]),
                            diagnostics: ExecutorError.Diagnostics(environment: [:], workingDirectory: "", recentLogs: [])
                        )
                    )
                }
                var digestBytes = Data(count: 32)
                fakeData.withUnsafeBytes { bytes in
                    digestBytes.withUnsafeMutableBytes { digestBytesPtr in
                        if let destBase = digestBytesPtr.baseAddress, let srcBase = bytes.baseAddress {
                            memcpy(destBase, srcBase, min(32, bytes.count))
                        }
                    }
                }
                imageDigest = try Digest(algorithm: .sha256, bytes: digestBytes)

            case .scratch:
                // Empty image
                imageSize = 0
                imageDigest = try Digest(algorithm: .sha256, bytes: Data(count: 32))

            case .ociLayout:
                // Simulate loading from OCI layout
                imageSize = 50 * 1024 * 1024  // 50MB
                var digestBytes = Data(count: 32)
                digestBytes[0] = 1
                digestBytes[1] = 2
                digestBytes[2] = 3
                imageDigest = try Digest(algorithm: .sha256, bytes: digestBytes)

            case .tarball:
                // Simulate loading from tarball
                imageSize = 75 * 1024 * 1024  // 75MB
                var digestBytes = Data(count: 32)
                digestBytes[0] = 4
                digestBytes[1] = 5
                digestBytes[2] = 6
                imageDigest = try Digest(algorithm: .sha256, bytes: digestBytes)
            }

            // Create base snapshot
            let snapshot = ContainerBuildSnapshotter.Snapshot(
                digest: imageDigest,
                size: imageSize,
                parent: nil as UUID?  // Base images have no parent
            )

            // Update context with image config
            context.updateImageConfig { config in
                // In a real implementation, we'd extract this from the image
                config.env = ["PATH=/usr/local/bin:/usr/bin:/bin"]
                config.workingDir = "/"
            }

            let duration = Date().timeIntervalSince(startTime)

            return ExecutionResult(
                filesystemChanges: .empty,
                snapshot: snapshot,
                duration: duration
            )
        } catch {
            throw ExecutorError(
                type: .executionFailed,
                context: ExecutorError.ErrorContext(
                    operation: operation, underlyingError: error, diagnostics: ExecutorError.Diagnostics(environment: [:], workingDirectory: "", recentLogs: [])))
        }
    }

    public func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool {
        operation is ImageOperation
    }
}
