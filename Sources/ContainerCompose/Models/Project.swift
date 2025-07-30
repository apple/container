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

/// Represents a parsed and normalized compose project
public struct Project: Sendable {
    public let name: String
    public let services: [String: Service]
    public let networks: [String: Network]
    public let volumes: [String: Volume]
    
    public init(name: String,
                services: [String: Service] = [:],
                networks: [String: Network] = [:],
                volumes: [String: Volume] = [:]) {
        self.name = name
        self.services = services
        self.networks = networks
        self.volumes = volumes
    }
}

/// Represents a service in the project
public struct Service: Sendable {
    public let name: String
    public let image: String?
    public let command: [String]?
    public let entrypoint: [String]?
    public let workingDir: String?
    public let environment: [String: String]
    public let ports: [PortMapping]
    public let volumes: [VolumeMount]
    public let networks: [String]
    public let dependsOn: [String]
    public let healthCheck: HealthCheck?
    public let deploy: Deploy?
    public let restart: String?
    public let containerName: String?
    public let profiles: [String]
    public let labels: [String: String]
    
    // Resource constraints
    public let cpus: String?
    public let memory: String?
    
    public init(name: String,
                image: String? = nil,
                command: [String]? = nil,
                entrypoint: [String]? = nil,
                workingDir: String? = nil,
                environment: [String: String] = [:],
                ports: [PortMapping] = [],
                volumes: [VolumeMount] = [],
                networks: [String] = [],
                dependsOn: [String] = [],
                healthCheck: HealthCheck? = nil,
                deploy: Deploy? = nil,
                restart: String? = nil,
                containerName: String? = nil,
                profiles: [String] = [],
                labels: [String: String] = [:],
                cpus: String? = nil,
                memory: String? = nil) {
        self.name = name
        self.image = image
        self.command = command
        self.entrypoint = entrypoint
        self.workingDir = workingDir
        self.environment = environment
        self.ports = ports
        self.volumes = volumes
        self.networks = networks
        self.dependsOn = dependsOn
        self.healthCheck = healthCheck
        self.deploy = deploy
        self.restart = restart
        self.containerName = containerName
        self.profiles = profiles
        self.labels = labels
        self.cpus = cpus
        self.memory = memory
    }
}

/// Port mapping configuration
public struct PortMapping: Sendable {
    public let hostIP: String?
    public let hostPort: String
    public let containerPort: String
    public let portProtocol: String
    
    public init(hostIP: String? = nil, hostPort: String, containerPort: String, portProtocol: String = "tcp") {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.portProtocol = portProtocol
    }
    
    /// Parse from docker-compose port format
    public init?(from portString: String) {
        let components = portString.split(separator: ":")
        guard components.count >= 2 else { return nil }
        
        // Check for protocol suffix
        var lastComponent = String(components.last!)
        var parsedProtocol = "tcp"
        
        if lastComponent.contains("/") {
            let protocolParts = lastComponent.split(separator: "/")
            if protocolParts.count == 2 {
                lastComponent = String(protocolParts[0])
                parsedProtocol = String(protocolParts[1])
            }
        }
        
        switch components.count {
        case 2:
            // "hostPort:containerPort"
            self.hostIP = nil
            self.hostPort = String(components[0])
            self.containerPort = lastComponent
            self.portProtocol = parsedProtocol
            
        case 3:
            // "hostIP:hostPort:containerPort"
            self.hostIP = String(components[0])
            self.hostPort = String(components[1])
            self.containerPort = lastComponent
            self.portProtocol = parsedProtocol
            
        default:
            return nil
        }
    }
}

/// Volume mount configuration
public struct VolumeMount: Sendable {
    public let source: String
    public let target: String
    public let readOnly: Bool
    public let type: VolumeType
    
    public enum VolumeType: Sendable {
        case bind
        case volume
        case tmpfs
    }
    
    public init(source: String, target: String, readOnly: Bool = false, type: VolumeType = .bind) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
        self.type = type
    }
    
    /// Parse from docker-compose volume format
    public init?(from volumeString: String) {
        let components = volumeString.split(separator: ":", maxSplits: 2)
        guard components.count >= 2 else { return nil }
        
        let source = String(components[0])
        let target = String(components[1])
        
        // Check for read-only flag
        var isReadOnly = false
        if components.count == 3 {
            let options = String(components[2])
            isReadOnly = options.contains("ro")
        }
        
        // Determine volume type
        let volumeType: VolumeType
        if source.hasPrefix(":tmpfs:") {
            volumeType = .tmpfs
            self.source = ""
            self.target = target
            self.readOnly = isReadOnly
            self.type = volumeType
        } else if source.hasPrefix("/") || source.hasPrefix("./") || source.hasPrefix("../") {
            volumeType = .bind
            self.source = source
            self.target = target
            self.readOnly = isReadOnly
            self.type = volumeType
        } else {
            volumeType = .volume
            self.source = source
            self.target = target
            self.readOnly = isReadOnly
            self.type = volumeType
        }
    }
}

/// Health check configuration
public struct HealthCheck: Sendable {
    public let test: [String]
    public let interval: TimeInterval?
    public let timeout: TimeInterval?
    public let retries: Int?
    public let startPeriod: TimeInterval?
    
    public init(test: [String],
                interval: TimeInterval? = nil,
                timeout: TimeInterval? = nil,
                retries: Int? = nil,
                startPeriod: TimeInterval? = nil) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
    }
}

/// Deployment configuration
public struct Deploy: Sendable {
    public let resources: ServiceResources?
    
    public init(resources: ServiceResources? = nil) {
        self.resources = resources
    }
}

/// Resource constraints
public struct ServiceResources: Sendable {
    public let limits: ServiceResourceConfig?
    public let reservations: ServiceResourceConfig?
    
    public init(limits: ServiceResourceConfig? = nil, reservations: ServiceResourceConfig? = nil) {
        self.limits = limits
        self.reservations = reservations
    }
}

/// CPU and memory configuration
public struct ServiceResourceConfig: Sendable {
    public let cpus: String?
    public let memory: String?
    
    public init(cpus: String? = nil, memory: String? = nil) {
        self.cpus = cpus
        self.memory = memory
    }
}

/// Network configuration
public struct Network: Sendable {
    public let name: String
    public let driver: String
    public let external: Bool
    
    public init(name: String, driver: String = "bridge", external: Bool = false) {
        self.name = name
        self.driver = driver
        self.external = external
    }
}

/// Volume configuration
public struct Volume: Sendable {
    public let name: String
    public let driver: String
    public let external: Bool
    
    public init(name: String, driver: String = "local", external: Bool = false) {
        self.name = name
        self.driver = driver
        self.external = external
    }
}