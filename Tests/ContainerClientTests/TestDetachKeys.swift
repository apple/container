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

import Testing
import Foundation
@testable import ContainerClient

/// Test suite for detach key sequence detection and parsing
struct TestDetachKeys {
    
    @Test("Default sequence is ctrl-p,ctrl-q")
    func testDefaultSequence() {
        #expect(DetachKeys.defaultSequence == "ctrl-p,ctrl-q")
    }
    
    @Test("Parse ctrl-p control character")
    func testParseCtrlP() {
        var detachKeys = DetachKeys("ctrl-p")
        
        // Send ctrl-p (0x10)
        let result = detachKeys.checkByte(0x10)
        #expect(result == .detach)
    }
    
    @Test("Parse ctrl-q control character")
    func testParseCtrlQ() {
        var detachKeys = DetachKeys("ctrl-q")
        
        // Send ctrl-q (0x11)
        let result = detachKeys.checkByte(0x11)
        #expect(result == .detach)
    }
    
    @Test("Default ctrl-p,ctrl-q sequence detection")
    func testDefaultSequenceDetection() {
        var detachKeys = DetachKeys()
        
        // Send ctrl-p (0x10)
        var result = detachKeys.checkByte(0x10)
        #expect(result == .inProgress)
        
        // Send ctrl-q (0x11)
        result = detachKeys.checkByte(0x11)
        #expect(result == .detach)
    }
    
    @Test("Partial sequence followed by wrong key resets")
    func testPartialSequenceReset() {
        var detachKeys = DetachKeys()
        
        // Send ctrl-p (0x10)
        var result = detachKeys.checkByte(0x10)
        #expect(result == .inProgress)
        
        // Send wrong key (e.g., 'a')
        result = detachKeys.checkByte(0x61) // 'a'
        #expect(result == .reset)
        
        // State should be reset, sending ctrl-p should start sequence again
        result = detachKeys.checkByte(0x10)
        #expect(result == .inProgress)
    }
    
    @Test("Custom sequence parsing")
    func testCustomSequence() {
        var detachKeys = DetachKeys("ctrl-a,ctrl-b")
        
        // Send ctrl-a (0x01)
        var result = detachKeys.checkByte(0x01)
        #expect(result == .inProgress)
        
        // Send ctrl-b (0x02)
        result = detachKeys.checkByte(0x02)
        #expect(result == .detach)
    }
    
    @Test("Single key sequence")
    func testSingleKeySequence() {
        var detachKeys = DetachKeys("ctrl-x")
        
        // Send ctrl-x (0x18)
        let result = detachKeys.checkByte(0x18)
        #expect(result == .detach)
    }
    
    @Test("Three key sequence")
    func testThreeKeySequence() {
        var detachKeys = DetachKeys("ctrl-a,ctrl-b,ctrl-c")
        
        // Send ctrl-a (0x01)
        var result = detachKeys.checkByte(0x01)
        #expect(result == .inProgress)
        
        // Send ctrl-b (0x02)
        result = detachKeys.checkByte(0x02)
        #expect(result == .inProgress)
        
        // Send ctrl-c (0x03)
        result = detachKeys.checkByte(0x03)
        #expect(result == .detach)
    }
    
    @Test("Invalid sequence string")
    func testInvalidSequence() {
        let detachKeys = DetachKeys("invalid-key")
        // Should create empty sequence, so any byte should reset
        var mutableKeys = detachKeys
        let result = mutableKeys.checkByte(0x10)
        #expect(result == .reset)
    }
    
    @Test("Reset functionality")
    func testReset() {
        var detachKeys = DetachKeys()
        
        // Start sequence
        var result = detachKeys.checkByte(0x10) // ctrl-p
        #expect(result == .inProgress)
        
        // Reset
        detachKeys.reset()
        
        // Next byte should start fresh
        result = detachKeys.checkByte(0x10) // ctrl-p again
        #expect(result == .inProgress)
    }
    
    @Test("Special key parsing")
    func testSpecialKeys() {
        var enterKeys = DetachKeys("enter")
        var result = enterKeys.checkByte(0x0D) // CR
        #expect(result == .detach)
        
        var tabKeys = DetachKeys("tab")
        result = tabKeys.checkByte(0x09) // Tab
        #expect(result == .detach)
        
        var escapeKeys = DetachKeys("escape")
        result = escapeKeys.checkByte(0x1B) // Escape
        #expect(result == .detach)
    }
    
    @Test("Case insensitive parsing")
    func testCaseInsensitive() {
        var upperKeys = DetachKeys("CTRL-P")
        var lowerKeys = DetachKeys("ctrl-p")
        
        // Both should produce same result
        let upperResult = upperKeys.checkByte(0x10)
        let lowerResult = lowerKeys.checkByte(0x10)
        
        #expect(upperResult == .detach)
        #expect(lowerResult == .detach)
    }
}

/// Test suite for DetachKeyDetector actor functionality
@Suite("DetachKeyDetector actor")
struct DetachKeyDetectorTests {
    
    @Test("Basic input processing")
    func testBasicInputProcessing() async {
        let detector = DetachKeyDetector()
        
        // Send normal data - should be forwarded
        let normalData = Data("hello".utf8)
        let (shouldDetach, dataToForward) = await detector.processInput(normalData)
        
        #expect(!shouldDetach)
        #expect(dataToForward == normalData)
    }
    
    @Test("Detach sequence detection")
    func testDetachSequenceDetection() async {
        let detector = DetachKeyDetector()
        
        // Send ctrl-p, ctrl-q sequence
        let ctrlP = Data([0x10])
        let ctrlQ = Data([0x11])
        
        // First part of sequence
        let (shouldDetach1, dataToForward1) = await detector.processInput(ctrlP)
        #expect(!shouldDetach1)
        #expect(dataToForward1.isEmpty) // Buffered, not forwarded
        
        // Complete sequence
        let (shouldDetach2, dataToForward2) = await detector.processInput(ctrlQ)
        #expect(shouldDetach2)
        #expect(dataToForward2.isEmpty) // Sequence consumed
    }
    
    @Test("Partial sequence then normal data")
    func testPartialSequenceThenNormalData() async {
        let detector = DetachKeyDetector()
        
        // Send ctrl-p (start of sequence)
        let ctrlP = Data([0x10])
        let (shouldDetach1, dataToForward1) = await detector.processInput(ctrlP)
        #expect(!shouldDetach1)
        #expect(dataToForward1.isEmpty)
        
        // Send normal character (should reset and forward buffered + new data)
        let normalData = Data("a".utf8)
        let (shouldDetach2, dataToForward2) = await detector.processInput(normalData)
        #expect(!shouldDetach2)
        
        // Should forward both the buffered ctrl-p and the 'a'
        let expectedData = Data([0x10]) + normalData
        #expect(dataToForward2 == expectedData)
    }
    
    @Test("Multiple data chunks with sequence")
    func testMultipleChunksWithSequence() async {
        let detector = DetachKeyDetector()
        
        // Send data chunk with ctrl-p at the end
        let chunk1 = Data("hello\u{10}".utf8) // hello + ctrl-p
        let (shouldDetach1, dataToForward1) = await detector.processInput(chunk1)
        #expect(!shouldDetach1)
        // Should forward "hello" but buffer ctrl-p
        #expect(dataToForward1 == Data("hello".utf8))
        
        // Send ctrl-q to complete sequence
        let chunk2 = Data([0x11])
        let (shouldDetach2, dataToForward2) = await detector.processInput(chunk2)
        #expect(shouldDetach2)
        #expect(dataToForward2.isEmpty)
    }
    
    @Test("Custom detach sequence")
    func testCustomDetachSequence() async {
        let detector = DetachKeyDetector(sequence: "ctrl-a,ctrl-x")
        
        // Send ctrl-a
        let ctrlA = Data([0x01])
        let (shouldDetach1, dataToForward1) = await detector.processInput(ctrlA)
        #expect(!shouldDetach1)
        #expect(dataToForward1.isEmpty)
        
        // Send ctrl-x to complete custom sequence
        let ctrlX = Data([0x18])
        let (shouldDetach2, dataToForward2) = await detector.processInput(ctrlX)
        #expect(shouldDetach2)
        #expect(dataToForward2.isEmpty)
    }
    
    @Test("Flush buffered data")
    func testFlushBufferedData() async {
        let detector = DetachKeyDetector()
        
        // Send partial sequence
        let ctrlP = Data([0x10])
        let (shouldDetach, dataToForward) = await detector.processInput(ctrlP)
        #expect(!shouldDetach)
        #expect(dataToForward.isEmpty)
        
        // Flush should return buffered data
        let flushedData = await detector.flush()
        #expect(flushedData == ctrlP)
        
        // After flush, detector should be reset
        let (shouldDetach2, dataToForward2) = await detector.processInput(ctrlP)
        #expect(!shouldDetach2)
        #expect(dataToForward2.isEmpty) // Should buffer again
    }
    
    @Test("Reset detector state")
    func testResetDetectorState() async {
        let detector = DetachKeyDetector()
        
        // Send partial sequence
        let ctrlP = Data([0x10])
        let (shouldDetach, dataToForward) = await detector.processInput(ctrlP)
        #expect(!shouldDetach)
        #expect(dataToForward.isEmpty)
        
        // Reset
        await detector.reset()
        
        // After reset, should start fresh
        let (shouldDetach2, dataToForward2) = await detector.processInput(ctrlP)
        #expect(!shouldDetach2)
        #expect(dataToForward2.isEmpty) // Should buffer again, not forward
    }
    
    @Test("Empty input data")
    func testEmptyInputData() async {
        let detector = DetachKeyDetector()
        
        let emptyData = Data()
        let (shouldDetach, dataToForward) = await detector.processInput(emptyData)
        
        #expect(!shouldDetach)
        #expect(dataToForward.isEmpty)
    }
    
    @Test("Large input data with sequence at various positions")
    func testLargeInputWithSequence() async {
        let detector = DetachKeyDetector()
        
        // Create large data with ctrl-p, ctrl-q in the middle
        var largeData = Data("start".utf8)
        largeData.append(contentsOf: Array(repeating: UInt8(65), count: 1000)) // 1000 'A's
        largeData.append(0x10) // ctrl-p
        largeData.append(0x11) // ctrl-q
        largeData.append(contentsOf: "end".utf8)
        
        let (shouldDetach, dataToForward) = await detector.processInput(largeData)
        
        #expect(shouldDetach)
        // Should forward everything before the detach sequence
        // The "end" part after the detach sequence should be ignored (not forwarded)
        let expectedForwarded = Data("start".utf8) + Data(Array(repeating: UInt8(65), count: 1000))
        #expect(dataToForward == expectedForwarded, "Should only forward data before detach sequence")
    }
}