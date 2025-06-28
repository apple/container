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

/// Manages PTY sessions for containers with support for attach
///
/// This class implements an always-buffer approach for container I/O:
/// - Always: All output is captured in ring buffers for history
/// - When attached: Output is also forwarded directly to client
/// - When detached: Only buffering occurs (no forwarding)
/// - On attach: Optionally replay buffered history then forward new output
///
/// Note: This design prioritizes simplicity over perfect backpressure.
/// High-volume output may wrap the ring buffer if clients can't keep up.
public actor PTYSessionManager {
    private let logger: Logger
    private var sessions: [String: PTYSession] = [:]
    
    /// Default buffer size for each stream (1MB)
    private let defaultBufferSize = 1024 * 1024
    
    public init(logger: Logger) {
        self.logger = logger
    }
    
    /// Create a new PTY session for a container
    public func createSession(containerID: String, bufferSize: Int? = nil) throws -> PTYSession {
        logger.info("Creating PTY session", metadata: [
            "containerID": "\(containerID)",
            "bufferSize": "\(bufferSize ?? defaultBufferSize)"
        ])
        
        let session = try PTYSession(
            containerID: containerID,
            bufferSize: bufferSize ?? defaultBufferSize,
            logger: logger
        )
        
        sessions[containerID] = session
        return session
    }
    
    /// Get an existing session
    public func getSession(containerID: String) -> PTYSession? {
        return sessions[containerID]
    }
    
    /// Remove a session (when container exits)
    public func removeSession(containerID: String) {
        logger.info("Removing PTY session", metadata: ["containerID": "\(containerID)"])
        if let session = sessions.removeValue(forKey: containerID) {
            session.cleanup()
        }
    }
    
}

/// Represents a single PTY session for a container
public final class PTYSession: @unchecked Sendable {
    public let containerID: String
    private let logger: Logger
    
    /// The PTY master file descriptor
    public let ptyMaster: Terminal
    
    /// The PTY slave file descriptor (passed to container)
    public let ptySlave: FileHandle
    
    /// Ring buffers for stdout/stderr when detached
    private let stdoutBuffer: RingBuffer
    private let stderrBuffer: RingBuffer
    
    /// Current attachment state
    private var attachmentState = AttachmentState.detached
    private let stateLock = NSLock()
    
    /// Dispatch queues for I/O handling
    private let ioQueue = DispatchQueue(label: "com.apple.container.pty.io", attributes: .concurrent)
    private var readSource: DispatchSourceRead?
    
    private enum AttachmentState {
        case attached(clientHandles: ClientHandles)
        case detached
    }
    
    private struct ClientHandles {
        let stdout: FileHandle
        let stderr: FileHandle
        let stdin: FileHandle?
    }
    
    init(containerID: String, bufferSize: Int, logger: Logger) throws {
        self.containerID = containerID
        self.logger = logger
        
        // Create PTY pair
        let (master, slave) = try Terminal.create()
        self.ptyMaster = master
        self.ptySlave = FileHandle(fileDescriptor: slave.handle.fileDescriptor, closeOnDealloc: false)
        
        // Initialize ring buffers
        self.stdoutBuffer = RingBuffer(capacity: bufferSize)
        self.stderrBuffer = RingBuffer(capacity: bufferSize)
        
        // Start reading from PTY master
        startReading()
        
        logger.debug("PTY session created", metadata: [
            "containerID": "\(containerID)",
            "masterFD": "\(master.handle.fileDescriptor)",
            "slaveFD": "\(slave.handle.fileDescriptor)"
        ])
    }
    
    /// Attach a client to this session
    /// - Parameters:
    ///   - stdout: Client's stdout handle
    ///   - stderr: Client's stderr handle  
    ///   - stdin: Client's stdin handle (optional)
    ///   - sendHistory: Whether to send buffered history
    /// - Returns: Tuple of (historyBytes, truncated) indicating how much history was sent
    public func attach(stdout: FileHandle, stderr: FileHandle, stdin: FileHandle?, sendHistory: Bool = true) throws -> (Int, Bool) {
        logger.info("Attaching to PTY session", metadata: ["containerID": "\(containerID)"])
        
        var historyBytes = 0
        var truncated = false
        
        stateLock.lock()
        defer { stateLock.unlock() }
        
        // Send buffered history if requested
        if sendHistory {
            let (bytes, trunc) = sendBufferedHistory(stdout: stdout, stderr: stderr)
            historyBytes = bytes
            truncated = trunc
        }
        
        // Update state to attached
        attachmentState = .attached(clientHandles: ClientHandles(
            stdout: stdout,
            stderr: stderr,
            stdin: stdin
        ))
        
        // Auto-detach when stdout is closed
        stdout.readabilityHandler = { [weak self] _ in
            // When client closes, this fires with empty data
            self?.autoDetach()
        }
        
        // Set up stdin forwarding if provided
        if let stdin = stdin {
            setupStdinForwarding(from: stdin)
        }
        
        return (historyBytes, truncated)
    }
    
    
    /// Check if session is currently attached
    public var isAttached: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        if case .attached = attachmentState {
            return true
        }
        return false
    }
    
    /// Auto-detach when client disconnects
    private func autoDetach() {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        if case .attached(let handles) = attachmentState {
            logger.info("Auto-detaching from PTY session (client disconnected)", metadata: ["containerID": "\(containerID)"])
            handles.stdin?.readabilityHandler = nil
            handles.stdout.readabilityHandler = nil
            attachmentState = .detached
        }
    }
    
    /// Get buffer statistics
    public func getBufferStats() -> (stdoutSize: Int, stderrSize: Int, stdoutTruncated: Bool, stderrTruncated: Bool) {
        return (
            stdoutSize: stdoutBuffer.count,
            stderrSize: stderrBuffer.count,
            stdoutTruncated: stdoutBuffer.hasWrapped,
            stderrTruncated: stderrBuffer.hasWrapped
        )
    }
    
    // MARK: - Private Methods
    
    private func startReading() {
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: ptyMaster.handle.fileDescriptor,
            queue: ioQueue
        )
        
        readSource?.setEventHandler { [weak self] in
            self?.handlePTYData()
        }
        
        readSource?.setCancelHandler { [weak self] in
            self?.logger.debug("PTY read source cancelled", metadata: [
                "containerID": "\(self?.containerID ?? "unknown")"
            ])
        }
        
        readSource?.resume()
    }
    
    private func handlePTYData() {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        
        let bytesRead = read(ptyMaster.handle.fileDescriptor, buffer, 4096)
        
        guard bytesRead > 0 else {
            if bytesRead < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                logger.error("PTY read error", metadata: [
                    "containerID": "\(containerID)",
                    "error": "\(String(cString: strerror(errno)))"
                ])
            }
            return
        }
        
        let data = Data(bytes: buffer, count: bytesRead)
        
        // Always buffer data for history/reattachment
        // For PTY, we only use stdout buffer since PTY combines both streams
        stdoutBuffer.write(data)
        
        if stdoutBuffer.hasWrapped {
            logger.debug("Buffer wrapped", metadata: [
                "containerID": "\(containerID)",
                "stream": "stdout"
            ])
        }
        
        // Also forward directly if attached
        stateLock.lock()
        let state = attachmentState
        stateLock.unlock()
        
        if case .attached(let handles) = state {
            do {
                // For PTY, both stdout and stderr go to the same stream
                try handles.stdout.write(contentsOf: data)
            } catch {
                logger.error("Failed to write to client", metadata: [
                    "containerID": "\(containerID)",
                    "error": "\(error)"
                ])
                // Could auto-detach here if write fails consistently
            }
        }
    }
    
    private func setupStdinForwarding(from clientStdin: FileHandle) {
        clientStdin.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            
            do {
                // Write to PTY master
                try self.ptyMaster.handle.write(contentsOf: data)
            } catch {
                self.logger.error("Failed to write to PTY", metadata: [
                    "containerID": "\(self.containerID)",
                    "error": "\(error)"
                ])
            }
        }
    }
    
    private func sendBufferedHistory(stdout: FileHandle, stderr: FileHandle) -> (Int, Bool) {
        var totalBytes = 0
        var truncated = false
        
        // Send truncation notice if buffer wrapped
        if stdoutBuffer.hasWrapped {
            truncated = true
            let notice = "\n[*** Buffer wrapped - some output was truncated ***]\n"
            if let noticeData = notice.data(using: .utf8) {
                try? stdout.write(contentsOf: noticeData)
            }
        }
        
        // Send buffered stdout
        if let historyData = stdoutBuffer.readAll() {
            totalBytes += historyData.count
            try? stdout.write(contentsOf: historyData)
        }
        
        // Note: For PTY sessions, stderr is combined with stdout
        // so we don't need to send stderr buffer separately
        
        return (totalBytes, truncated)
    }
    
    func cleanup() {
        logger.debug("Cleaning up PTY session", metadata: ["containerID": "\(containerID)"])
        
        readSource?.cancel()
        readSource = nil
        
        stateLock.lock()
        defer { stateLock.unlock() }
        
        if case .attached(let handles) = attachmentState {
            handles.stdin?.readabilityHandler = nil
        }
        
        // Close PTY
        try? ptyMaster.reset()
        try? ptySlave.close()
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