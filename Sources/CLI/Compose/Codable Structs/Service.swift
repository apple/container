//
//  Service.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a single service definition within the `services` section.
struct Service: Codable, Hashable {
    let image: String? // Docker image name
    let build: Build? // Build configuration if the service is built from a Dockerfile
    let deploy: Deploy? // Deployment configuration (primarily for Swarm)
    let restart: String? // Restart policy (e.g., 'unless-stopped', 'always')
    let healthcheck: Healthcheck? // Healthcheck configuration
    let volumes: [String]? // List of volume mounts (e.g., "hostPath:containerPath", "namedVolume:/path")
    let environment: [String: String]? // Environment variables to set in the container
    let env_file: [String]? // List of .env files to load environment variables from
    let ports: [String]? // Port mappings (e.g., "hostPort:containerPort")
    let command: [String]? // Command to execute in the container, overriding the image's default
    let depends_on: [String]? // Services this service depends on (for startup order)
    let user: String? // User or UID to run the container as

    let container_name: String? // Explicit name for the container instance
    let networks: [String]? // List of networks the service will connect to
    let hostname: String? // Container hostname
    let entrypoint: [String]? // Entrypoint to execute in the container, overriding the image's default
    let privileged: Bool? // Run container in privileged mode
    let read_only: Bool? // Mount container's root filesystem as read-only
    let working_dir: String? // Working directory inside the container
    let configs: [ServiceConfig]? // Service-specific config usage (primarily for Swarm)
    let secrets: [ServiceSecret]? // Service-specific secret usage (primarily for Swarm)
    let stdin_open: Bool? // Keep STDIN open (-i flag for `container run`)
    let tty: Bool? // Allocate a pseudo-TTY (-t flag for `container run`)
    
    // Defines custom coding keys to map YAML keys to Swift properties
    enum CodingKeys: String, CodingKey {
        case image, build, deploy, restart, healthcheck, volumes, environment, env_file, ports, command, depends_on, user,
             container_name, networks, hostname, entrypoint, privileged, read_only, working_dir, configs, secrets, stdin_open, tty
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
        
        depends_on = try container.decodeIfPresent([String].self, forKey: .depends_on)
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
    }
}
