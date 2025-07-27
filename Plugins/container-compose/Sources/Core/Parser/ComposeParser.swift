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
import Yams
import ContainerizationError
import Logging

public struct ComposeParser {
    private let log: Logger
    private let merger: ComposeFileMerger
    private let allowAnchors: Bool
    
    public init(log: Logger, allowAnchors: Bool = false) {
        self.log = log
        self.merger = ComposeFileMerger(log: log)
        self.allowAnchors = allowAnchors
    }
    
    /// Parse and merge multiple docker-compose files
    public func parse(from urls: [URL]) throws -> ComposeFile {
        guard !urls.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "No compose files specified"
            )
        }

        var composeFiles: [ComposeFile] = []

        for url in urls {
            // Load .env for each file directory (Compose precedence: shell env overrides .env)
            _ = EnvLoader.load(from: url.deletingLastPathComponent(), export: true, override: false, logger: log)
            let file = try parseWithoutValidation(from: url)
            composeFiles.append(file)
            log.info("Loaded compose file: \(url.lastPathComponent)")
        }
        
        // Merge all files
        let merged = merger.merge(composeFiles)
        
        if urls.count > 1 {
            log.info("Merged \(urls.count) compose files")
        }
        
        // Validate only the final merged result
        try validate(merged)
        
        return merged
    }
    
    /// Parse a single docker-compose.yaml file from the given URL
    public func parse(from url: URL) throws -> ComposeFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContainerizationError(
                .notFound,
                message: "Compose file not found at path: \(url.path)"
            )
        }

        // Load .env from the compose file directory for interpolation if present
        _ = EnvLoader.load(from: url.deletingLastPathComponent(), export: true, override: false, logger: log)

        let data = try Data(contentsOf: url)
        return try parse(from: data)
    }
    
    /// Parse compose file from data without validation (for internal use)
    private func parseWithoutValidation(from url: URL) throws -> ComposeFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContainerizationError(
                .notFound,
                message: "Compose file not found at path: \(url.path)"
            )
        }
        
        let data = try Data(contentsOf: url)
        return try parseWithoutValidation(from: data)
    }
    
    /// Parse compose file from data without validation
    private func parseWithoutValidation(from data: Data) throws -> ComposeFile {
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Unable to decode compose file as UTF-8"
            )
        }
        
        do {
            // Decode directly without intermediate dump/reload
            let decoder = YAMLDecoder()
            
            // First try to decode directly (no interpolation needed)
            if !yamlString.contains("$") {
                return try decoder.decode(ComposeFile.self, from: data)
            }
            
            // If we have variables to interpolate, we need to process the YAML
            // But let's do it more intelligently by working with the string directly
            let interpolatedYaml = try interpolateYamlString(yamlString)
            let interpolatedData = interpolatedYaml.data(using: .utf8)!
            
            return try decoder.decode(ComposeFile.self, from: interpolatedData)
        } catch let error as DecodingError {
            throw ContainerizationError(
                .invalidArgument,
                message: "Failed to parse compose file: \(describeDecodingError(error))"
            )
        } catch {
            throw error
        }
    }
    
    /// Parse compose file from data
    public func parse(from data: Data) throws -> ComposeFile {
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Unable to decode compose file as UTF-8"
            )
        }

        // Security: Check for potentially malicious YAML content
        try validateYamlContent(yamlString)

        do {
            // Decode directly without intermediate dump/reload
            let decoder = YAMLDecoder()

            // First try to decode directly (no interpolation needed)
            if !yamlString.contains("$") {
                let composeFile = try decoder.decode(ComposeFile.self, from: data)
                try validateEnvironmentKeysPreflight(composeFile)
                try validate(composeFile)
                return composeFile
            }

            // If we have variables to interpolate, we need to process the YAML
            // But let's do it more intelligently by working with the string directly
            let interpolatedYaml = try interpolateYamlString(yamlString)
            let interpolatedData = interpolatedYaml.data(using: .utf8)!

            let composeFile = try decoder.decode(ComposeFile.self, from: interpolatedData)
            try validateEnvironmentKeysPreflight(composeFile)
            try validate(composeFile)

            return composeFile
        } catch let error as DecodingError {
            throw ContainerizationError(
                .invalidArgument,
                message: "Failed to parse compose file: \(describeDecodingError(error))"
            )
        } catch {
            throw error
        }
    }

    /// Additional safeguard to validate environment keys after decoding
    private func validateEnvironmentKeysPreflight(_ composeFile: ComposeFile) throws {
        for (name, svc) in composeFile.services {
            if let env = svc.environment {
                switch env {
                case .dict(let dict):
                    for (k, _) in dict { try checkEnvName(k, service: name) }
                case .list(let list):
                    for item in list {
                        let key = String(item.split(separator: "=", maxSplits: 1).first ?? "")
                        if !key.isEmpty { try checkEnvName(key, service: name) }
                    }
                }
            }
        }
    }

    private func checkEnvName(_ key: String, service: String) throws {
        let valid = isValidSimpleEnvName(key)
        if !valid {
            throw ContainerizationError(
                .invalidArgument,
                message: "Invalid environment variable name: '\(key)' in service '\(service)'"
            )
        }
    }
    
    private func isValidSimpleEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func isAlphaOrUnderscore(_ s: Unicode.Scalar) -> Bool {
            return ("A"..."Z").contains(s) || ("a"..."z").contains(s) || s == "_"
        }
        func isAlnumOrUnderscore(_ s: Unicode.Scalar) -> Bool {
            return isAlphaOrUnderscore(s) || ("0"..."9").contains(s)
        }
        guard isAlphaOrUnderscore(first) else { return false }
        for s in name.unicodeScalars.dropFirst() {
            if !isAlnumOrUnderscore(s) { return false }
        }
        return true
    }

    /// Validate YAML content for security issues
    private func validateYamlContent(_ yamlString: String) throws {
        // Check for potentially dangerous YAML constructs using universal patterns
        // Look for any !!tag/ patterns that could be dangerous
        let tagPattern = "!![a-zA-Z][a-zA-Z0-9._-]*"
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            let matches = regex.matches(in: yamlString, range: NSRange(yamlString.startIndex..., in: yamlString))
            for match in matches {
                if let range = Range(match.range, in: yamlString) {
                    let tag = String(yamlString[range])
                    // Allow safe built-in YAML tags
                    let safeTags = ["!!str", "!!int", "!!float", "!!bool", "!!null", "!!seq", "!!map", "!!binary", "!!timestamp"]
                    if !safeTags.contains(tag) {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "Potentially unsafe YAML tag detected: \(tag)"
                        )
                    }
                }
            }
        }

        // Check for YAML anchors and merge keys that can cause DoS
        if !allowAnchors {
            if yamlString.contains("&") || yamlString.contains("<<:") {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "YAML anchors and merge keys are not allowed for security reasons (use --allow-anchors to override)"
                )
            }
        }

        // Check file size limit (prevent DoS with extremely large files)
        let maxSize = 9_000_000 // ~9MB limit to catch ~10,000,000 byte strings
        if yamlString.utf8.count > maxSize {
            throw ContainerizationError(
                .invalidArgument,
                message: "Compose file too large (max \(maxSize) bytes)"
            )
        }

        // Check for excessive nesting depth (prevent stack overflow)
        let maxDepth = 20
        var maxFoundDepth = 0
        var currentDepth = 0

        for char in yamlString {
            if char == " " {
                currentDepth += 1
                maxFoundDepth = max(maxFoundDepth, currentDepth)
            } else if char != "\n" && char != "\r" {
                currentDepth = 0
            }

            if maxFoundDepth > maxDepth * 2 { // 2 spaces per indentation level
                throw ContainerizationError(
                    .invalidArgument,
                    message: "YAML nesting depth too deep (max \(maxDepth) levels)"
                )
            }
        }

        // Environment-variable name validation is enforced during decoding and preflight
        // to avoid false positives from textual scanning. Text scanning is disabled here.
    }
    
    /// Validate the compose file structure
    private func validate(_ composeFile: ComposeFile) throws {
        // Check version compatibility
        if let version = composeFile.version {
            let supportedVersions = ["2", "2.0", "2.1", "2.2", "2.3", "2.4", 
                                   "3", "3.0", "3.1", "3.2", "3.3", "3.4", "3.5", "3.6", "3.7", "3.8", "3.9"]
            let majorVersion = version.split(separator: ".").first.map(String.init) ?? version
            
            if !supportedVersions.contains(version) && !supportedVersions.contains(majorVersion) {
                log.warning("Compose file version '\(version)' may not be fully supported")
            }
        }
        
        // Validate services
        guard !composeFile.services.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "No services defined in compose file"
            )
        }
        
        for (name, service) in composeFile.services {
            try validateService(name: name, service: service)
        }
        
        // Validate circular dependencies
        try validateDependencies(composeFile)
    }
    
    /// Validate individual service configuration
    private func validateService(name: String, service: ComposeService) throws {
        // Either image or build must be specified
        if service.image == nil && service.build == nil {
            throw ContainerizationError(
                .invalidArgument,
                message: "Service '\(name)' must specify either 'image' or 'build'"
            )
        }
        
        // Validate extends configuration
        if let extends = service.extends {
            if extends.service.isEmpty {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Service '\(name)' extends configuration must specify a service"
                )
            }
        }
        
        // Validate port mappings
        if let ports = service.ports {
            for port in ports {
                if !isValidPortMapping(port) {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "Invalid port mapping '\(port)' in service '\(name)'"
                    )
                }
            }
        }
        
        // Validate environment variable key names when provided as dict/list entries
        if let env = service.environment {
            func isValidName(_ name: String) -> Bool {
                let pattern = "^[A-Za-z_][A-Za-z0-9_]*$"
                let regex = try! NSRegularExpression(pattern: pattern)
                let range = NSRange(name.startIndex..., in: name)
                return regex.firstMatch(in: name, range: range) != nil
            }
            switch env {
            case .dict(let dict):
                for (k, _) in dict {
                    if !isValidName(k) {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "Invalid environment variable name: '\(k)'"
                        )
                    }
                }
            case .list(let list):
                for item in list {
                    let parts = item.split(separator: "=", maxSplits: 1)
                    if !parts.isEmpty {
                        let key = String(parts[0])
                        if !isValidName(key) {
                            throw ContainerizationError(
                                .invalidArgument,
                                message: "Invalid environment variable name: '\(key)'"
                            )
                        }
                    }
                }
            }
        }
        
        // Validate volume mounts (short-form only)
        if let volumes = service.volumes {
            for v in volumes {
                switch v {
                case .string(let s):
                    if !isValidVolumeMount(s) {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "Invalid volume mount '\(s)' in service '\(name)'"
                        )
                    }
                case .object:
                    continue
                }
            }
        }
    }
    
    /// Validate dependencies don't have circular references
    private func validateDependencies(_ composeFile: ComposeFile) throws {
        var visited = Set<String>()
        var recursionStack = Set<String>()
        
        func hasCycle(service: String) -> Bool {
            if recursionStack.contains(service) {
                return true
            }
            if visited.contains(service) {
                return false
            }
            
            visited.insert(service)
            recursionStack.insert(service)
            
            if let serviceConfig = composeFile.services[service],
               let dependsOn = serviceConfig.dependsOn {
                for dependency in dependsOn.asList {
                    if hasCycle(service: dependency) {
                        return true
                    }
                }
            }
            
            recursionStack.remove(service)
            return false
        }
        
        for serviceName in composeFile.services.keys {
            if hasCycle(service: serviceName) {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Circular dependency detected involving service '\(serviceName)'"
                )
            }
        }
    }
    
    /// Check if port mapping is valid
    private func isValidPortMapping(_ port: String) -> Bool {
        // Accept formats:
        // - "8080:80"
        // - "8080:80/tcp"
        // - "127.0.0.1:8080:80"
        // - "127.0.0.1:8080:80/tcp"
        let components = port.split(separator: ":")
        return components.count >= 2 && components.count <= 3
    }
    
    /// Check if volume mount is valid
    private func isValidVolumeMount(_ volume: String) -> Bool {
        // Accept formats:
        // - "container_path" (anonymous volume)
        // - "host_path:container_path"
        // - "host_path:container_path:option" where option in [ro,rw,z,Z,cached,delegated]
        // - "volume_name:container_path[:option]"
        let components = volume.split(separator: ":")
        if components.count == 1 {
            return components[0].hasPrefix("/") // must be an absolute container path
        }
        if components.count < 2 || components.count > 3 {
            return false
        }
        if components.count == 3 {
            let validOptions = ["ro", "rw", "z", "Z", "cached", "delegated"]
            return validOptions.contains(String(components[2]))
        }
        return true
    }
    
    /// Interpolate environment variables directly in YAML string
    private func interpolateYamlString(_ yaml: String) throws -> String {
        var result = yaml

        // Pattern for ${VAR} or ${VAR:-default}
        let pattern = #"\$\{([^}]+)\}"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: yaml, range: NSRange(yaml.startIndex..., in: yaml))

        // Process matches in reverse order to maintain correct positions
        for match in matches.reversed() {
            guard let range = Range(match.range, in: yaml),
                  let varRange = Range(match.range(at: 1), in: yaml)
            else {
                continue
            }

            let varExpression = String(yaml[varRange])
            let (varName, defaultValue) = parseVarExpression(varExpression)

            // Validate variable name to prevent injection
            guard isValidEnvironmentVariableName(varName) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Invalid environment variable name: '\(varName)'"
                )
            }

            let value = getenv(varName).flatMap { String(cString: $0) } ?? defaultValue ?? ""
            result.replaceSubrange(range, with: value)
        }

        // Also handle $VAR format
        let simplePattern = #"\$([A-Za-z_][A-Za-z0-9_]*)"#  // Fixed: was missing closing parenthesis
        let simpleRegex = try NSRegularExpression(pattern: simplePattern)
        let simpleMatches = simpleRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        for match in simpleMatches.reversed() {
            guard let range = Range(match.range, in: result),
                  let varRange = Range(match.range(at: 1), in: result)
            else {
                continue
            }

            let varName = String(result[varRange])

            // Validate variable name to prevent injection
            guard isValidEnvironmentVariableName(varName) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Invalid environment variable name: '\(varName)'"
                )
            }

            if let cstr = getenv(varName) {
                result.replaceSubrange(range, with: String(cString: cstr))
            }
        }

        return result
    }

    /// Validate environment variable name to prevent injection attacks
    private func isValidEnvironmentVariableName(_ name: String) -> Bool {
        return isValidSimpleEnvName(name)
    }
    
    
    /// Parse variable expression like "VAR:-default"
    private func parseVarExpression(_ expression: String) -> (name: String, defaultValue: String?) {
        if let colonDashIndex = expression.firstIndex(of: ":") {
            let name = String(expression[..<colonDashIndex])
            let afterColon = expression.index(after: colonDashIndex)
            if afterColon < expression.endIndex && expression[afterColon] == "-" {
                let defaultStart = expression.index(after: afterColon)
                let defaultValue = String(expression[defaultStart...])
                return (name, defaultValue)
            }
            return (name, nil)
        }
        return (expression, nil)
    }
    
    
    /// Describe decoding error in a user-friendly way
    private func describeDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let context):
            return "Type mismatch at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "Missing value at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "Unknown key '\(key.stringValue)' at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .dataCorrupted(let context):
            return "Invalid data at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
        @unknown default:
            return "Unknown parsing error: \(error)"
        }
    }
}
