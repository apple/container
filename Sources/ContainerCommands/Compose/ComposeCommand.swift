//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Darwin
import Foundation
import Logging
import Yams

extension Application {
    public struct ComposeCommand: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "compose",
            abstract: "Manage multi-container applications from Compose files",
            subcommands: [
                ComposeConfig.self,
                ComposeUp.self,
                ComposeDown.self,
                ComposePs.self,
                ComposeLogs.self,
            ]
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            print(Self.helpMessage())
        }
    }
}

private protocol ComposeFileOptions {
    var file: String? { get }
    var projectName: String? { get }
    var profiles: [String] { get }
    var envFiles: [String] { get }
}

private extension ComposeFileOptions {
    func loadComposeProject() throws -> ComposeProject {
        try ComposeSupport.loadProject(
            filePath: file,
            projectName: projectName,
            profiles: profiles,
            envFiles: envFiles
        )
    }
}

extension Application.ComposeCommand {
    struct ComposeConfig: AsyncLoggableCommand, ComposeFileOptions {
        static let configuration = CommandConfiguration(
            commandName: "config",
            abstract: "Validate and print the normalized Compose project"
        )

        @Option(name: .shortAndLong, help: "Compose file path")
        var file: String?

        @Option(name: .shortAndLong, help: "Compose project name")
        var projectName: String?

        @Option(name: .customLong("profile"), help: "Enable a Compose profile")
        var profiles: [String] = []

        @Option(name: .customLong("env-file"), help: "Compose interpolation env-file")
        var envFiles: [String] = []

        @OptionGroup
        public var logOptions: Flags.Logging

        func run() async throws {
            let project = try loadComposeProject()
            let encoder = YAMLEncoder()
            let output = try encoder.encode(RenderedComposeProject(project: project))
            print(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    struct ComposeUp: AsyncLoggableCommand, ComposeFileOptions {
        static let configuration = CommandConfiguration(
            commandName: "up",
            abstract: "Create and start services from a Compose project"
        )

        @Option(name: .shortAndLong, help: "Compose file path")
        var file: String?

        @Option(name: .shortAndLong, help: "Compose project name")
        var projectName: String?

        @Option(name: .customLong("profile"), help: "Enable a Compose profile")
        var profiles: [String] = []

        @Option(name: .customLong("env-file"), help: "Compose interpolation env-file")
        var envFiles: [String] = []

        @Flag(name: .shortAndLong, help: "Build images before starting services")
        var build: Bool = false

        @Argument(help: "Optional service names to start")
        var serviceNames: [String] = []

        @OptionGroup
        public var logOptions: Flags.Logging

        func run() async throws {
            let project = try loadComposeProject()
            try await ComposeExecutor(log: log).up(project: project, selectedServices: Set(serviceNames), build: build)
        }
    }

    struct ComposeDown: AsyncLoggableCommand, ComposeFileOptions {
        static let configuration = CommandConfiguration(
            commandName: "down",
            abstract: "Stop and remove Compose project resources"
        )

        @Option(name: .shortAndLong, help: "Compose file path")
        var file: String?

        @Option(name: .shortAndLong, help: "Compose project name")
        var projectName: String?

        @Option(name: .customLong("profile"), help: "Enable a Compose profile")
        var profiles: [String] = []

        @Option(name: .customLong("env-file"), help: "Compose interpolation env-file")
        var envFiles: [String] = []

        @Flag(name: [.customShort("v"), .customLong("volumes")], help: "Remove named volumes declared by the Compose project")
        var removeVolumes: Bool = false

        @Flag(name: .customLong("remove-orphans"), help: "Accepted for compatibility; project-scoped resources are always removed")
        var removeOrphans: Bool = false

        @OptionGroup
        public var logOptions: Flags.Logging

        func run() async throws {
            let project = try loadComposeProject()
            try await ComposeExecutor(log: log).down(project: project, removeVolumes: removeVolumes || removeOrphans)
        }
    }

    struct ComposePs: AsyncLoggableCommand, ComposeFileOptions {
        static let configuration = CommandConfiguration(
            commandName: "ps",
            abstract: "List Compose services and their containers"
        )

        @Option(name: .shortAndLong, help: "Compose file path")
        var file: String?

        @Option(name: .shortAndLong, help: "Compose project name")
        var projectName: String?

        @Option(name: .customLong("profile"), help: "Enable a Compose profile")
        var profiles: [String] = []

        @Option(name: .customLong("env-file"), help: "Compose interpolation env-file")
        var envFiles: [String] = []

        @Option(name: .long, help: "Format of the output")
        var format: Application.ListFormat = .table

        @Argument(help: "Optional service names to filter")
        var serviceNames: [String] = []

        @OptionGroup
        public var logOptions: Flags.Logging

        func run() async throws {
            let project = try loadComposeProject()
            try await ComposeExecutor(log: log).ps(project: project, selectedServices: Set(serviceNames), format: format)
        }
    }

    struct ComposeLogs: AsyncLoggableCommand, ComposeFileOptions {
        static let configuration = CommandConfiguration(
            commandName: "logs",
            abstract: "Show logs for Compose services"
        )

        @Option(name: .shortAndLong, help: "Compose file path")
        var file: String?

        @Option(name: .shortAndLong, help: "Compose project name")
        var projectName: String?

        @Option(name: .customLong("profile"), help: "Enable a Compose profile")
        var profiles: [String] = []

        @Option(name: .customLong("env-file"), help: "Compose interpolation env-file")
        var envFiles: [String] = []

        @Flag(name: .shortAndLong, help: "Follow log output")
        var follow: Bool = false

        @Option(name: .short, help: "Number of lines to show from the end of the logs")
        var numLines: Int?

        @Argument(help: "Optional service names to show")
        var serviceNames: [String] = []

        @OptionGroup
        public var logOptions: Flags.Logging

        func run() async throws {
            let project = try loadComposeProject()
            try await ComposeExecutor(log: log).logs(
                project: project,
                selectedServices: Set(serviceNames),
                follow: follow,
                numLines: numLines
            )
        }
    }
}

private struct ComposeExecutor {
    let log: Logger

    func up(project: ComposeProject, selectedServices: Set<String>, build: Bool) async throws {
        let services = try filteredOrderedServices(project: project, selectedServices: selectedServices)

        try await ensureNetworks(project: project)
        try await ensureVolumes(project: project)

        if build {
            for service in services where service.build != nil {
                try await buildImage(for: service)
            }
        }

        let client = ContainerClient()
        let existingContainers = try await client.list(filters: ContainerListFilters(labels: [
            ComposeSupport.projectLabel: project.name
        ]))
        let existingById = Dictionary(uniqueKeysWithValues: existingContainers.map { ($0.id, $0) })

        for service in services {
            try await waitForDependencies(of: service, in: project)
            let configHash = try ComposeSupport.hashService(service)
            let existing = existingById[service.containerName]

            if let existing, existing.configuration.labels[ComposeSupport.configHashLabel] != configHash {
                if existing.status == .running || existing.status == .stopping {
                    try await client.stop(id: existing.id)
                }
                try await client.delete(id: existing.id, force: true)
            }

            if let existing = try? await client.get(id: service.containerName),
               existing.configuration.labels[ComposeSupport.configHashLabel] == configHash {
                if existing.status == .running {
                    continue
                }
                try await startDetached(containerId: existing.id)
                continue
            }

            try await createAndStart(service: service, project: project, configHash: configHash)
        }
    }

    func down(project: ComposeProject, removeVolumes: Bool) async throws {
        let client = ContainerClient()
        let containers = try await client.list(filters: ContainerListFilters(labels: [
            ComposeSupport.projectLabel: project.name
        ]))

        for container in containers where container.status == .running || container.status == .stopping {
            try await client.stop(id: container.id)
        }
        for container in containers {
            try await client.delete(id: container.id, force: true)
        }

        let networks = try await ClientNetwork.list()
        for network in networks where networkProjectName(network) == project.name {
            try? await ClientNetwork.delete(id: network.id)
        }

        if removeVolumes {
            let volumes = try await ClientVolume.list()
            for volume in volumes where volume.labels[ComposeSupport.projectLabel] == project.name {
                try? await ClientVolume.delete(name: volume.name)
            }
        }
    }

    func ps(project: ComposeProject, selectedServices: Set<String>, format: Application.ListFormat) async throws {
        let client = ContainerClient()
        let containers = try await client.list(filters: ContainerListFilters(labels: [
            ComposeSupport.projectLabel: project.name
        ]))
        let filtered = containers
            .filter { selectedServices.isEmpty || selectedServices.contains($0.configuration.labels[ComposeSupport.serviceLabel] ?? "") }
            .sorted {
                ($0.configuration.labels[ComposeSupport.serviceLabel] ?? "", $0.id)
                    < ($1.configuration.labels[ComposeSupport.serviceLabel] ?? "", $1.id)
            }

        if format == .json {
            let data = try JSONEncoder().encode(filtered.map(PrintableComposeService.init))
            print(String(decoding: data, as: UTF8.self))
            return
        }

        var rows = [["SERVICE", "CONTAINER", "STATE", "IMAGE", "STARTED"]]
        for container in filtered {
            rows.append([
                container.configuration.labels[ComposeSupport.serviceLabel] ?? "",
                container.id,
                container.status.rawValue,
                container.configuration.image.reference,
                container.startedDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            ])
        }
        print(TableOutput(rows: rows).format())
    }

    func logs(project: ComposeProject, selectedServices: Set<String>, follow: Bool, numLines: Int?) async throws {
        let client = ContainerClient()
        let containers = try await client.list(filters: ContainerListFilters(labels: [
            ComposeSupport.projectLabel: project.name
        ]))
        let filtered = containers
            .filter { selectedServices.isEmpty || selectedServices.contains($0.configuration.labels[ComposeSupport.serviceLabel] ?? "") }
            .sorted {
                ($0.configuration.labels[ComposeSupport.serviceLabel] ?? "", $0.id)
                    < ($1.configuration.labels[ComposeSupport.serviceLabel] ?? "", $1.id)
            }

        if follow && filtered.count > 1 {
            throw ContainerizationError(.unsupported, message: "following logs for multiple Compose services is not supported")
        }

        for container in filtered {
            let fhs = try await client.logs(id: container.id)
            let serviceName = container.configuration.labels[ComposeSupport.serviceLabel] ?? container.id
            try printLogData(
                try fhs[0].readToEnd() ?? Data(),
                prefix: filtered.count > 1 ? "\(serviceName) | " : "",
                numLines: numLines
            )

            if follow {
                try await followLog(fhs[0], prefix: filtered.count > 1 ? "\(serviceName) | " : "")
            }
        }
    }

    private func filteredOrderedServices(project: ComposeProject, selectedServices: Set<String>) throws -> [NormalizedComposeService] {
        let ordered = try project.orderedServices
        if selectedServices.isEmpty {
            return ordered
        }
        let expanded = try dependencyClosure(project: project, selectedServices: selectedServices)
        return ordered.filter { expanded.contains($0.name) }
    }

    private func dependencyClosure(project: ComposeProject, selectedServices: Set<String>) throws -> Set<String> {
        var result = selectedServices
        var stack = Array(selectedServices)
        while let name = stack.popLast() {
            guard let service = project.services[name] else {
                throw ContainerizationError(.invalidArgument, message: "unknown Compose service '\(name)'")
            }
            for dependency in service.dependsOn where !result.contains(dependency) {
                result.insert(dependency)
                stack.append(dependency)
            }
        }
        return result
    }

    private func ensureNetworks(project: ComposeProject) async throws {
        let existing = try await ClientNetwork.list()
        let existingNames = Set(existing.map(\.id))
        for networkName in project.networks where !existingNames.contains(networkName) {
            let config = try NetworkConfiguration(
                id: networkName,
                mode: .nat,
                labels: ComposeSupport.projectResourceLabels(project: project.name),
                pluginInfo: NetworkPluginInfo(plugin: "container-network-vmnet")
            )
            _ = try await ClientNetwork.create(configuration: config)
        }
    }

    private func ensureVolumes(project: ComposeProject) async throws {
        let existing = try await ClientVolume.list()
        let existingNames = Set(existing.map(\.name))
        for volumeName in project.volumes where !existingNames.contains(volumeName) {
            _ = try await ClientVolume.create(
                name: volumeName,
                labels: ComposeSupport.projectResourceLabels(project: project.name)
            )
        }
    }

    private func buildImage(for service: NormalizedComposeService) async throws {
        guard let build = service.build else { return }
        var arguments = ["--progress", "plain", "--tag", service.image]
        for key in build.args.keys.sorted() {
            arguments.append(contentsOf: ["--build-arg", "\(key)=\(build.args[key] ?? "")"])
        }
        if let dockerfilePath = build.dockerfilePath {
            arguments.append(contentsOf: ["--file", dockerfilePath])
        }
        if let target = build.target {
            arguments.append(contentsOf: ["--target", target])
        }
        arguments.append(build.contextDirectory)
        var command = try Application.BuildCommand.parseAsRoot(arguments)
        try await command.run()
    }

    private func waitForDependencies(of service: NormalizedComposeService, in project: ComposeProject) async throws {
        for dependency in service.dependencyConditions {
            guard let dependencyService = project.services[dependency.service] else {
                throw ContainerizationError(.invalidArgument, message: "service '\(service.name)' depends on unknown service '\(dependency.service)'")
            }

            switch dependency.condition {
            case .serviceStarted:
                try await waitForContainerRunning(id: dependencyService.containerName)
            case .serviceHealthy:
                guard let healthcheck = dependencyService.healthcheck else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "service '\(service.name)' requires '\(dependency.service)' to be healthy, but '\(dependency.service)' has no healthcheck"
                    )
                }
                try await waitForHealthcheck(service: dependencyService, healthcheck: healthcheck)
            }
        }
    }

    private func createAndStart(service: NormalizedComposeService, project: ComposeProject, configHash: String) async throws {
        let processFlags = Flags.Process(
            cwd: service.workingDir,
            env: service.environment,
            envFile: [],
            gid: nil,
            interactive: service.stdinOpen,
            tty: service.tty,
            uid: nil,
            ulimits: [],
            user: service.user
        )

        let managementFlags = Flags.Management(
            arch: Arch.hostArchitecture().rawValue,
            cidfile: "",
            detach: true,
            dns: Flags.DNS(domain: nil, nameservers: [], options: [], searchDomains: []),
            dnsDisabled: false,
            entrypoint: service.entrypoint,
            initImage: nil,
            kernel: nil,
            labels: try serviceLabels(service: service, projectName: project.name, configHash: configHash),
            mounts: [],
            name: service.containerName,
            networks: service.networks,
            os: "linux",
            platform: nil,
            publishPorts: service.ports,
            publishSockets: [],
            readOnly: false,
            remove: false,
            rosetta: false,
            runtime: nil,
            ssh: false,
            tmpFs: [],
            useInit: false,
            virtualization: false,
            volumes: service.volumes
        )

        let registryFlags = Flags.Registry(scheme: "auto")
        let resourceFlags = Flags.Resource(cpus: nil, memory: nil)
        let imageFetchFlags = Flags.ImageFetch(maxConcurrentDownloads: 3)
        let client = ContainerClient()
        let ck = try await Utility.containerConfigFromFlags(
            id: service.containerName,
            image: service.image,
            arguments: service.commandArguments,
            process: processFlags,
            management: managementFlags,
            resource: resourceFlags,
            registry: registryFlags,
            imageFetch: imageFetchFlags,
            progressUpdate: { _ in },
            log: log
        )

        var configuration = ck.0
        configuration.networks = configuration.networks.map {
            AttachmentConfiguration(
                network: $0.network,
                options: AttachmentOptions(
                    hostname: service.name,
                    macAddress: $0.options.macAddress,
                    mtu: $0.options.mtu
                )
            )
        }

        try await client.create(
            configuration: configuration,
            options: ContainerCreateOptions(autoRemove: false),
            kernel: ck.1,
            initImage: ck.2
        )
        try await startDetached(containerId: service.containerName)
    }

    private func serviceLabels(service: NormalizedComposeService, projectName: String, configHash: String) throws -> [String] {
        let labels = ComposeSupport.composeLabels(project: projectName, service: service.name, configHash: configHash)
        return labels.keys.sorted().map { "\($0)=\(labels[$0] ?? "")" }
    }

    private func startDetached(containerId: String) async throws {
        let client = ContainerClient()
        let container = try await client.get(id: containerId)

        if container.status == .running {
            print(containerId)
            return
        }

        for mount in container.configuration.mounts where mount.isVirtiofs {
            if !FileManager.default.fileExists(atPath: mount.source) {
                throw ContainerizationError(.invalidState, message: "path '\(mount.source)' is not a directory")
            }
        }

        let io = try ProcessIO.create(
            tty: container.configuration.initProcess.terminal,
            interactive: false,
            detach: true
        )
        defer {
            try? io.close()
        }

        do {
            let process = try await client.bootstrap(id: container.id, stdio: io.stdio)
            try await process.start()
            try io.closeAfterStart()
            print(containerId)
        } catch {
            try? await client.stop(id: container.id)

            if error is ContainerizationError {
                throw error
            }
            throw ContainerizationError(.internalError, message: "failed to start container: \(error)")
        }
    }

    private func networkProjectName(_ network: NetworkState) -> String? {
        switch network {
        case .created(let config), .running(let config, _):
            return config.labels[ComposeSupport.projectLabel]
        }
    }

    private func waitForContainerRunning(id: String, timeout: Duration = .seconds(60)) async throws {
        let client = ContainerClient()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let container = try? await client.get(id: id), container.status == .running {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ContainerizationError(.timeout, message: "timed out waiting for container \(id) to start")
    }

    private func waitForHealthcheck(service: NormalizedComposeService, healthcheck: ComposeHealthcheckDefinition) async throws {
        guard case .none = healthcheck.test else {
            try await waitForContainerRunning(id: service.containerName)
            if healthcheck.startPeriod > .zero {
                try await Task.sleep(for: healthcheck.startPeriod)
            }

            let attempts = max(healthcheck.retries, 1)
            for attempt in 1...attempts {
                if try await runHealthcheckProbe(containerId: service.containerName, healthcheck: healthcheck) {
                    return
                }
                if attempt < attempts {
                    try await Task.sleep(for: healthcheck.interval)
                }
            }

            throw ContainerizationError(
                .invalidState,
                message: "healthcheck failed for service '\(service.name)' after \(attempts) attempt(s)"
            )
        }

        throw ContainerizationError(.invalidArgument, message: "service '\(service.name)' disables its healthcheck and can not satisfy service_healthy")
    }

    private func runHealthcheckProbe(containerId: String, healthcheck: ComposeHealthcheckDefinition) async throws -> Bool {
        let client = ContainerClient()
        let container = try await client.get(id: containerId)
        try Application.ensureRunning(container: container)

        let command: [String]
        switch healthcheck.test {
        case .none:
            return false
        case .shell(let shellCommand):
            command = ["/bin/sh", "-c", shellCommand]
        case .exec(let args):
            guard !args.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "healthcheck command for container \(containerId) is empty")
            }
            command = args
        }

        var config = container.configuration.initProcess
        config.executable = command[0]
        config.arguments = Array(command.dropFirst())
        config.terminal = false

        let process = try await client.createProcess(
            containerId: container.id,
            processId: UUID().uuidString.lowercased(),
            configuration: config,
            stdio: [nil, nil, nil]
        )
        try await process.start()

        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                let exitCode = try await process.wait()
                return exitCode == 0
            }
            group.addTask {
                try await Task.sleep(for: healthcheck.timeout)
                try? await process.kill(SIGKILL)
                return false
            }

            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func printLogData(_ data: Data, prefix: String, numLines: Int?) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "failed to decode container logs as UTF-8")
        }
        var lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if let numLines {
            lines = Array(lines.suffix(numLines))
        }
        for line in lines {
            print("\(prefix)\(line)")
        }
    }

    private func followLog(_ handle: FileHandle, prefix: String) async throws {
        _ = try handle.seekToEnd()
        let stream = AsyncStream<String> { continuation in
            handle.readabilityHandler = { logHandle in
                let data = logHandle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    for line in text.components(separatedBy: .newlines).filter({ !$0.isEmpty }) {
                        continuation.yield(line)
                    }
                }
            }
        }

        for await line in stream {
            print("\(prefix)\(line)")
        }
    }
}

private struct RenderedComposeProject: Encodable {
    let name: String
    let services: [String: NormalizedComposeService]
    let networks: [String]
    let volumes: [String]

    init(project: ComposeProject) {
        self.name = project.name
        self.services = project.services
        self.networks = project.networks
        self.volumes = project.volumes
    }
}

private struct PrintableComposeService: Codable {
    let service: String
    let container: String
    let state: RuntimeStatus
    let image: String
    let startedDate: Date?

    init(_ snapshot: ContainerSnapshot) {
        self.service = snapshot.configuration.labels[ComposeSupport.serviceLabel] ?? snapshot.id
        self.container = snapshot.id
        self.state = snapshot.status
        self.image = snapshot.configuration.image.reference
        self.startedDate = snapshot.startedDate
    }
}
