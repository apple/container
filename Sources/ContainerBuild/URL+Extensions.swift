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

extension String {
    fileprivate var fs_cleaned: String {
        var value = self

        if value.hasPrefix("file://") {
            value.removeFirst("file://".count)
        }

        if value.count > 1 && value.last == "/" {
            value.removeLast()
        }

        return value.removingPercentEncoding ?? value
    }

    fileprivate var fs_components: [String] {
        var parts: [String] = []
        for segment in self.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if !parts.isEmpty { parts.removeLast() }
            default:
                parts.append(String(segment))
            }
        }
        return parts
    }

    fileprivate var fs_isAbsolute: Bool { first == "/" }
}

extension URL {
    var cleanPath: String {
        self.path.fs_cleaned
    }

    func parentOf(_ url: URL) -> Bool {
        let parentPath = self.absoluteURL.cleanPath
        let childPath = url.absoluteURL.cleanPath

        guard parentPath.fs_isAbsolute else {
            return true
        }

        let parentParts = parentPath.fs_components
        let childParts = childPath.fs_components

        guard parentParts.count <= childParts.count else { return false }
        return zip(parentParts, childParts).allSatisfy { $0 == $1 }
    }

    func relativeChildPath(to context: URL) throws -> String {
        guard context.parentOf(self) else {
            throw BuildFSSync.Error.pathIsNotChild(cleanPath, context.cleanPath)
        }

        let ctxParts = context.cleanPath.fs_components
        let selfParts = cleanPath.fs_components

        return selfParts.dropFirst(ctxParts.count).joined(separator: "/")
    }

    func relativePathFrom(from base: URL) -> String {
        let destParts = cleanPath.fs_components
        let baseParts = base.cleanPath.fs_components

        let common = zip(destParts, baseParts).prefix { $0 == $1 }.count
        guard common > 0 else { return cleanPath }

        let ups = Array(repeating: "..", count: baseParts.count - common)
        let remainder = destParts.dropFirst(common)
        return (ups + remainder).joined(separator: "/")
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
