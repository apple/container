//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import Containerization
import Foundation

/// Response from a credential helper execution
struct CredentialHelperResponse: Codable {
    let ServerURL: String
    let Username: String
    let Secret: String
}

/// Executes Docker credential helpers to retrieve registry credentials
public struct CredentialHelperExecutor: Sendable {
    public init() {}

    /// Execute a credential helper for a given host
    /// - Parameters:
    ///   - helperName: The name of the credential helper (e.g., "cgr" for "docker-credential-cgr")
    ///   - host: The registry host to get credentials for
    /// - Returns: Authentication if the helper succeeded, nil otherwise
    public func execute(helperName: String, for host: String) async -> Authentication? {
        // Validate helper name to prevent unexpected characters
        let allowedCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard helperName.rangeOfCharacter(from: allowedCharacterSet.inverted) == nil else {
            return nil
        }

        let executableName = "docker-credential-\(helperName)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executableName, "get"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Write the host to stdin
            let hostData = Data("\(host)\n".utf8)
            inputPipe.fileHandleForWriting.write(hostData)
            // Close stdin to signal EOF to the credential helper
            try inputPipe.fileHandleForWriting.close()

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

            let decoder = JSONDecoder()
            let response = try decoder.decode(CredentialHelperResponse.self, from: outputData)

            return BasicAuthentication(username: response.Username, password: response.Secret)
        } catch {
            // Ensure stdin is closed even if we error out
            try? inputPipe.fileHandleForWriting.close()
            return nil
        }
    }
}
