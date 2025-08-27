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
//  Service.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation


/// Represents a single service definition within the `services` section.
struct Service: Codable, Hashable {
    /// Docker image name
    let image: String?

    /// Build configuration if the service is built from a Dockerfile
    let build: Build?

    /// Deployment configuration (primarily for Swarm)
    let deploy: Deploy?

    /// Restart policy (e.g., 'unless-stopped', 'always')
    let restart: String?

    /// Healthcheck configuration
    let healthcheck: Healthcheck?

    /// List of volume mounts (e.g., "hostPath:containerPath", "namedVolume:/path")
    let volumes: [String]?

    /// Environment variables to set in the container
    let environment: [String: String]?

    /// List of .env files to load environment variables from
    let env_file: [String]?

    /// Port mappings (e.g., "hostPort:containerPort")
    let ports: [String]?

    /// Command to execute in the container, overriding the image's default
    let command: [String]?

    /// Services this service depends on (for startup order)
    let depends_on: [String]?

    /// User or UID to run the container as
    let user: String?

    /// Explicit name for the container instance
    let container_name: String?

    /// List of networks the service will connect to
    let networks: [String]?

    /// Container hostname
    let hostname: String?

    /// Entrypoint to execute in the container, overriding the image's default
    let entrypoint: [String]?

    /// Run container in privileged mode
    let privileged: Bool?

    /// Mount container's root filesystem as read-only
    let read_only: Bool?

    /// Working directory inside the container
    let working_dir: String?

    /// Platform architecture for the service
    let platform: String?

    /// Service-specific config usage (primarily for Swarm)
    let configs: [ServiceConfig]?

    /// Service-specific secret usage (primarily for Swarm)
    let secrets: [ServiceSecret]?

    /// Keep STDIN open (-i flag for `container run`)
    let stdin_open: Bool?

    /// Allocate a pseudo-TTY (-t flag for `container run`)
    let tty: Bool?
    
    /// Other services that depend on this service
    var dependedBy: [String] = []
    
    // Defines custom coding keys to map YAML keys to Swift properties
    enum CodingKeys: String, CodingKey {
        case image, build, deploy, restart, healthcheck, volumes, environment, env_file, ports, command, depends_on, user,
             container_name, networks, hostname, entrypoint, privileged, read_only, working_dir, configs, secrets, stdin_open, tty, platform
    }

    /// Custom initializer to handle decoding and basic validation.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        build = try container.decodeIfPresent(Build.self, forKey: .build)
        deploy = try container.decodeIfPresent(Deploy.self, forKey: .deploy)
        
        // Ensure that a service has either an image or a build context.
        guard image != nil || build != nil else {
            throw DecodingError.dataCorruptedError(forKey: .image, in: container, debugDescription: "Service must have either 'image' or 'build' specified.")
        }

        restart = try container.decodeIfPresent(String.self, forKey: .restart)
        healthcheck = try container.decodeIfPresent(Healthcheck.self, forKey: .healthcheck)
        volumes = try container.decodeIfPresent([String].self, forKey: .volumes)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment)
        env_file = try container.decodeIfPresent([String].self, forKey: .env_file)
        ports = try container.decodeIfPresent([String].self, forKey: .ports)

        // Decode 'command' which can be either a single string or an array of strings.
        if let cmdArray = try? container.decodeIfPresent([String].self, forKey: .command) {
            command = cmdArray
        } else if let cmdString = try? container.decodeIfPresent(String.self, forKey: .command) {
            command = [cmdString]
        } else {
            command = nil
        }
        
        if let dependsOnString = try? container.decodeIfPresent(String.self, forKey: .depends_on) {
            depends_on = [dependsOnString]
        } else {
            depends_on = try container.decodeIfPresent([String].self, forKey: .depends_on)
        }
        user = try container.decodeIfPresent(String.self, forKey: .user)

        container_name = try container.decodeIfPresent(String.self, forKey: .container_name)
        networks = try container.decodeIfPresent([String].self, forKey: .networks)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        
        // Decode 'entrypoint' which can be either a single string or an array of strings.
        if let entrypointArray = try? container.decodeIfPresent([String].self, forKey: .entrypoint) {
            entrypoint = entrypointArray
        } else if let entrypointString = try? container.decodeIfPresent(String.self, forKey: .entrypoint) {
            entrypoint = [entrypointString]
        } else {
            entrypoint = nil
        }

        privileged = try container.decodeIfPresent(Bool.self, forKey: .privileged)
        read_only = try container.decodeIfPresent(Bool.self, forKey: .read_only)
        working_dir = try container.decodeIfPresent(String.self, forKey: .working_dir)
        configs = try container.decodeIfPresent([ServiceConfig].self, forKey: .configs)
        secrets = try container.decodeIfPresent([ServiceSecret].self, forKey: .secrets)
        stdin_open = try container.decodeIfPresent(Bool.self, forKey: .stdin_open)
        tty = try container.decodeIfPresent(Bool.self, forKey: .tty)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
    }
    
    /// Returns the services in topological order based on `depends_on` relationships.
    static func topoSortConfiguredServices(
        _ services: [(serviceName: String, service: Service)]
    ) throws -> [(serviceName: String, service: Service)] {
        
        var visited = Set<String>()
        var visiting = Set<String>()
        var sorted: [(String, Service)] = []

        func visit(_ name: String, from service: String? = nil) throws {
            guard var serviceTuple = services.first(where: { $0.serviceName == name }) else { return }
            if let service {
                serviceTuple.service.dependedBy.append(service)
            }
            
            if visiting.contains(name) {
                throw NSError(domain: "ComposeError", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Cyclic dependency detected involving '\(name)'"
                ])
            }
            guard !visited.contains(name) else { return }

            visiting.insert(name)
            for depName in serviceTuple.service.depends_on ?? [] {
                try visit(depName, from: name)
            }
            visiting.remove(name)
            visited.insert(name)
            sorted.append(serviceTuple)
        }

        for (serviceName, _) in services {
            if !visited.contains(serviceName) {
                try visit(serviceName)
            }
        }

        return sorted
    }
}
