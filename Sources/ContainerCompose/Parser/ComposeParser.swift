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
    
    public init(log: Logger) {
        self.log = log
    }
    
    /// Parse a docker-compose.yaml file from the given URL
    public func parse(from url: URL) throws -> ComposeFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContainerizationError(
                .notFound,
                message: "Compose file not found at path: \(url.path)"
            )
        }
        
        let data = try Data(contentsOf: url)
        return try parse(from: data)
    }
    
    /// Parse compose file from data
    public func parse(from data: Data) throws -> ComposeFile {
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
                let composeFile = try decoder.decode(ComposeFile.self, from: data)
                try validate(composeFile)
                return composeFile
            }
            
            // If we have variables to interpolate, we need to process the YAML
            // But let's do it more intelligently by working with the string directly
            let interpolatedYaml = try interpolateYamlString(yamlString)
            let interpolatedData = interpolatedYaml.data(using: .utf8)!
            
            let composeFile = try decoder.decode(ComposeFile.self, from: interpolatedData)
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
        
        // Validate volume mounts
        if let volumes = service.volumes {
            for volume in volumes {
                if !isValidVolumeMount(volume) {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "Invalid volume mount '\(volume)' in service '\(name)'"
                    )
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
        // - "host_path:container_path"
        // - "host_path:container_path:ro"
        // - "volume_name:container_path"
        // - "volume_name:container_path:ro"
        let components = volume.split(separator: ":")
        if components.count < 2 || components.count > 3 {
            return false
        }
        
        // If there's a third component, it should be a valid mount option
        if components.count == 3 {
            let validOptions = ["ro", "rw", "z", "Z"]
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
                  let varRange = Range(match.range(at: 1), in: yaml) else {
                continue
            }
            
            let varExpression = String(yaml[varRange])
            let (varName, defaultValue) = parseVarExpression(varExpression)
            
            let value = ProcessInfo.processInfo.environment[varName] ?? defaultValue ?? ""
            result.replaceSubrange(range, with: value)
        }
        
        // Also handle $VAR format
        let simplePattern = #"\$([A-Za-z_][A-Za-z0-9_]*)"#
        let simpleRegex = try NSRegularExpression(pattern: simplePattern)
        let simpleMatches = simpleRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in simpleMatches.reversed() {
            guard let range = Range(match.range, in: result),
                  let varRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            
            let varName = String(result[varRange])
            if let value = ProcessInfo.processInfo.environment[varName] {
                result.replaceSubrange(range, with: value)
            }
        }
        
        return result
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