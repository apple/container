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
import Logging
import ContainerizationOS
import ContainerizationExtras
import ContainerizationError
import Darwin

/// Manages I/O sessions for containers with support for history replay
///
/// This class provides unified I/O handling for server-owned PTY session
/// - Always buffers output in ring buffers for history
/// - Forwards output to client pipes using non-blocking I/O
/// - Supports accurate history replay with clear boundary between historical and live data
/// - Server owns all pipes - client connects to server-owned pipes
///
/// Design principles:
/// - Non-blocking writes prevent slow clients from blocking container output
/// - History buffer preserves output for later replay
/// - Simple synchronization ensures accurate history/live boundary
public final class PTYSession: @unchecked Sendable {
    public let containerID: String
    private let logger: Logger
    
    /// I/O mode for this session
    public enum IOMode {
        case pty(master: Terminal, slave: FileHandle)
        case pipes(stdin: Pipe, stdout: Pipe, stderr: Pipe)
    }
    private let ioMode: IOMode
    
    /// Client-facing pipes (server-owned, created once)
    private let clientStdinPipe: Pipe
    private let clientStdoutPipe: Pipe
    private let clientStderrPipe: Pipe?
    
    /// History buffer
    private let historyBuffer: RingBuffer
    
    /// History replay synchronization
    private let historyLock = NSLock()
    private var isReplayingHistory = false
    
    /// Dispatch for I/O handling
    private let readQueue = DispatchQueue(label: "com.apple.container.io.read")
    private var readSources: [DispatchSourceRead] = []

    /// Default buffer size for history (1MB)
    public static let defaultBufferSize = 1024 * 1024
    
    public init(containerID: String, terminal: Bool, bufferSize: Int, logger: Logger) throws {
        self.containerID = containerID
        self.logger = logger
        self.historyBuffer = RingBuffer(capacity: bufferSize)
        
        // Create client-facing pipes
        self.clientStdinPipe = Pipe()
        self.clientStdoutPipe = Pipe()
        
        // Make stdout pipe non-blocking
        let outFD = clientStdoutPipe.fileHandleForWriting.fileDescriptor
        var flags = fcntl(outFD, F_GETFL, 0)
        guard flags != -1 else {
            throw ContainerizationError(.internalError, message: "Failed to get pipe flags", cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM))
        }
        guard fcntl(outFD, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw ContainerizationError(.internalError, message: "Failed to set non-blocking mode", cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM))
        }
        
        if terminal {
            // PTY mode
            let (master, slave) = try Terminal.create()
            self.ioMode = .pty(master: master, slave: FileHandle(fileDescriptor: slave.handle.fileDescriptor, closeOnDealloc: false))
            self.clientStderrPipe = nil // PTY combines stdout/stderr
            
            // Setup forwarding: client stdin -> PTY master
            setupStdinForwarding(from: clientStdinPipe.fileHandleForReading, to: master.handle)
            
            // Start reading from PTY master
            startReading(from: master.handle.fileDescriptor)
            
            logger.debug("PTY session created", metadata: [
                "containerID": "\(containerID)",
                "masterFD": "\(master.handle.fileDescriptor)",
                "slaveFD": "\(slave.handle.fileDescriptor)"
            ])
        } else {
            // Pipe mode
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            self.ioMode = .pipes(stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
            self.clientStderrPipe = Pipe()
            
            // Make stderr pipe non-blocking too
            let errFD = clientStderrPipe!.fileHandleForWriting.fileDescriptor
            flags = fcntl(errFD, F_GETFL, 0)
            guard flags != -1 else {
                throw ContainerizationError(.internalError, message: "Failed to get stderr pipe flags", cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM))
            }
            guard fcntl(errFD, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw ContainerizationError(.internalError, message: "Failed to set stderr non-blocking mode", cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM))
            }
            
            // Setup forwarding: client -> container pipes
            setupStdinForwarding(from: clientStdinPipe.fileHandleForReading, to: stdinPipe.fileHandleForWriting)
            
            // Start reading from container stdout/stderr
            startReading(from: stdoutPipe.fileHandleForReading.fileDescriptor)
            startReading(from: stderrPipe.fileHandleForReading.fileDescriptor, isStderr: true)
            
            logger.debug("Pipe session created", metadata: [
                "containerID": "\(containerID)"
            ])
        }
    }
    
    /// Container-side handles to pass to the container process
    public var containerHandles: [FileHandle?] {
        switch ioMode {
        case .pty(_, let slave):
            return [slave, slave, slave]
        case .pipes(let stdin, let stdout, let stderr):
            return [
                stdin.fileHandleForReading,
                stdout.fileHandleForWriting,
                stderr.fileHandleForWriting
            ]
        }
    }
    
    /// Client-side handles (always the same for a session)
    public var clientHandles: [FileHandle?] {
        return [
            clientStdinPipe.fileHandleForWriting,
            clientStdoutPipe.fileHandleForReading,
            clientStderrPipe?.fileHandleForReading
        ]
    }
    
    /// Send buffered history to client
    /// - Returns: Tuple of (historyBytes, truncated) indicating how much history was sent
    public func sendHistory() -> (bytes: Int, truncated: Bool) {
        logger.info("Sending history for session", metadata: ["containerID": "\(containerID)"])
        
        historyLock.lock()
        isReplayingHistory = true
        
        // Get snapshot of history at this exact moment
        let historyData = historyBuffer.readAll()
        let truncated = historyBuffer.hasWrapped
        
        // Clear the flag - new data after this point is "live"
        isReplayingHistory = false
        historyLock.unlock()
        
        var totalBytes = 0
        if let data = historyData {
            totalBytes = data.count
            
            // Send truncation notice if buffer wrapped
            if truncated {
                let notice = "\n[*** Buffer wrapped - some output was truncated ***]\n"
                if let noticeData = notice.data(using: .utf8) {
                    writeHistoryData(noticeData, to: clientStdoutPipe.fileHandleForWriting)
                }
            }
            
            // Write history (temporarily make blocking for reliable delivery)
            writeHistoryData(data, to: clientStdoutPipe.fileHandleForWriting)
            
            // For pipe mode with stderr, check if we have stderr history
            if case .pipes = ioMode, clientStderrPipe != nil {
                // In current implementation, stderr is mixed with stdout in history
                // This could be enhanced to maintain separate buffers if needed
            }
        }
        
        logger.debug("History sent", metadata: [
            "containerID": "\(containerID)",
            "bytes": "\(totalBytes)",
            "truncated": "\(truncated)"
        ])
        
        return (totalBytes, truncated)
    }
    
    /// Get buffer statistics
    public func getBufferStats() -> (historySize: Int, truncated: Bool) {
        return (
            historySize: historyBuffer.count,
            truncated: historyBuffer.hasWrapped
        )
    }
    
    // MARK: - Private Methods
    
    private func startReading(from fd: Int32, isStderr: Bool = false) {
        logger.debug("Starting to read from descriptor", metadata: [
            "containerID": "\(containerID)",
            "fd": "\(fd)",
            "isStderr": "\(isStderr)"
        ])
        
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: readQueue
        )
        
        source.setEventHandler { [weak self] in
            self?.handleData(from: fd, isStderr: isStderr)
        }
        
        source.setCancelHandler { [weak self] in
            self?.logger.debug("Read source cancelled", metadata: [
                "containerID": "\(self?.containerID ?? "unknown")",
                "fd": "\(fd)"
            ])
        }
        
        source.resume()
        readSources.append(source)
        logger.debug("Read source started", metadata: ["containerID": "\(containerID)", "fd": "\(fd)"])
    }
    
    private func handleData(from fd: Int32, isStderr: Bool) {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        
        let bytesRead = read(fd, buffer, 4096)
        
        guard bytesRead > 0 else {
            if bytesRead < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                logger.error("Read error", metadata: [
                    "containerID": "\(containerID)",
                    "fd": "\(fd)",
                    "error": "\(String(cString: strerror(errno)))"
                ])
            }
            return
        }
        
        let data = Data(bytes: buffer, count: bytesRead)
        
        logger.debug("Read data", metadata: [
            "containerID": "\(containerID)",
            "bytesRead": "\(bytesRead)",
            "isStderr": "\(isStderr)"
        ])
        
        historyLock.lock()
        
        // Always buffer for history
        // For PTY mode or pipe stdout, buffer everything
        // For pipe stderr, only buffer if we have a stderr pipe
        if !isStderr || clientStderrPipe != nil {
            historyBuffer.write(data)
            
            if historyBuffer.hasWrapped {
                logger.debug("Buffer wrapped", metadata: [
                    "containerID": "\(containerID)"
                ])
            }
        }
        
        // Forward to client pipe if not replaying history
        if !isReplayingHistory {
            let pipe = isStderr ? clientStderrPipe! : clientStdoutPipe
            do {
                try pipe.fileHandleForWriting.write(contentsOf: data)
                logger.debug("Forwarded data to client", metadata: [
                    "containerID": "\(containerID)",
                    "bytes": "\(data.count)",
                    "isStderr": "\(isStderr)"
                ])
            } catch {
                // EAGAIN/EWOULDBLOCK - pipe full, client not keeping up
                // This is expected with non-blocking I/O
                if (error as NSError).code != EAGAIN {
                    logger.debug("Failed to write to client pipe", metadata: [
                        "containerID": "\(containerID)",
                        "error": "\(error)",
                        "isStderr": "\(isStderr)"
                    ])
                }
            }
        }
        
        historyLock.unlock()
    }
    
    private func setupStdinForwarding(from source: FileHandle, to dest: FileHandle) {
        source.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            
            do {
                try dest.write(contentsOf: data)
                self?.logger.debug("Forwarded stdin data", metadata: [
                    "containerID": "\(self?.containerID ?? "unknown")",
                    "bytes": "\(data.count)"
                ])
            } catch {
                self?.logger.error("Failed to forward stdin", metadata: [
                    "containerID": "\(self?.containerID ?? "unknown")",
                    "error": "\(error)"
                ])
            }
        }
    }
    
    private func writeHistoryData(_ data: Data, to handle: FileHandle) {
        // Temporarily make blocking for history replay
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        
        if flags != -1 {
            // Clear non-blocking flag
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
            
            do {
                try handle.write(contentsOf: data)
            } catch {
                logger.error("Failed to send history", metadata: [
                    "containerID": "\(containerID)",
                    "error": "\(error)"
                ])
            }
            
            // Restore non-blocking
            _ = fcntl(fd, F_SETFL, flags)
        }
    }
    
    public func cleanup() {
        logger.debug("Cleaning up session", metadata: ["containerID": "\(containerID)"])
        
        for source in readSources {
            source.cancel()
        }
        readSources.removeAll()
        
        // Clear stdin handlers
        clientStdinPipe.fileHandleForReading.readabilityHandler = nil
        
        // Close handles based on mode
        switch ioMode {
        case .pty(let master, let slave):
            try? master.reset()
            try? slave.close()
        case .pipes(let stdin, let stdout, let stderr):
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
    }
    
    deinit {
        cleanup()
    }
}

/// A thread-safe ring buffer for storing output data
private final class RingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int
    private var head: Int = 0
    private var tail: Int = 0
    private var _count: Int = 0
    private var _hasWrapped: Bool = false
    private let lock = NSLock()
    
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
    
    var hasWrapped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _hasWrapped
    }
    
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
    }
    
    deinit {
        buffer.deallocate()
    }
    
    func write(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            let bytesToWrite = data.count
            
            // If data is larger than buffer, only keep the last part
            let dataOffset = max(0, bytesToWrite - capacity)
            let actualBytesToWrite = min(bytesToWrite, capacity)
            
            data.withUnsafeBytes { bytes in
                let src = bytes.baseAddress!.advanced(by: dataOffset)
                
                if actualBytesToWrite >= capacity {
                    // Complete overwrite
                    buffer.copyMemory(from: src, byteCount: capacity)
                    head = 0
                    tail = 0
                    _count = capacity
                    _hasWrapped = true
                } else {
                    // Normal write
                    var written = 0
                    while written < actualBytesToWrite {
                        let spaceToEnd = capacity - head
                        let toWrite = min(actualBytesToWrite - written, spaceToEnd)
                        
                        buffer.advanced(by: head).copyMemory(
                            from: src.advanced(by: written),
                            byteCount: toWrite
                        )
                        
                        written += toWrite
                        head = (head + toWrite) % capacity
                        
                        if _count < capacity {
                            _count = min(_count + toWrite, capacity)
                        } else {
                            // Buffer is full, advance tail
                            tail = head
                            _hasWrapped = true
                        }
                    }
                }
            }
        }
    
    func readAll() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        
        guard _count > 0 else { return nil }
        
        var data = Data(count: _count)
        data.withUnsafeMutableBytes { bytes in
            let dst = bytes.baseAddress!
            
            if tail < head {
                // Continuous read
                dst.copyMemory(from: buffer.advanced(by: tail), byteCount: _count)
            } else {
                // Wrapped read
                let firstPart = capacity - tail
                dst.copyMemory(from: buffer.advanced(by: tail), byteCount: firstPart)
                dst.advanced(by: firstPart).copyMemory(from: buffer, byteCount: head)
            }
        }
        
        // Don't clear the buffer after reading (keep history)
        return data
    }
}