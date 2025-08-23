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
import ContainerizationError
import Logging

/// Converts a ComposeFile to a normalized Project structure
public struct ProjectConverter {
    private let log: Logger
    
    public init(log: Logger) {
        self.log = log
    }
    
    /// Convert a ComposeFile to a Project
    public func convert(
        composeFile: ComposeFile,
        projectName: String,
        profiles: [String] = [],
        selectedServices: [String] = []
    ) throws -> Project {
        // First, resolve service inheritance
        let resolvedServices = try resolveServiceInheritance(composeFile.services)
        
        // Filter services by profiles
        let profileFilteredServices = filterServicesByProfiles(resolvedServices, profiles: profiles)
        
        // Filter by selected services if specified
        let filteredServices = filterSelectedServices(profileFilteredServices, selected: selectedServices)
        
        // Convert services
        var services: [String: Service] = [:]
        for (name, composeService) in filteredServices {
            services[name] = try convertService(name: name, service: composeService, projectName: projectName)
        }
        
        // Convert networks
        var networks: [String: Network] = [:]
        if let composeNetworks = composeFile.networks {
            for (name, composeNetwork) in composeNetworks {
                networks[name] = convertNetwork(name: name, network: composeNetwork)
            }
        }
        
        // Add default network if no networks specified
        if networks.isEmpty {
            networks["default"] = Network(name: "default", driver: "bridge", external: false)
        }
        
        // Convert volumes
        var volumes: [String: Volume] = [:]
        if let composeVolumes = composeFile.volumes {
            for (name, composeVolume) in composeVolumes {
                volumes[name] = convertVolume(name: name, volume: composeVolume)
            }
        }
        
        return Project(
            name: projectName,
            services: services,
            networks: networks,
            volumes: volumes
        )
    }
    
    // MARK: - Service Inheritance Resolution
    
    private func resolveServiceInheritance(_ services: [String: ComposeService]) throws -> [String: ComposeService] {
        var resolved: [String: ComposeService] = [:]
        var resolving: Set<String> = []
        
        func resolve(name: String, service: ComposeService) throws -> ComposeService {
            // Check for circular dependencies
            if resolving.contains(name) {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Circular service inheritance detected involving '\(name)'"
                )
            }
            
            // If already resolved, return it
            if let resolvedService = resolved[name] {
                return resolvedService
            }
            
            // If no extends, return as is
            guard let extends = service.extends else {
                resolved[name] = service
                return service
            }
            
            // Mark as currently resolving
            resolving.insert(name)
            defer { resolving.remove(name) }
            
            // Get base service
            guard let baseService = services[extends.service] else {
                throw ContainerizationError(
                    .notFound,
                    message: "Service '\(name)' extends unknown service '\(extends.service)'"
                )
            }
            
            // Resolve base service first
            let resolvedBase = try resolve(name: extends.service, service: baseService)
            
            // Merge services
            let merged = try mergeServices(base: resolvedBase, override: service)
            resolved[name] = merged
            
            return merged
        }
        
        // Resolve all services
        for (name, service) in services {
            _ = try resolve(name: name, service: service)
        }
        
        return resolved
    }
    
    private func mergeServices(base: ComposeService, override: ComposeService) throws -> ComposeService {
        // For scalar values, override wins
        // For arrays, concatenate base + override
        // For dictionaries, merge with override winning
        
        return ComposeService(
            image: override.image ?? base.image,
            build: override.build ?? base.build,
            command: override.command ?? base.command,
            entrypoint: override.entrypoint ?? base.entrypoint,
            workingDir: override.workingDir ?? base.workingDir,
            environment: mergeEnvironment(base: base.environment, override: override.environment),
            envFile: mergeStringOrList(base: base.envFile, override: override.envFile),
            volumes: mergeArrays(base: base.volumes, override: override.volumes),
            ports: mergeArrays(base: base.ports, override: override.ports),
            networks: override.networks ?? base.networks,
            dependsOn: override.dependsOn ?? base.dependsOn,
            deploy: override.deploy ?? base.deploy,
            memLimit: override.memLimit ?? base.memLimit,
            cpus: override.cpus ?? base.cpus,
            containerName: override.containerName ?? base.containerName,
            healthcheck: override.healthcheck ?? base.healthcheck,
            profiles: mergeArrays(base: base.profiles, override: override.profiles),
            extends: nil, // Don't inherit extends
            restart: override.restart ?? base.restart,
            labels: mergeLabels(base: base.labels, override: override.labels)
        )
    }
    
    private func mergeEnvironment(base: Environment?, override: Environment?) -> Environment? {
        guard let base = base else { return override }
        guard let override = override else { return base }
        
        let baseDict = base.asDictionary
        var mergedDict = baseDict
        
        for (key, value) in override.asDictionary {
            mergedDict[key] = value
        }
        
        return .dict(mergedDict)
    }
    
    private func mergeStringOrList(base: StringOrList?, override: StringOrList?) -> StringOrList? {
        guard let base = base else { return override }
        guard let override = override else { return base }
        
        return .list(base.asArray + override.asArray)
    }
    
    private func mergeArrays<T>(base: [T]?, override: [T]?) -> [T]? {
        guard let base = base else { return override }
        guard let override = override else { return base }
        
        return base + override
    }
    
    private func mergeLabels(base: Labels?, override: Labels?) -> Labels? {
        guard let base = base else { return override }
        guard let override = override else { return base }
        
        switch (base, override) {
        case (.dict(let baseDict), .dict(let overrideDict)):
            var merged = baseDict
            for (key, value) in overrideDict {
                merged[key] = value
            }
            return .dict(merged)
        case (.list(let baseList), .list(let overrideList)):
            return .list(baseList + overrideList)
        default:
            // If types don't match, override wins
            return override
        }
    }
    
    // MARK: - Profile Filtering
    
    private func filterServicesByProfiles(
        _ services: [String: ComposeService],
        profiles: [String]
    ) -> [String: ComposeService] {
        if profiles.isEmpty {
            // No profiles specified, include only services without profiles
            return services.filter { $0.value.profiles == nil || $0.value.profiles!.isEmpty }
        }
        
        // Include services that have no profiles OR match any of the specified profiles
        return services.filter { (_, service) in
            if let serviceProfiles = service.profiles, !serviceProfiles.isEmpty {
                // Service has profiles, check if any match
                return !Set(serviceProfiles).isDisjoint(with: Set(profiles))
            }
            // Service has no profiles, always include
            return true
        }
    }
    
    // MARK: - Service Selection
    
    private func filterSelectedServices(
        _ services: [String: ComposeService],
        selected: [String]
    ) -> [String: ComposeService] {
        if selected.isEmpty {
            return services
        }
        
        var result: [String: ComposeService] = [:]
        var toProcess = Set(selected)
        var processed = Set<String>()
        
        // Recursively include dependencies
        while !toProcess.isEmpty {
            let current = toProcess.removeFirst()
            if processed.contains(current) {
                continue
            }
            processed.insert(current)
            
            guard let service = services[current] else {
                log.warning("Selected service '\(current)' not found")
                continue
            }
            
            result[current] = service
            
            // Add dependencies
            if let deps = service.dependsOn {
                for dep in deps.asList {
                    toProcess.insert(dep)
                }
            }
        }
        
        return result
    }
    
    // MARK: - Service Conversion
    
    private func convertService(name: String, service: ComposeService, projectName: String) throws -> Service {
        // Parse ports
        let ports = try (service.ports ?? []).compactMap { portString -> PortMapping? in
            guard let mapping = PortMapping(from: portString) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Invalid port mapping '\(portString)' in service '\(name)'"
                )
            }
            return mapping
        }
        
        // Parse volumes
        let volumes = (service.volumes ?? []).compactMap { volumeString -> VolumeMount? in
            guard let mount = VolumeMount(from: volumeString) else {
                log.warning("Invalid volume mount '\(volumeString)' in service '\(name)'")
                return nil
            }
            
            // Convert relative paths to absolute
            var finalMount = mount
            if mount.type == .bind && !mount.source.hasPrefix("/") {
                let currentDir = FileManager.default.currentDirectoryPath
                let absolutePath = URL(fileURLWithPath: currentDir)
                    .appendingPathComponent(mount.source)
                    .standardized
                    .path
                finalMount = VolumeMount(
                    source: absolutePath,
                    target: mount.target,
                    readOnly: mount.readOnly,
                    type: mount.type
                )
            }
            
            return finalMount
        }
        
        // Load env_file entries and merge into environment
        var environment = [String: String]()
        if let envFile = service.envFile {
            for path in envFile.asArray {
                let url: URL
                if path.hasPrefix("/") {
                    url = URL(fileURLWithPath: path)
                } else {
                    let cwd = FileManager.default.currentDirectoryPath
                    url = URL(fileURLWithPath: cwd).appendingPathComponent(path)
                }
                if let fileEnv = try? loadEnvFile(url: url) {
                    // later files override earlier ones
                    for (k, v) in fileEnv { environment[k] = v }
                } else {
                    log.warning("env_file not found or unreadable: \(path)")
                }
            }
        }
        // Service-level environment overrides env_file
        for (k, v) in (service.environment?.asDictionary ?? [:]) { environment[k] = v }
        
        // Get networks
        let networks: [String] = {
            switch service.networks {
            case .list(let list):
                return list
            case .dict(let dict):
                return Array(dict.keys)
            case nil:
                return ["default"]
            }
        }()
        
        // Get dependencies and conditions
        let dependsOn = service.dependsOn?.asList ?? []
        var dependsOnHealthy: [String] = []
        var dependsOnStarted: [String] = []
        var dependsOnCompleted: [String] = []
        if case .dict(let dict) = service.dependsOn {
            for (name, cfg) in dict {
                switch cfg.condition?.lowercased() {
                case "service_healthy": dependsOnHealthy.append(name)
                case "service_started": dependsOnStarted.append(name)
                case "service_completed_successfully": dependsOnCompleted.append(name)
                default: break
                }
            }
        }
        
        // Convert health check
        let healthCheck: HealthCheck? = {
            guard let hc = service.healthcheck, !(hc.disable ?? false) else { return nil }
            
            // Build the test command according to Compose spec
            var testCommand: [String] = []
            if let test = hc.test {
                switch test {
                case .list(let arr):
                    testCommand = arr
                case .string(let s):
                    // String form is equivalent to CMD-SHELL
                    testCommand = ["/bin/sh", "-c", s]
                }
            }
            
            // Handle special tokens
            if !testCommand.isEmpty {
                if testCommand[0] == "NONE" {
                    // NONE means no health check
                    return nil
                } else if testCommand[0] == "CMD-SHELL" && testCommand.count > 1 {
                    // Convert CMD-SHELL to shell invocation
                    let shellCommand = testCommand[1...].joined(separator: " ")
                    testCommand = ["/bin/sh", "-c", shellCommand]
                }
            }
            
            return HealthCheck(
                test: testCommand,
                interval: parseTimeInterval(hc.interval),
                timeout: parseTimeInterval(hc.timeout),
                retries: hc.retries,
                startPeriod: parseTimeInterval(hc.startPeriod)
            )
        }()
        
        // Get resource limits
        let cpus = service.cpus ?? service.deploy?.resources?.limits?.cpus
        let memory = service.memLimit ?? service.deploy?.resources?.limits?.memory
        
        // Container name
        let containerName = service.containerName ?? "\(projectName)_\(name)"
        
        return Service(
            name: name,
            image: service.image,
            build: service.build,
            command: service.command?.asArray,
            entrypoint: service.entrypoint?.asArray,
            workingDir: service.workingDir,
            environment: environment,
            ports: ports,
            volumes: volumes,
            networks: networks,
            dependsOn: dependsOn,
            dependsOnHealthy: dependsOnHealthy,
            dependsOnStarted: dependsOnStarted,
            dependsOnCompletedSuccessfully: dependsOnCompleted,
            healthCheck: healthCheck,
            deploy: convertDeploy(service.deploy),
            restart: service.restart,
            containerName: containerName,
            profiles: service.profiles ?? [],
            labels: convertLabels(service.labels),
            cpus: cpus,
            memory: memory
        )
    }
    
    // MARK: - Helper Conversions
    
    private func convertNetwork(name: String, network: ComposeNetwork) -> Network {
        let external: Bool = {
            switch network.external {
            case .bool(let value):
                return value
            case .config(_):
                return true
            case nil:
                return false
            }
        }()
        
        return Network(
            name: name,
            driver: network.driver ?? "bridge",
            external: external
        )
    }
    
    private func convertVolume(name: String, volume: ComposeVolume) -> Volume {
        let external: Bool = {
            switch volume.external {
            case .bool(let value):
                return value
            case .config(_):
                return true
            case nil:
                return false
            }
        }()
        
        return Volume(
            name: name,
            driver: volume.driver ?? "local",
            external: external
        )
    }
    
    private func convertDeploy(_ composeDeploy: DeployConfig?) -> Deploy? {
        guard let composeDeploy = composeDeploy else { return nil }
        
        let resources: ServiceResources? = {
            guard let composeResources = composeDeploy.resources else { return nil }
            
            let limits = composeResources.limits.map { limits in
                ServiceResourceConfig(
                    cpus: limits.cpus,
                    memory: limits.memory
                )
            }
            
            let reservations = composeResources.reservations.map { reservations in
                ServiceResourceConfig(
                    cpus: reservations.cpus,
                    memory: reservations.memory
                )
            }
            
            return ServiceResources(
                limits: limits,
                reservations: reservations
            )
        }()
        
        return Deploy(resources: resources)
    }
    
    private func convertLabels(_ labels: Labels?) -> [String: String] {
        guard let labels = labels else { return [:] }
        
        switch labels {
        case .dict(let dict):
            return dict
        case .list(let list):
            var dict: [String: String] = [:]
            for item in list {
                let parts = item.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    dict[String(parts[0])] = String(parts[1])
                }
            }
            return dict
        }
    }
    
    private func parseTimeInterval(_ string: String?) -> TimeInterval? {
        guard let string = string else { return nil }
        
        // Parse duration strings like "30s", "5m", "1h"
        let pattern = #"^(\d+)([smh])$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let valueRange = Range(match.range(at: 1), in: string),
              let unitRange = Range(match.range(at: 2), in: string),
              let value = Double(string[valueRange]) else {
            return nil
        }
        
        let unit = String(string[unitRange])
        switch unit {
        case "s":
            return value
        case "m":
            return value * 60
        case "h":
            return value * 3600
        default:
            return nil
        }
    }

    private func loadEnvFile(url: URL) throws -> [String: String] {
        // Validate file path to prevent directory traversal
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.pathComponents.contains("..") == false else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Invalid env file path: \(url.path) (directory traversal not allowed)"
            )
        }

        // Check file permissions and ownership
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            throw ContainerizationError(
                .notFound,
                message: "Cannot read env file: \(url.path)"
            )
        }

        // Check if file is readable only by owner (security best practice)
        if let posixPermissions = attributes[.posixPermissions] as? UInt16 {
            let permissions = posixPermissions & 0o777
            if permissions & 0o044 != 0 { // Group or other can read
                log.warning("Env file \(url.path) is readable by group/other. Consider restricting permissions to 600")
            }
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: String] = [:]

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }

            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var val = String(parts[1]).trimmingCharacters(in: .whitespaces)

            // Validate environment variable name (alphanumeric + underscore, no leading digit)
            guard !key.isEmpty && key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                log.warning("Skipping invalid environment variable name: '\(key)'")
                continue
            }

            // Remove quotes if present
            if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }

            // Expand any nested variable references (basic support)
            val = expandVariables(in: val, existingVars: out)

            out[key] = val
        }

        return out
    }

    private func expandVariables(in value: String, existingVars: [String: String]) -> String {
        var result = value

        // Simple variable expansion for ${VAR} and $VAR
        let patterns = [
            #"\$\{([^}]+)\}"#,  // ${VAR}
            #"\$([A-Za-z_][A-Za-z0-9_]*)"#,  // $VAR
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let varRange = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: result) else { continue }
                let varName = String(result[varRange])

                // Get value from existing variables or environment
                if let existingValue = existingVars[varName] {
                    result.replaceSubrange(Range(match.range, in: result)!, with: existingValue)
                } else if let envValue = getenv(varName).flatMap({ String(cString: $0) }) {
                    result.replaceSubrange(Range(match.range, in: result)!, with: envValue)
                }
            }
        }

        return result
    }
}
