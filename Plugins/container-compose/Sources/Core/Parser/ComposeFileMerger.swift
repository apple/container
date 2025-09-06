//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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

/// Merges multiple compose files according to Docker Compose merge rules
public struct ComposeFileMerger {
    private let log: Logger
    
    public init(log: Logger) {
        self.log = log
    }
    
    /// Merge multiple compose files, with later files overriding earlier ones
    public func merge(_ files: [ComposeFile]) -> ComposeFile {
        guard !files.isEmpty else {
            return ComposeFile()
        }
        
        guard files.count > 1 else {
            return files[0]
        }
        
        var result = files[0]
        
        for i in 1..<files.count {
            result = mergeTwoFiles(base: result, override: files[i])
        }
        
        return result
    }
    
    /// Merge two compose files
    private func mergeTwoFiles(base: ComposeFile, override: ComposeFile) -> ComposeFile {
        // Version: use override if present, otherwise base
        let version = override.version ?? base.version
        
        // Services: merge with override winning
        let services = mergeServices(base: base.services, override: override.services)
        
        // Networks: merge with override winning
        let networks = mergeNetworks(base: base.networks, override: override.networks)
        
        // Volumes: merge with override winning
        let volumes = mergeVolumes(base: base.volumes, override: override.volumes)
        
        return ComposeFile(
            version: version,
            services: services,
            networks: networks,
            volumes: volumes
        )
    }
    
    // MARK: - Service Merging
    
    private func mergeServices(base: [String: ComposeService], override: [String: ComposeService]) -> [String: ComposeService] {
        var merged = base
        
        for (name, overrideService) in override {
            if let baseService = base[name] {
                // Merge existing service
                merged[name] = mergeService(base: baseService, override: overrideService)
            } else {
                // Add new service
                merged[name] = overrideService
            }
        }
        
        return merged
    }
    
    private func mergeService(base: ComposeService, override: ComposeService) -> ComposeService {
        return ComposeService(
            image: override.image ?? base.image,
            build: override.build ?? base.build,
            command: override.command ?? base.command,
            entrypoint: override.entrypoint ?? base.entrypoint,
            workingDir: override.workingDir ?? base.workingDir,
            environment: mergeEnvironment(base: base.environment, override: override.environment),
            envFile: mergeStringOrList(base: base.envFile, override: override.envFile),
            volumes: mergeServiceVolumes(base: base.volumes, override: override.volumes),
            ports: mergeStringArrays(base: base.ports, override: override.ports),
            networks: mergeNetworkConfig(base: base.networks, override: override.networks),
            dependsOn: mergeDependsOn(base: base.dependsOn, override: override.dependsOn),
            deploy: override.deploy ?? base.deploy,
            memLimit: override.memLimit ?? base.memLimit,
            cpus: override.cpus ?? base.cpus,
            containerName: override.containerName ?? base.containerName,
            healthcheck: override.healthcheck ?? base.healthcheck,
            profiles: mergeStringArrays(base: base.profiles, override: override.profiles),
            extends: override.extends ?? base.extends,
            restart: override.restart ?? base.restart,
            labels: mergeLabels(base: base.labels, override: override.labels),
            tty: override.tty ?? base.tty,
            stdinOpen: override.stdinOpen ?? base.stdinOpen
        )
    }
    
    // MARK: - Network Merging
    
    private func mergeNetworks(base: [String: ComposeNetwork]?, override: [String: ComposeNetwork]?) -> [String: ComposeNetwork]? {
        guard let base = base else { return override }
        guard let override = override else { return base }
        
        var merged = base
        for (name, overrideNetwork) in override {
            if let baseNetwork = base[name] {
                // Merge existing network
                merged[name] = mergeNetwork(base: baseNetwork, override: overrideNetwork)
            } else {
                // Add new network
                merged[name] = overrideNetwork
            }
        }
        
        return merged
    }
    
    private func mergeNetwork(base: ComposeNetwork, override: ComposeNetwork) -> ComposeNetwork {
        return ComposeNetwork(
            driver: override.driver ?? base.driver,
            external: override.external ?? base.external,
            name: override.name ?? base.name
        )
    }
    
    // MARK: - Volume Merging
    
    private func mergeVolumes(base: [String: ComposeVolume]?, override: [String: ComposeVolume]?) -> [String: ComposeVolume]? {
        guard let base = base else { return override }
        guard let override = override else { return base }
        
        var merged = base
        for (name, overrideVolume) in override {
            if let baseVolume = base[name] {
                // Merge existing volume
                merged[name] = mergeVolume(base: baseVolume, override: overrideVolume)
            } else {
                // Add new volume
                merged[name] = overrideVolume
            }
        }
        
        return merged
    }
    
    private func mergeVolume(base: ComposeVolume, override: ComposeVolume) -> ComposeVolume {
        return ComposeVolume(
            driver: override.driver ?? base.driver,
            external: override.external ?? base.external,
            name: override.name ?? base.name
        )
    }
    
    // MARK: - Helper Methods
    
    private func mergeEnvironment(base: Environment?, override: Environment?) -> Environment? {
        guard let base = base else { return override }
        guard let override = override else { return base }
        
        // Convert to dictionaries for merging
        var baseDict = base.asDictionary
        let overrideDict = override.asDictionary
        
        // Override wins
        for (key, value) in overrideDict {
            baseDict[key] = value
        }
        
        return .dict(baseDict)
    }
    
    private func mergeStringOrList(base: StringOrList?, override: StringOrList?) -> StringOrList? {
        // For env_file, override completely replaces base (Docker Compose behavior)
        return override ?? base
    }
    
    private func mergeStringArrays(base: [String]?, override: [String]?) -> [String]? {
        // For arrays like ports and volumes, override completely replaces base
        // This matches Docker Compose behavior
        return override ?? base
    }

    private func mergeServiceVolumes(base: [ServiceVolume]?, override: [ServiceVolume]?) -> [ServiceVolume]? {
        // For service volumes, follow compose: override replaces base if specified
        return override ?? base
    }
    
    private func mergeNetworkConfig(base: NetworkConfig?, override: NetworkConfig?) -> NetworkConfig? {
        // Network config override completely replaces base
        return override ?? base
    }
    
    private func mergeDependsOn(base: DependsOn?, override: DependsOn?) -> DependsOn? {
        // depends_on override completely replaces base
        return override ?? base
    }
    
    private func mergeLabels(base: Labels?, override: Labels?) -> Labels? {
        guard let base = base else { return override }
        guard let override = override else { return base }
        
        // Convert to dictionaries for merging
        var baseDict = base.asDictionary
        let overrideDict = override.asDictionary
        
        // Override wins
        for (key, value) in overrideDict {
            baseDict[key] = value
        }
        
        return .dict(baseDict)
    }
}
