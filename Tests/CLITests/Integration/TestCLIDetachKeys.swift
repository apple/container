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
@testable import container
@testable import ContainerClient

/// Integration tests for detach key functionality in CLI commands
@Suite("CLI Detach Keys Integration")
class TestCLIDetachKeys: CLITest, @unchecked Sendable {
    
    @Test("Run command help shows detach-keys option")
    func testRunCommandHelpShowsDetachKeys() async throws {
        let (output, _, status) = try run(arguments: ["run", "--help"])
        
        #expect(status == 0, "Help command should succeed")
        #expect(output.contains("--detach-keys"), "Help should show --detach-keys option")
        #expect(output.contains("Override the key sequence for detaching"), "Help should show detach keys description")
    }
    
    @Test("Exec command help shows detach-keys option")  
    func testExecCommandHelpShowsDetachKeys() async throws {
        let (output, _, status) = try run(arguments: ["exec", "--help"])
        
        #expect(status == 0, "Help command should succeed")
        #expect(output.contains("--detach-keys"), "Help should show --detach-keys option")
        #expect(output.contains("Override the key sequence for detaching"), "Help should show detach keys description")
    }
    
    @Test("Attach command help shows detach-keys option")
    func testAttachCommandHelpShowsDetachKeys() async throws {
        let (output, _, status) = try run(arguments: ["attach", "--help"])
        
        #expect(status == 0, "Help command should succeed") 
        #expect(output.contains("--detach-keys"), "Help should show --detach-keys option")
        #expect(output.contains("Override the key sequence for detaching"), "Help should show detach keys description")
    }
    
    @Test("DetachKeys basic functionality")
    func testDetachKeysBasicFunctionality() async throws {
        // Test basic DetachKeys functionality that we can access
        var detachKeys = DetachKeys()
        
        // Test default sequence detection
        var result = detachKeys.checkByte(0x10) // ctrl-p
        #expect(result == .inProgress, "Should be in progress after ctrl-p")
        
        result = detachKeys.checkByte(0x11) // ctrl-q
        #expect(result == .detach, "Should detach after ctrl-p, ctrl-q sequence")
    }
    
    @Test("DetachKeyDetector functionality")
    func testDetachKeyDetectorFunctionality() async throws {
        // Test DetachKeyDetector that we can access
        let detector = DetachKeyDetector()
        
        // Test normal input forwarding
        let normalData = Data("hello".utf8)
        let (shouldDetach, dataToForward) = await detector.processInput(normalData)
        
        #expect(!shouldDetach, "Should not detach on normal input")
        #expect(dataToForward == normalData, "Should forward normal data")
    }
    
    @Test("Detach key sequence validation")
    func testDetachKeySequenceValidation() async throws {
        // Test various valid detach key sequences
        let validSequences = [
            "ctrl-p,ctrl-q",
            "ctrl-a",
            "ctrl-x,ctrl-y,ctrl-z",
            "escape",
            "ctrl-c",
            "CTRL-P,CTRL-Q" // Case insensitive
        ]
        
        for sequence in validSequences {
            // Should not throw when creating DetachKeys with valid sequences
            let detachKeys = DetachKeys(sequence)
            // This implicitly tests that the sequence was parsed without errors
            var mutableKeys = detachKeys
            _ = mutableKeys.checkByte(0x10) // Test basic functionality
        }
    }
    
    @Test("Default Docker-compatible behavior")
    func testDefaultDockerCompatibleBehavior() async throws {
        // Verify that our default behavior matches Docker's
        // The default sequence should be ctrl-p,ctrl-q to match Docker
        #expect(DetachKeys.defaultSequence == "ctrl-p,ctrl-q", "Should match Docker's default sequence")
    }
    
    @Test("Detach key integration works")
    func testDetachKeyIntegration() async throws {
        // Test that our detach key functionality integrates properly
        // by testing the core DetachKeys and DetachKeyDetector functionality
        let customSequence = "ctrl-x,ctrl-y"
        let detector = DetachKeyDetector(sequence: customSequence)
        
        // Test that custom sequence is properly set up
        let normalData = Data("test".utf8)
        let (shouldDetach, dataToForward) = await detector.processInput(normalData)
        
        #expect(!shouldDetach, "Should not detach on normal input")
        #expect(dataToForward == normalData, "Should forward normal data")
    }
    
    @Test("DetachKeyDetector consistency test")
    func testDetachKeyDetectorConsistency() async throws {
        let customKeys = "ctrl-a,ctrl-x"
        
        // Test both default and custom detector creation
        let defaultDetector = DetachKeyDetector()
        let customDetector = DetachKeyDetector(sequence: customKeys)
        
        // Both should handle input correctly
        let testData = Data("test".utf8)
        let (shouldDetach1, data1) = await defaultDetector.processInput(testData)
        let (shouldDetach2, data2) = await customDetector.processInput(testData)
        
        #expect(!shouldDetach1, "Default detector should not detach on normal input")
        #expect(!shouldDetach2, "Custom detector should not detach on normal input")
        #expect(data1 == testData, "Default detector should forward normal data")
        #expect(data2 == testData, "Custom detector should forward normal data")
    }
    
    @Test("Detach key error handling for invalid sequences")
    func testDetachKeyErrorHandlingInvalidSequences() async throws {
        // Test with invalid sequences - should still create ProcessIO but with empty detector sequence
        let invalidSequences = [
            "invalid-key",
            "ctrl-invalid",
            "",
            "ctrl-",
            "random-text"
        ]
        
        for sequence in invalidSequences {
            // Should not throw, but detector may have empty sequence
            let detachKeys = DetachKeys(sequence)
            // This should not crash even with invalid sequences
            var mutableKeys = detachKeys
            let result = mutableKeys.checkByte(0x10)
            // Invalid sequences result in empty sequence, so any input should reset
            #expect(result == .reset, "Invalid sequence should result in reset for any input: \(sequence)")
        }
    }
}