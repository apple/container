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
import Foundation
import Logging

public class DirectoryWatcher {
    public let directoryURL: URL

    private let monitorQueue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?

    private let log: Logger

    init(directoryURL: URL, log: Logger) {
        self.directoryURL = directoryURL
        self.monitorQueue = DispatchQueue(label: "monitor:\(directoryURL.path)")
        self.log = log
    }

    public func startWatching(handler: @escaping ([URL]) throws -> Void) throws {
        guard source == nil else {
            throw ContainerizationError(.invalidState, message: "already watching on \(directoryURL.path)")
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            try handler(files.map { directoryURL.appending(path: $0) })
        } catch {
            throw ContainerizationError(.invalidState, message: "failed to start watching on \(directoryURL.path)")
        }

        log.info("starting directory watcher for \(directoryURL.path)")

        let descriptor = open(directoryURL.path, O_EVTONLY)

        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: monitorQueue
        )

        // Close the file descriptor when the source is cancelled
        dispatchSource.setCancelHandler {
            close(descriptor)
        }

        dispatchSource.setEventHandler { [weak self] in
            guard let self else { return }

            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
                try handler(files.map { directoryURL.appending(path: $0) })
            } catch {
                self.log.error("failed to run DirectoryWatcher handler", metadata: ["error": "\(error)", "path": "\(directoryURL.path)"])
            }
        }

        source = dispatchSource
        dispatchSource.resume()
    }

    deinit {
        guard let source else {
            return
        }

        source.cancel()
    }
}
