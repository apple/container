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
//  Helper Functions.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation
import Yams
import Rainbow
import ContainerCLI

//extension Application {
    /// Loads environment variables from a .env file.
    /// - Parameter path: The full path to the .env file.
    /// - Returns: A dictionary of key-value pairs representing environment variables.
    internal func loadEnvFile(path: String) -> [String: String] {
        var envVars: [String: String] = [:]
        let fileURL = URL(fileURLWithPath: path)
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.split(separator: "\n")
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // Ignore empty lines and comments
                if !trimmedLine.isEmpty && !trimmedLine.starts(with: "#") {
                    // Parse key=value pairs
                    if let eqIndex = trimmedLine.firstIndex(of: "=") {
                        let key = String(trimmedLine[..<eqIndex])
                        let value = String(trimmedLine[trimmedLine.index(after: eqIndex)...])
                        envVars[key] = value
                    }
                }
            }
        } catch {
            // print("Warning: Could not read .env file at \(path): \(error.localizedDescription)")
            // Suppress error message if .env file is optional or missing
        }
        return envVars
    }
    
    /// Resolves environment variables within a string (e.g., ${VAR:-default}, ${VAR:?error}).
    /// This function supports default values and error-on-missing variable syntax.
    /// - Parameters:
    ///   - value: The string possibly containing environment variable references.
    ///   - envVars: A dictionary of environment variables to use for resolution.
    /// - Returns: The string with all recognized environment variables resolved.
    internal func resolveVariable(_ value: String, with envVars: [String: String]) -> String {
        var resolvedValue = value
        // Regex to find ${VAR}, ${VAR:-default}, ${VAR:?error}
        let regex = try! NSRegularExpression(pattern: "\\$\\{([A-Z0-9_]+)(:?-(.*?))?(:\\?(.*?))?\\}", options: [])
        
        // Combine process environment with loaded .env file variables, prioritizing process environment
        let combinedEnv = ProcessInfo.processInfo.environment.merging(envVars) { (current, _) in current }
        
        // Loop to resolve all occurrences of variables in the string
        while let match = regex.firstMatch(in: resolvedValue, options: [], range: NSRange(resolvedValue.startIndex..<resolvedValue.endIndex, in: resolvedValue)) {
            guard let varNameRange = Range(match.range(at: 1), in: resolvedValue) else { break }
            let varName = String(resolvedValue[varNameRange])
            
            if let envValue = combinedEnv[varName] {
                // Variable found in environment, replace with its value
                resolvedValue.replaceSubrange(Range(match.range(at: 0), in: resolvedValue)!, with: envValue)
            } else if let defaultValueRange = Range(match.range(at: 3), in: resolvedValue) {
                // Variable not found, but default value is provided, replace with default
                let defaultValue = String(resolvedValue[defaultValueRange])
                resolvedValue.replaceSubrange(Range(match.range(at: 0), in: resolvedValue)!, with: defaultValue)
            } else if match.range(at: 5).location != NSNotFound, let errorMessageRange = Range(match.range(at: 5), in: resolvedValue) {
                // Variable not found, and error-on-missing syntax used, print error and exit
                let errorMessage = String(resolvedValue[errorMessageRange])
                fputs("Error: Missing required environment variable '\(varName)': \(errorMessage)\n", stderr)
                Application.exit(withError: "Error: Missing required environment variable '\(varName)': \(errorMessage)\n")
            } else {
                // Variable not found and no default/error specified, leave as is and break loop to avoid infinite loop
                break
            }
        }
        return resolvedValue
    }
//}

extension String: @retroactive Error {}

/// A structure representing the result of a command-line process execution.
struct CommandResult {
    /// The standard output captured from the process.
    let stdout: String

    /// The standard error output captured from the process.
    let stderr: String

    /// The exit code returned by the process upon termination.
    let exitCode: Int32
}

extension NamedColor: Codable {

}
