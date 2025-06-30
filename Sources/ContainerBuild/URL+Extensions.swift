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

    func bufferedCopyReader(chunkSize: Int = 4 * 1024 * 1024) throws -> BufferedCopyReader {
        try BufferedCopyReader(url: self, chunkSize: chunkSize)
    }
}

/// A synchronous buffered reader that reads one chunk at a time from a file
/// Uses a configurable buffer size (default 4MB) and only reads when nextChunk() is called
/// Implements AsyncSequence for use with `for await` loops
public final class BufferedCopyReader: AsyncSequence {
    public typealias Element = Data
    public typealias AsyncIterator = BufferedCopyReaderIterator

    private let inputStream: InputStream
    private let chunkSize: Int
    private var isFinished: Bool = false
    private let reusableBuffer: UnsafeMutablePointer<UInt8>

    /// Initialize a buffered copy reader for the given URL
    /// - Parameters:
    ///   - url: The file URL to read from
    ///   - chunkSize: Size of each chunk to read (default: 4MB)
    public init(url: URL, chunkSize: Int = 4 * 1024 * 1024) throws {
        guard let stream = InputStream(url: url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        self.inputStream = stream
        self.chunkSize = chunkSize
        self.reusableBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        self.inputStream.open()
    }

    deinit {
        inputStream.close()
        reusableBuffer.deallocate()
    }

    /// Create an async iterator for this sequence
    public func makeAsyncIterator() -> BufferedCopyReaderIterator {
        BufferedCopyReaderIterator(reader: self)
    }

    /// Read the next chunk of data from the file
    /// - Returns: Data chunk, or nil if end of file reached
    /// - Throws: Any file reading errors
    public func nextChunk() throws -> Data? {
        guard !isFinished else { return nil }

        // Read directly into our reusable buffer
        let bytesRead = inputStream.read(reusableBuffer, maxLength: chunkSize)

        // Check for errors
        if bytesRead < 0 {
            if let error = inputStream.streamError {
                throw error
            }
            throw CocoaError(.fileReadUnknown)
        }

        // If we read no data, we've reached the end
        if bytesRead == 0 {
            isFinished = true
            return nil
        }

        // If we read less than the chunk size, this is the last chunk
        if bytesRead < chunkSize {
            isFinished = true
        }

        // Create Data object only with the bytes actually read
        return Data(bytes: reusableBuffer, count: bytesRead)
    }

    /// Check if the reader has finished reading the file
    public var hasFinished: Bool {
        isFinished
    }

    /// Reset the reader to the beginning of the file
    /// Note: InputStream doesn't support seeking, so this recreates the stream
    /// - Throws: Any file opening errors
    public func reset() throws {
        inputStream.close()
        // Note: InputStream doesn't provide a way to get the original URL,
        // so reset functionality is limited. Consider removing this method
        // or storing the original URL if reset is needed.
        throw CocoaError(
            .fileReadUnsupportedScheme,
            userInfo: [
                NSLocalizedDescriptionKey: "Reset not supported with InputStream-based implementation"
            ])
    }

    /// Get the current file offset
    /// Note: InputStream doesn't provide offset information
    /// - Returns: Current position in the file
    /// - Throws: Unsupported operation error
    public func currentOffset() throws -> UInt64 {
        throw CocoaError(
            .fileReadUnsupportedScheme,
            userInfo: [
                NSLocalizedDescriptionKey: "Offset tracking not supported with InputStream-based implementation"
            ])
    }

    /// Seek to a specific offset in the file
    /// Note: InputStream doesn't support seeking
    /// - Parameter offset: The byte offset to seek to
    /// - Throws: Unsupported operation error
    public func seek(to offset: UInt64) throws {
        throw CocoaError(
            .fileReadUnsupportedScheme,
            userInfo: [
                NSLocalizedDescriptionKey: "Seeking not supported with InputStream-based implementation"
            ])
    }

    /// Close the input stream explicitly (called automatically in deinit)
    public func close() {
        inputStream.close()
        isFinished = true
    }
}

/// AsyncIteratorProtocol implementation for BufferedCopyReader
public struct BufferedCopyReaderIterator: AsyncIteratorProtocol {
    public typealias Element = Data

    private let reader: BufferedCopyReader

    init(reader: BufferedCopyReader) {
        self.reader = reader
    }

    /// Get the next chunk of data asynchronously
    /// - Returns: Next data chunk, or nil when finished
    /// - Throws: Any file reading errors
    public mutating func next() async throws -> Data? {
        // Yield control to allow other tasks to run, then read synchronously
        await Task.yield()
        return try reader.nextChunk()
    }
}
