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

import ContainerizationError
import ContainerizationOS
import Foundation
import Logging

public class DirectoryWatcher {
    public let directoryURL: URL

    private let monitorQueue: DispatchQueue
    private var parentSource: DispatchSourceFileSystemObject?
    private var source: DispatchSourceFileSystemObject?

    private let log: Logger?

    public init(directoryURL: URL, log: Logger?) {
        self.directoryURL = directoryURL
        self.monitorQueue = DispatchQueue(label: "monitor:\(directoryURL.path)")
        self.log = log
    }

    private func _startWatching(
        handler: @escaping ([URL]) throws -> Void
    ) throws {
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor > 0 else {
            throw ContainerizationError(.internalError, message: "cannot open \(directoryURL.path), descriptor=\(descriptor)")
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            try handler(files.map { directoryURL.appending(path: $0) })
        } catch {
            throw ContainerizationError(.internalError, message: "failed to run handler for \(directoryURL.path)")
        }

        log?.info("starting directory watcher for \(directoryURL.path)")

        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: monitorQueue
        )

        dispatchSource.setCancelHandler {
            close(descriptor)
        }

        dispatchSource.setEventHandler { [weak self] in
            guard let self else { return }

            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
                try handler(files.map { directoryURL.appending(path: $0) })
            } catch {
                self.log?.error("failed to run DirectoryWatcher handler", metadata: ["error": "\(error)", "path": "\(directoryURL.path)"])
            }
        }

        source = dispatchSource
        dispatchSource.resume()
    }

    public func startWatching(handler: @escaping ([URL]) throws -> Void) throws {
        guard source == nil else {
            throw ContainerizationError(.invalidState, message: "already watching on \(directoryURL.path)")
        }

        let parent = directoryURL.deletingLastPathComponent().resolvingSymlinksInPathWithPrivate()
        guard parent.isDirectory else {
            throw ContainerizationError(.invalidState, message: "expected \(parent.path) to be an existing directory")
        }

        guard !directoryURL.isSymlink else {
            throw ContainerizationError(.invalidState, message: "expected \(directoryURL.path) not a symlink")
        }

        guard directoryURL.isDirectory else {
            log?.info("no \(directoryURL.path), start watching \(parent.path)")

            let descriptor = open(parent.path, O_EVTONLY)
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: .write,
                queue: monitorQueue)

            source.setCancelHandler {
                close(descriptor)
            }

            source.setEventHandler { [weak self] in
                guard let self else { return }

                if directoryURL.isDirectory {
                    do {
                        try _startWatching(handler: handler)
                    } catch {
                        log?.error("failed to start watching: \(error)")
                    }
                    source.cancel()
                }
            }

            parentSource = source
            source.resume()
            return
        }

        try _startWatching(handler: handler)
    }

    deinit {
        parentSource?.cancel()
        source?.cancel()
    }
}
