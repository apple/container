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

        let startTime = Date()

        do {
            // 1. Load/pull the base image and create initial snapshot
            let baseSnapshot = try await loadBaseImage(imageOp)

            // 2. Prepare and commit the base snapshot directly (no filesystem changes needed here)
            let finalSnapshot = try await context.prepareAndCommit(from: baseSnapshot)

            // 4. Update context with image configuration
            try await updateImageConfiguration(imageOp, context: context)

            let duration = Date().timeIntervalSince(startTime)

            return ExecutionResult(
                snapshot: finalSnapshot,
                duration: duration
            )

        } catch {

            throw ExecutorError(
                type: .executionFailed,
                context: ExecutorError.ErrorContext(
                    operation: operation,
                    underlyingError: error,
                    diagnostics: ExecutorError.Diagnostics(
                        environment: context.environment.effectiveEnvironment,
                        workingDirectory: context.workingDirectory,
                        recentLogs: ["Failed to load base image: \(imageOp.source)", "Error: \(error.localizedDescription)"]
                    )
                )
            )
        }
    }

    /// Load a base image and create the initial snapshot.
    ///
    /// This is currently a simulation. When TarSnapshotter is implemented,
    /// this will pull actual images and extract their filesystem layers.
    ///
    /// - Parameters:
    ///   - operation: The image operation
    /// - Returns: A base snapshot representing the image filesystem
    private func loadBaseImage(_ operation: ImageOperation) async throws -> Snapshot {
        // TODO: When TarSnapshotter is implemented, this will:
        // 1. Pull the image from registry/load from file (if needed)
        // 2. Verify the image (if verification specified)
        // 3. Extract the image filesystem layers
        // 4. Create a snapshot with the actual image content

        // Simulate image loading based on source type
        let imageSize: Int64
        let imageDigest: Digest

        switch operation.source {
        case .registry(let reference):
            // Simulate pulling from registry
            imageSize = 100 * 1024 * 1024  // 100MB
            let fakeDataString = "fake-image-\(reference.stringValue)"
            guard let fakeData = fakeDataString.data(using: .utf8) else {
                throw NSError(domain: "ImageOperationExecutor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode fake image data as UTF-8"])
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

        // Create base snapshot (no parent for base images)
        // Provide a concrete mountpoint so snapshotter.prepare can ensure it exists.
        let tempMountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("base-image", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        return Snapshot(
            digest: imageDigest,
            size: imageSize,
            parent: nil,
            state: .prepared(mountpoint: tempMountPoint)
        )
    }

    /// Update the execution context with image configuration.
    ///
    /// - Parameters:
    ///   - operation: The image operation
    ///   - context: The execution context to update
    private func updateImageConfiguration(_ operation: ImageOperation, context: ExecutionContext) async throws {
        // TODO: When TarSnapshotter is implemented, this will:
        // 1. Extract the actual image configuration from the image manifest
        // 2. Set environment variables, working directory, user, etc.
        // 3. Configure exposed ports, volumes, labels, etc.

        // For now, simulate basic image configuration
        context.updateImageConfig { config in
            // Set basic defaults that most images have
            config.env = ["PATH=/usr/local/bin:/usr/bin:/bin"]
            config.workingDir = "/"

            // Add source-specific configuration
            switch operation.source {
            case .registry(let reference):
                config.labels["source"] = "registry:\(reference.stringValue)"
            case .scratch:
                config.labels["source"] = "scratch"
            case .ociLayout:
                config.labels["source"] = "oci-layout"
            case .tarball:
                config.labels["source"] = "tarball"
            }
        }
    }

    public func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool {
        operation is ImageOperation
    }
}
