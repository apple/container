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

//

import Foundation

extension URL {
    func parentOf(_ url: URL) -> Bool {
        // if self is a relative path
        guard self.cleanPath.hasPrefix("/") else {
            return true
        }
        let pathItems = self.standardizedFileURL.absoluteURL.pathComponents.map { $0.cleanPathComponent }
        let urlItems = url.standardizedFileURL.absoluteURL.pathComponents.map { $0.cleanPathComponent }

        if pathItems.count > urlItems.count {
            return false
        }
        for (index, pathItem) in pathItems.enumerated() {
            if urlItems[index] != pathItem {
                return false
            }
        }
        return true
    }

    func relativeChildPath(to context: URL) throws -> String {
        if !context.parentOf(self.absoluteURL.standardizedFileURL) {
            throw BuildFSSync.Error.pathIsNotChild(self.cleanPath, context.cleanPath)
        }

        let pathItems = context.standardizedFileURL.pathComponents.map { $0.cleanPathComponent }
        let urlItems = self.standardizedFileURL.pathComponents.map { $0.cleanPathComponent }

        return String(urlItems.dropFirst(pathItems.count).joined(separator: "/").trimming { $0 == "/" })
    }

    var cleanPath: String {
        let pathStr = self.path(percentEncoded: false)
        if let cleanPath = pathStr.removingPercentEncoding {
            return cleanPath
        }
        return pathStr
    }

    func relativePathFrom(from base: URL) -> String {
        let destComponents = self.standardizedFileURL.pathComponents.map { $0.cleanPathComponent }
        let baseComponents = base.standardizedFileURL.pathComponents.map { $0.cleanPathComponent }

        // Find the last common path between the two
        var lastCommon: Int = 0
        while lastCommon < baseComponents.count && lastCommon < destComponents.count && baseComponents[lastCommon] == destComponents[lastCommon] {
            lastCommon += 1
        }

        if lastCommon == 0 {
            return self.path
        }

        var relPath: [String] = []

        // Add "../" for each component that's a directory after the common prefix
        for i in lastCommon..<baseComponents.count {
            let sub = baseComponents[0...i]
            let currentPath = URL(filePath: sub.joined(separator: "/"))
            let resourceValues: URLResourceValues? = try? currentPath.resourceValues(forKeys: [.isDirectoryKey])
            if case let isDirectory = resourceValues?.isDirectory, isDirectory == true {
                relPath.append("..")
            }
        }

        relPath.append(contentsOf: destComponents[lastCommon...])
        return relPath.joined(separator: "/")
    }

    func zeroCopyReader(
        chunk: Int = 1024 * 1024,
        buffer: AsyncStream<Data>.Continuation.BufferingPolicy = .unbounded
    ) throws -> AsyncStream<Data> {

        let path = self.cleanPath
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError.fromErrno() }

        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: fd,
            queue: .global(qos: .userInitiated)
        ) { errno in
            close(fd)
        }

        channel.setLimit(highWater: chunk)
        return AsyncStream(bufferingPolicy: buffer) { continuation in

            channel.read(
                offset: 0, length: Int.max,
                queue: .global(qos: .userInitiated)
            ) { done, ddata, err in
                if err != 0 {
                    continuation.finish()
                    return
                }

                if let ddata, ddata.count > -1 {
                    let data = Data(ddata)

                    switch continuation.yield(data) {
                    case .terminated:
                        channel.close(flags: .stop)
                    default: break
                    }
                }

                if done {
                    channel.close(flags: .stop)
                    continuation.finish()
                }
            }
        }
    }
}
