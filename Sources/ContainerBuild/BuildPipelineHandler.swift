//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import GRPCCore
import NIO

/// A handler for one stage of the build protocol.
///
/// The build pipeline multiplexes a single bidirectional gRPC stream between
/// the macOS host and the builder shim. Each packet carries a stage tag;
/// a handler claims packets for its stage via ``accept(_:)`` and processes
/// them via ``handle(_:_:)``.
protocol BuildPipelineHandler: Sendable {
    func accept(_ packet: ServerStream) throws -> Bool
    func handle(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ServerStream) async throws
}

/// Drives a build session by routing packets from the builder shim to the
/// appropriate handler.
///
/// ## Three-tier architecture
///
/// Builds involve three components with distinct responsibilities:
///
/// **macOS host (`BuildPipeline` / its handlers)**
/// Serves resources to the builder shim over a bidirectional gRPC stream.
/// Responsibilities include:
/// - Packing requested build-context files into a tar archive (``BuildFSSync``).
/// - Proxying image-layer blobs from the local content store (``BuildRemoteContentProxy``).
/// - Resolving and pulling base images (``BuildImageResolver``).
/// - Relaying builder stdout/stderr to the terminal (``BuildStdio``).
/// - Enforcing the context root boundary: directory traversal uses `openat(O_NOFOLLOW)`
///   at every descent step, and every individual file request resolves symlinks to their
///   canonical path before verifying containment within the context root.
///
/// **Builder shim (`container-builder-shim`)**
/// A Go process running inside a Linux VM that bridges the host gRPC stream
/// and BuildKit's `filesync` gRPC interface. Responsibilities include:
/// - Receiving the context tar from the host, unpacking it to a local cache,
///   and presenting the result to BuildKit via `DiffCopy`.
/// - Applying dockerignore exclusions (received from BuildKit as
///   `exclude-patterns` metadata) when walking the unpacked cache.
/// - Passing `followpaths` from BuildKit to the host so the host knows which
///   context paths to include in the tar.
///
/// **BuildKit**
/// Parses and executes the Dockerfile. Responsibilities include:
/// - Sending `Walk` requests with `followpaths` derived from each `COPY`/`ADD`
///   source and `exclude-patterns` derived from `.dockerignore`.
/// - Dereferencing symlinks, recursing into directories, and applying all
///   other COPY/ADD transfer semantics on the unpacked context the shim provides.
///
/// ## Packet flow
///
/// ```
/// BuildKit ──► shim DiffCopy ──► host Walk  (tar of context files)
///                            ◄── tar archive
///          ◄── PACKET_STAT per file (after shim unpacks + filters)
///          ──► PACKET_REQ for each regular file
///          ◄── PACKET_DATA (shim reads from local unpacked cache)
/// ```
public actor BuildPipeline {
    let handlers: [BuildPipelineHandler]
    public init(_ config: Builder.BuildConfig) async throws {
        self.handlers =
            [
                try BuildFSSync(URL(filePath: config.contextDir)),
                try BuildRemoteContentProxy(config.contentStore),
                try BuildImageResolver(
                    config.contentStore,
                    quiet: config.quiet,
                    output: config.terminal?.handle ?? FileHandle.standardError,
                    pull: config.pull,
                    containerSystemConfig: config.containerSystemConfig
                ),
                try BuildStdio(quiet: config.quiet, output: config.terminal?.handle ?? FileHandle.standardError),
            ]
    }

    public func run<S: AsyncSequence & Sendable>(
        sender: AsyncStream<ClientStream>.Continuation,
        receiver: S
    ) async throws where S.Element == ServerStream {
        defer { sender.finish() }
        try await untilFirstError { group in
            for try await packet in receiver {
                try Task.checkCancellation()
                for handler in self.handlers {
                    try Task.checkCancellation()
                    guard try handler.accept(packet) else {
                        continue
                    }
                    try Task.checkCancellation()
                    try await handler.handle(sender, packet)
                    break
                }
            }
        }
    }

    /// untilFirstError() throws when any one of its submitted tasks fail.
    /// This is useful for asynchronous packet processing scenarios which
    /// have the following 3 requirements:
    ///   - the packet should be processed without blocking I/O
    ///   - the packet stream is never-ending
    ///   - when the first task fails, the error needs to be propagated to the caller
    ///
    /// Usage:
    ///
    ///   ```
    ///     try await untilFirstError { group in
    ///         for try await packet in receiver  {
    ///              group.addTask {
    ///                 try await handler.handle(sender, packet)
    ///             }
    ///         }
    ///     }
    ///     ```
    ///
    ///
    /// WithThrowingTaskGroup cannot accomplish this because it
    /// doesn't provide a mechanism to exit when one of the tasks fail
    /// before all the tasks have been added. i.e. it is more suitable for
    /// tasks that are limited. Here's a sample code where withThrowingTaskGroup
    /// doesn't solve the problem:
    ///
    ///  ```
    ///     withThrowingTaskGroup { group in
    ///         for try await packet in receiver {
    ///             group.addTask {
    ///                 /* process packet */
    ///             }
    ///         }                          /* this loop blocks forever waiting for more packets */
    ///         try await group.next()     /* this never gets called */
    ///     }
    ///  ```
    ///  The above closure never returns even when a handler encounters an error
    ///  because the blocking operation `try await group.next()` cannot be
    ///  called while iterating over the receiver stream.
    private func untilFirstError(body: @Sendable @escaping (UntilFirstError) async throws -> Void) async throws {
        let group = try await UntilFirstError()
        var taskContinuation: AsyncStream<Task<(), Error>>.Continuation?
        let tasks = AsyncStream<Task<(), Error>> { continuation in
            taskContinuation = continuation
        }
        guard let taskContinuation else {
            throw NSError(
                domain: "untilFirstError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "failed to initialize task continuation"])
        }
        defer { taskContinuation.finish() }
        let stream = AsyncStream<Error> { continuation in
            let processTasks = Task {
                let taskStream = await group.tasks()
                defer {
                    continuation.finish()
                }
                for await item in taskStream {
                    try Task.checkCancellation()
                    let addedTask = Task {
                        try Task.checkCancellation()
                        do {
                            try await item()
                        } catch {
                            continuation.yield(error)
                            await group.continuation?.finish()
                            throw error
                        }
                    }
                    taskContinuation.yield(addedTask)
                }
            }
            taskContinuation.yield(processTasks)

            let mainTask = Task { @Sendable in
                defer {
                    continuation.finish()
                    processTasks.cancel()
                    taskContinuation.finish()
                }
                do {
                    try Task.checkCancellation()
                    try await body(group)
                } catch {
                    continuation.yield(error)
                    await group.continuation?.finish()
                    throw error
                }
            }
            taskContinuation.yield(mainTask)
        }

        // when the first handler fails, cancel all tasks and throw error
        for await item in stream {
            try Task.checkCancellation()
            Task {
                for await task in tasks {
                    task.cancel()
                }
            }
            throw item
        }
        // if none of the handlers fail, wait for all subtasks to complete
        for await task in tasks {
            try Task.checkCancellation()
            try await task.value
        }
    }

    private actor UntilFirstError {
        var stream: AsyncStream<@Sendable () async throws -> Void>?
        var continuation: AsyncStream<@Sendable () async throws -> Void>.Continuation?

        init() async throws {
            self.stream = AsyncStream { cont in
                self.continuation = cont
            }
            guard let _ = continuation else {
                throw NSError()
            }
        }

        func addTask(body: @Sendable @escaping () async throws -> Void) {
            if !Task.isCancelled {
                self.continuation?.yield(body)
            }
        }

        func tasks() -> AsyncStream<@Sendable () async throws -> Void> {
            self.stream!
        }
    }
}
