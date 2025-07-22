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

/// Handles detection and parsing of detach key sequences for interactive containers
/// Matches Docker's behavior with ctrl-p,ctrl-q as the default sequence
public struct DetachKeys: Sendable {
    /// The default detach key sequence matching Docker's behavior
    public static let defaultSequence = "ctrl-p,ctrl-q"
    
    /// Parsed key sequence for detection
    private let sequence: [UInt8]
    
    /// Current position in the sequence detection
    private var position: Int = 0
    
    /// Initialize with a key sequence string
    /// - Parameter sequenceString: Comma-separated key sequence (e.g., "ctrl-p,ctrl-q")
    public init(_ sequenceString: String = defaultSequence) {
        self.sequence = Self.parseSequence(sequenceString)
    }
    
    /// Check if the given byte matches the next expected key in the sequence
    /// - Parameter byte: Input byte to check
    /// - Returns: DetachResult indicating if sequence is in progress, completed, or reset
    public mutating func checkByte(_ byte: UInt8) -> DetachResult {
        if position < sequence.count && byte == sequence[position] {
            position += 1
            if position == sequence.count {
                // Complete sequence detected
                position = 0
                return .detach
            }
            return .inProgress
        } else {
            // Reset sequence detection
            position = 0
            // Check if this byte starts the sequence
            if !sequence.isEmpty && byte == sequence[0] {
                position = 1
                return .inProgress
            }
            return .reset
        }
    }
    
    /// Reset the sequence detection state
    public mutating func reset() {
        position = 0
    }
    
    /// Parse a sequence string into control character bytes
    /// - Parameter sequenceString: Input sequence (e.g., "ctrl-p,ctrl-q")
    /// - Returns: Array of control character bytes
    private static func parseSequence(_ sequenceString: String) -> [UInt8] {
        let parts = sequenceString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.compactMap { parseKey(String($0)) }
    }
    
    /// Parse a single key string into its control character byte value
    /// - Parameter keyString: Key specification (e.g., "ctrl-p", "ctrl-q")
    /// - Returns: Control character byte value, or nil if invalid
    private static func parseKey(_ keyString: String) -> UInt8? {
        let lowercased = keyString.lowercased()
        
        // Handle ctrl-X format
        if lowercased.hasPrefix("ctrl-") && lowercased.count == 6 {
            let char = lowercased.last!
            switch char {
            case "a": return 0x01  // Ctrl-A
            case "b": return 0x02  // Ctrl-B
            case "c": return 0x03  // Ctrl-C
            case "d": return 0x04  // Ctrl-D
            case "e": return 0x05  // Ctrl-E
            case "f": return 0x06  // Ctrl-F
            case "g": return 0x07  // Ctrl-G
            case "h": return 0x08  // Ctrl-H
            case "i": return 0x09  // Ctrl-I (Tab)
            case "j": return 0x0A  // Ctrl-J (LF)
            case "k": return 0x0B  // Ctrl-K
            case "l": return 0x0C  // Ctrl-L
            case "m": return 0x0D  // Ctrl-M (CR)
            case "n": return 0x0E  // Ctrl-N
            case "o": return 0x0F  // Ctrl-O
            case "p": return 0x10  // Ctrl-P
            case "q": return 0x11  // Ctrl-Q
            case "r": return 0x12  // Ctrl-R
            case "s": return 0x13  // Ctrl-S
            case "t": return 0x14  // Ctrl-T
            case "u": return 0x15  // Ctrl-U
            case "v": return 0x16  // Ctrl-V
            case "w": return 0x17  // Ctrl-W
            case "x": return 0x18  // Ctrl-X
            case "y": return 0x19  // Ctrl-Y
            case "z": return 0x1A  // Ctrl-Z
            default: return nil
            }
        }
        
        // Handle special keys
        switch lowercased {
        case "enter", "return": return 0x0D
        case "tab": return 0x09
        case "escape", "esc": return 0x1B
        case "space": return 0x20
        case "backspace": return 0x08
        case "delete", "del": return 0x7F
        default: break
        }
        
        // Handle single character
        if keyString.count == 1 {
            return keyString.utf8.first
        }
        
        return nil
    }
}

/// Result of detach key sequence detection
public enum DetachResult: Sendable {
    /// Still detecting sequence, don't forward the byte
    case inProgress
    /// Complete detach sequence detected
    case detach
    /// Sequence reset, forward all buffered bytes
    case reset
}

/// Detach key detector for processing input streams
public actor DetachKeyDetector {
    private var detachKeys: DetachKeys
    private var buffer: [UInt8] = []
    
    public init(sequence: String = DetachKeys.defaultSequence) {
        self.detachKeys = DetachKeys(sequence)
    }
    
    /// Process input data and detect detach sequences
    /// - Parameter data: Input data to process
    /// - Returns: Tuple of (shouldDetach, dataToForward)
    public func processInput(_ data: Data) -> (shouldDetach: Bool, dataToForward: Data) {
        var shouldDetach = false
        var outputBytes: [UInt8] = []
        
        for byte in data {
            let result = detachKeys.checkByte(byte)
            
            switch result {
            case .inProgress:
                // Buffer this byte, don't forward yet
                buffer.append(byte)
                
            case .detach:
                // Detach sequence complete, don't forward any buffered bytes
                buffer.removeAll()
                shouldDetach = true
                // Break out of the for loop, not just the switch
                return (shouldDetach: true, dataToForward: Data(outputBytes))
                
            case .reset:
                // Forward any buffered bytes plus this byte
                outputBytes.append(contentsOf: buffer)
                outputBytes.append(byte)
                buffer.removeAll()
            }
        }
        
        return (shouldDetach: shouldDetach, dataToForward: Data(outputBytes))
    }
    
    /// Flush any buffered bytes (e.g., on connection close)
    public func flush() -> Data {
        let data = Data(buffer)
        buffer.removeAll()
        detachKeys.reset()
        return data
    }
    
    /// Reset the detector state
    public func reset() {
        buffer.removeAll()
        detachKeys.reset()
    }
}