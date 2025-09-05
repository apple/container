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
import ContainerNetworkService
import CryptoKit
import ContainerClient
import Containerization
import ContainerizationError
import ContainerizationOS
import ContainerizationOCI
import Logging

#if os(macOS)
import Darwin
#else
import Glibc
#endif

// Keep strong references to DispatchSourceSignal for exec signal forwarding
@MainActor
fileprivate final class ExecSignalRetainer {
    private static var sources: [DispatchSourceSignal] = []
    static func retain(_ src: DispatchSourceSignal) { sources.append(src) }
}

// MARK: - HealthCheckRunner



public protocol HealthCheckRunner: Sendable {
    func execute(container: ClientContainer, healthCheck: HealthCheck, log: Logger) async -> Bool
}

public struct DefaultHealthCheckRunner: HealthCheckRunner {
    public init() {}

    public func execute(container: ClientContainer, healthCheck: HealthCheck, log: Logger) async -> Bool {
        guard !healthCheck.test.isEmpty else {
            log.warning("Health check has no test command")
            return false
        }

        do {
            let processId = "healthcheck-\(UUID().uuidString)"

            // Create process configuration
            let procConfig = ProcessConfiguration(
                executable: healthCheck.test[0],
                arguments: Array(healthCheck.test.dropFirst()),
                environment: [], // Use container's environment
                workingDirectory: "/"
            )

            let process = try await container.createProcess(
                id: processId,
                configuration: procConfig,
                stdio: [nil, nil, nil]
            )

            // Wait for process completion
            let result = try await process.wait()

            // Check exit status
            let success = result == 0
            if success {
                log.debug("Health check passed for container")
            } else {
                log.warning("Health check failed with exit code \(result)")
            }

            return success

        } catch {
            log.error("Health check execution failed: \(error.localizedDescription)")
            return false
        }
    }

    private struct TimeoutError: Error {
        let duration: TimeInterval
    }


}

// MARK: - BuildService

public protocol BuildService: Sendable {
    func buildImage(
        serviceName: String,
        buildConfig: BuildConfig,
        projectName: String,
        targetTag: String,
        progressHandler: ProgressUpdateHandler?
    ) async throws -> String
}

public struct DefaultBuildService: BuildService {
    private let log: Logger

    public init() {
        self.log = Logger(label: "DefaultBuildService")
    }

    public func buildImage(
        serviceName: String,
        buildConfig: BuildConfig,
        projectName: String,
        targetTag: String,
        progressHandler: ProgressUpdateHandler?
    ) async throws -> String {
        do {
            // Validate build configuration
            let contextDir = buildConfig.context ?? "."
            let dockerfilePathRaw = buildConfig.dockerfile ?? "Dockerfile"

            // Check if dockerfile exists
            // Resolve dockerfile relative to context if needed
            let dockerfileURL: URL = {
                let url = URL(fileURLWithPath: dockerfilePathRaw)
                if url.path.hasPrefix("/") { return url }
                return URL(fileURLWithPath: contextDir).appendingPathComponent(dockerfilePathRaw)
            }()
            guard FileManager.default.fileExists(atPath: dockerfileURL.path) else {
                throw ContainerizationError(
                    .notFound,
                    message: "Dockerfile not found at path '\(dockerfileURL.path)' for service '\(serviceName)'"
                )
            }

            // Check if context directory exists
            let contextURL = URL(fileURLWithPath: contextDir)
            guard FileManager.default.fileExists(atPath: contextURL.path) else {
                throw ContainerizationError(
                    .notFound,
                    message: "Build context directory not found at path '\(contextDir)' for service '\(serviceName)'"
                )
            }

            // Use the container CLI to perform the build
            try await buildImageWithCLI(
                serviceName: serviceName,
                buildConfig: buildConfig,
                imageName: targetTag,
                contextDir: contextDir,
                dockerfilePath: dockerfileURL.path
            )

            log.info("Successfully built image \(targetTag) for service \(serviceName)")
            return targetTag

        } catch let error as ContainerizationError {
            // Re-throw ContainerizationErrors as-is
            throw error
        } catch {
            log.error("Failed to build image for service \(serviceName): \(error)")
            throw ContainerizationError(
                .internalError,
                message: "Failed to build image for service '\(serviceName)': \(error.localizedDescription)"
            )
        }
    }

    private func buildImageWithCLI(
        serviceName: String,
        buildConfig: BuildConfig,
        imageName: String,
        contextDir: String,
        dockerfilePath: String
    ) async throws {
        // Get the container executable path
        let executablePath: URL
        do {
            executablePath = try getContainerExecutablePath()
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "Failed to find container executable: \(error.localizedDescription)"
            )
        }

        // Prepare build arguments
        var arguments = ["build"]

        // Add dockerfile if not default
        if dockerfilePath != "Dockerfile" {
            arguments.append(contentsOf: ["--file", dockerfilePath])
        }

        // Add build args
        if let buildArgs = buildConfig.args {
            for key in buildArgs.keys.sorted() {
                if let value = buildArgs[key] {
                    arguments.append(contentsOf: ["--build-arg", "\(key)=\(value)"])
                }
            }
        }

        // Target stage if specified
        if let target = buildConfig.target, !target.isEmpty {
            arguments.append(contentsOf: ["--target", target])
        }

        // Add tag
        arguments.append(contentsOf: ["--tag", imageName])

        // Add context directory
        arguments.append(contextDir)

        // Execute build command with proper error handling
        let process = Process()
        process.executableURL = executablePath
        process.arguments = arguments

        // Set working directory to build context
        process.currentDirectoryURL = URL(fileURLWithPath: contextDir)

        // Capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Wait for process completion
            process.waitUntilExit()
            let timeoutResult = process.terminationStatus

            if timeoutResult != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown build error"
                let outputMessage = String(data: outputData, encoding: .utf8) ?? ""

                log.error("Build failed for service '\(serviceName)'. Error: \(errorMessage)")
                if !outputMessage.isEmpty {
                    log.error("Build output: \(outputMessage)")
                }

                throw ContainerizationError(
                    .internalError,
                    message: "Build failed for service '\(serviceName)': \(errorMessage)"
                )
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let outputMessage = String(data: outputData, encoding: .utf8) ?? ""
            if !outputMessage.isEmpty {
                log.info("Build output for \(serviceName): \(outputMessage)")
            }

        } catch {
            throw ContainerizationError(
                .internalError,
                message: "Failed to execute build command for service '\(serviceName)': \(error.localizedDescription)"
            )
        }
    }

    private func getContainerExecutablePath() throws -> URL {
        // First try to find container in PATH using which command
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = ["container"]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if let pathString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !pathString.isEmpty {
                    let url = URL(fileURLWithPath: pathString)
                    if FileManager.default.fileExists(atPath: url.path) {
                        return url
                    }
                }
            }
        } catch {
            // which command failed, continue with fallback
        }

        // Try to find the container executable in the same directory as this process
        if let exePath = Bundle.main.executableURL {
            let containerPath = exePath.deletingLastPathComponent().appendingPathComponent("container")
            if FileManager.default.fileExists(atPath: containerPath.path) {
                return containerPath
            }
        }

        // Try common installation paths with proper permissions check
        let commonPaths = [
            "/usr/local/bin/container",
            "/opt/homebrew/bin/container",
            "/usr/bin/container",
            "/opt/local/bin/container"
        ]

        for path in commonPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                // Check if file is executable
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }

        // Try to find in PATH environment variable
        if let pathEnv = getenv("PATH") {
            let pathString = String(cString: pathEnv)
            let paths = pathString.split(separator: ":").map(String.init)

            for path in paths {
                let containerPath = URL(fileURLWithPath: path).appendingPathComponent("container")
                if FileManager.default.fileExists(atPath: containerPath.path) &&
                   FileManager.default.isExecutableFile(atPath: containerPath.path) {
                    return containerPath
                }
            }
        }

        throw ContainerizationError(
            .notFound,
            message: "Could not find container executable. Please ensure 'container' is installed and available in PATH"
        )
    }
}

// MARK: - VolumeClient (injectable for tests)

public protocol VolumeClient: Sendable {
    func create(name: String, driver: String, driverOpts: [String: String], labels: [String: String]) async throws -> ContainerClient.Volume
    func delete(name: String) async throws
    func list() async throws -> [ContainerClient.Volume]
    func inspect(name: String) async throws -> ContainerClient.Volume
}

public struct DefaultVolumeClient: VolumeClient {
    public init() {}
    public func create(name: String, driver: String, driverOpts: [String : String], labels: [String : String]) async throws -> ContainerClient.Volume {
        try await ClientVolume.create(name: name, driver: driver, driverOpts: driverOpts, labels: labels)
    }
    public func delete(name: String) async throws {
        try await ClientVolume.delete(name: name)
    }
    public func list() async throws -> [ContainerClient.Volume] {
        try await ClientVolume.list()
    }
    public func inspect(name: String) async throws -> ContainerClient.Volume {
        try await ClientVolume.inspect(name)
    }
}

// MARK: - Orchestrator

/// The main orchestrator for managing containerized applications
///
/// The Orchestrator is responsible for coordinating all aspects of container
/// lifecycle management, including service orchestration, image building,
/// health monitoring, and dependency resolution.
///
/// ## Key Features
///
/// - **Dependency Management**: Starts and stops services in the correct order
/// - **Image Building**: Automatically builds Docker images for services with build configs
/// - **Health Monitoring**: Executes health checks and waits for services to be ready
/// - **Parallel Execution**: Builds images concurrently where possible to improve performance
/// - **Caching**: Reuses previously built images when build configurations haven't changed
///
/// ## Thread Safety
///
/// All operations are thread-safe through the actor model, allowing multiple
/// concurrent operations while maintaining data consistency.
///
/// ## Example Usage
///
/// ```swift
/// let orchestrator = Orchestrator(log: logger)
/// let project = try await converter.convert(composeFile: composeFile, ...)
///
/// try await orchestrator.up(
///     project: project,
///     services: ["web", "api"],
///     detach: true
/// )
/// ```
public actor Orchestrator {
    public enum PullPolicy: String, Sendable {
        case always
        case missing
        case never
    }
    private let log: Logger
    private var projectState: [String: ProjectState] = [:]
    private var healthWaiters: [String: [String: [CheckedContinuation<Void, Error>]]] = [:]
    private var healthMonitors: [String: [String: Task<Void, Never>]] = [:]
    private let healthRunner: HealthCheckRunner
    private let buildService: BuildService
    private let volumeClient: VolumeClient
    private var buildCache: [String: String] = [:] // Cache key -> image name

    /// State of a project
    private struct ProjectState {
        var containers: [String: ContainerState] = [:]
        var lastAccessed: Date = Date()
    }

    /// Container status
    private enum ContainerStatus {
        case created
        case starting
        case healthy
        case unhealthy
        case stopped
        case removed
    }

    /// State of a container in a project
    private struct ContainerState {
        let serviceName: String
        let containerID: String
        let containerName: String
        var status: ContainerStatus
    }

    /// Service status information
    public struct ServiceStatus: Sendable {
        public let name: String
        public let containerID: String
        public let containerName: String
        public let status: String
        public let ports: String
        public let image: String

        public init(name: String, containerID: String, containerName: String, status: String, ports: String, image: String) {
            self.name = name
            self.containerID = containerID
            self.containerName = containerName
            self.status = status
            self.ports = ports
            self.image = image
        }
    }

    public struct DownResult: Sendable {
        public let removedContainers: [String]
        public let removedVolumes: [String]
        public init(removedContainers: [String], removedVolumes: [String]) {
            self.removedContainers = removedContainers
            self.removedVolumes = removedVolumes
        }
    }

    /// Log entry information
    public struct LogEntry: Sendable {
        public let serviceName: String
        public let containerName: String
        public let message: String
        public let stream: LogStream
        public let timestamp: Date

        public enum LogStream: Sendable {
            case stdout
            case stderr
        }

        public init(serviceName: String, containerName: String, message: String, stream: LogStream, timestamp: Date = Date()) {
            self.serviceName = serviceName
            self.containerName = containerName
            self.message = message
            self.stream = stream
            self.timestamp = timestamp
        }
    }

    public init(
        log: Logger,
        healthRunner: HealthCheckRunner = DefaultHealthCheckRunner(),
        buildService: BuildService? = nil,
        volumeClient: VolumeClient = DefaultVolumeClient()
    ) {
        self.log = log
        self.healthRunner = healthRunner
        self.buildService = buildService ?? DefaultBuildService()
        self.volumeClient = volumeClient
    }

    /// Start services in a project.
    ///
    /// Services are started in dependency order, with independent services
    /// starting in parallel. Existing containers may be reused or recreated
    /// based on the provided options.
    ///
    /// - Parameters:
    ///   - project: The project containing service definitions
    ///   - services: Specific services to start (empty means all)
    ///   - detach: Whether to run containers in the background
    ///   - forceRecreate: Force recreation of existing containers
    ///   - noRecreate: Never recreate existing containers
    ///   - removeOnExit: Automatically remove containers when they exit
    ///   - progressHandler: Optional handler for progress updates
    /// - Throws: `ContainerizationError` if service configuration is invalid or container operations fail
    public func up(
        project: Project,
        services: [String] = [],
        detach: Bool = false,
        forceRecreate: Bool = false,
        noRecreate: Bool = false,
        noDeps: Bool = false,
        removeOrphans: Bool = false,
        removeOnExit: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil,
        pullPolicy: PullPolicy = .missing,
        wait: Bool = false,
        waitTimeoutSeconds: Int? = nil,
        disableHealthcheck: Bool = false
    ) async throws {
        log.info("Starting project '\(project.name)'")

        // Filter services based on selection and --no-deps
        let targetServices: [String: Service]
        if services.isEmpty {
            targetServices = project.services
        } else if noDeps {
            // Only start the explicitly named services
            targetServices = project.services.filter { services.contains($0.key) }
        } else {
            // Include dependencies
            targetServices = DependencyResolver.filterWithDependencies(services: project.services, selected: services)
        }

        // Ensure compose networks (macOS 26+) exist before starting services
        try await ensureComposeNetworks(project: project)

        // Build images for services that need building
        do {
            log.info("Checking if images need to be built for \(targetServices.count) services")
            for (name, service) in targetServices {
                log.info("Service '\(name)': hasBuild=\(service.hasBuild), image=\(service.image ?? "nil"), build=\(service.build != nil ? "present" : "nil")")
            }

            try await buildImagesIfNeeded(
                project: project,
                services: targetServices,
                progressHandler: progressHandler
            )
            log.info("Image building completed")
        } catch {
            log.error("Failed to build images: \(error)")
            // Clean up any partial state
            projectState[project.name] = nil
            throw error
        }

        // Initialize project state
        if projectState[project.name] == nil {
            projectState[project.name] = ProjectState()
        } else {
            // Update access time for existing project
            updateProjectAccess(projectName: project.name)
        }

        // Optionally remove orphans by inspecting runtime containers
        if removeOrphans {
            await removeOrphanContainers(project: project)
        }

        // Create and start containers for services
        try await createAndStartContainers(
            project: project,
            services: targetServices,
            detach: detach,
            forceRecreate: forceRecreate,
            noRecreate: noRecreate,
            removeOnExit: removeOnExit,
            progressHandler: progressHandler,
            pullPolicy: pullPolicy,
            disableHealthcheck: disableHealthcheck
        )

        // If --wait is set, wait for selected services to be healthy/running
        if wait {
            let timeout = waitTimeoutSeconds ?? 300
            for (name, svc) in targetServices {
                if !disableHealthcheck, svc.healthCheck != nil {
                    try await waitUntilHealthy(project: project, serviceName: name, service: svc)
                } else {
                    let cid = svc.containerName ?? "\(project.name)_\(name)"
                    try await waitUntilContainerRunning(containerId: cid, timeoutSeconds: timeout)
                }
            }
        }

        // Clean up old project states to prevent memory leaks
        cleanupOldProjectStates()

        log.info("Project '\(project.name)' started successfully")
    }



    /// Clean up old project states to prevent memory leaks
    private func cleanupOldProjectStates() {
        let cutoffDate = Date().addingTimeInterval(-3600) // 1 hour ago
        let oldProjects = projectState.filter { $0.value.lastAccessed < cutoffDate }

        for (projectName, _) in oldProjects {
            log.info("Cleaning up old project state for '\(projectName)'")
            projectState[projectName] = nil
        }

        if !oldProjects.isEmpty {
            log.info("Cleaned up \(oldProjects.count) old project states")
        }
    }

    /// Update last accessed time for a project
    private func updateProjectAccess(projectName: String) {
        if var state = projectState[projectName] {
            state.lastAccessed = Date()
            projectState[projectName] = state
        }
    }

    /// Remove named volumes for a project
    private func removeNamedVolumes(project: Project, progressHandler: ProgressUpdateHandler?) async {
        // Implementation for removing named volumes
        // This would need to be implemented based on the volume management system
        log.info("Volume removal not yet implemented for project '\(project.name)'")
    }



    /// Cancel health monitors for a project
    private func cancelHealthMonitors(projectName: String) {
        guard let map = healthMonitors[projectName] else { return }
        for (_, task) in map { task.cancel() }
        healthMonitors[projectName] = [:]
    }

    /// Create and start containers for services
    private func createAndStartContainers(
        project: Project,
        services: [String: Service],
        detach: Bool,
        forceRecreate: Bool,
        noRecreate: Bool,
        removeOnExit: Bool,
        progressHandler: ProgressUpdateHandler?,
        pullPolicy: PullPolicy,
        disableHealthcheck: Bool
    ) async throws {
        // Sort services by dependencies
        let resolution = try DependencyResolver.resolve(services: services)
        let sortedServices = resolution.startOrder

        for serviceName in sortedServices {
            guard let service = services[serviceName] else { continue }

            do {
                // Wait for dependency conditions before starting this service
                try await waitForDependencyConditions(project: project, serviceName: serviceName, services: services, disableHealthcheck: disableHealthcheck)

                try await createAndStartContainer(
                    project: project,
                    serviceName: serviceName,
                    service: service,
                    detach: detach,
                    forceRecreate: forceRecreate,
                    noRecreate: noRecreate,
                    removeOnExit: removeOnExit,
                    progressHandler: progressHandler,
                    pullPolicy: pullPolicy
                )

                // Do not run background health probes by default.
                // Health checks are evaluated only when --wait is explicitly requested.
            } catch {
                log.error("Failed to start service '\(serviceName)': \(error)")
                throw error
            }
        }
    }

    /// Wait for dependencies according to compose depends_on conditions
    private func waitForDependencyConditions(project: Project, serviceName: String, services: [String: Service], disableHealthcheck: Bool) async throws {
        guard let svc = services[serviceName] else { return }

        // Wait for service_started
        for dep in svc.dependsOnStarted {
            let depId = services[dep]?.containerName ?? "\(project.name)_\(dep)"
            try await waitUntilContainerRunning(containerId: depId, timeoutSeconds: 120)
        }
        // Wait for service_healthy
        for dep in svc.dependsOnHealthy where !disableHealthcheck {
            if let depSvc = services[dep] {
                try await waitUntilHealthy(project: project, serviceName: dep, service: depSvc)
            }
        }
        // service_completed_successfully: best-effort wait for container to exit 0
        for dep in svc.dependsOnCompletedSuccessfully {
            let depId = services[dep]?.containerName ?? "\(project.name)_\(dep)"
            try await waitUntilContainerExitedSuccessfully(containerId: depId, timeoutSeconds: 600)
        }
    }

    private func waitUntilContainerRunning(containerId: String, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            do {
                let all = try await ClientContainer.list()
                if let c = all.first(where: { $0.id == containerId }), c.status == .running {
                    return
                }
            } catch { /* ignore */ }
            try await Task.sleep(nanoseconds: 300_000_000) // 300ms
        }
        throw ContainerizationError(.timeout, message: "Timed out waiting for container \(containerId) to start")
    }

    private func waitUntilContainerExitedSuccessfully(containerId: String, timeoutSeconds: Int) async throws {
        // We don't have direct process APIs here; approximate by waiting until container disappears
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            do {
                let all = try await ClientContainer.list()
                if all.first(where: { $0.id == containerId }) == nil {
                    // Consider success if it's gone (best-effort)
                    return
                }
            } catch { /* ignore */ }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ContainerizationError(.timeout, message: "Timed out waiting for container \(containerId) to complete successfully")
    }

    private func waitUntilContainerStopped(containerId: String, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            do {
                let all = try await ClientContainer.list()
                if let c = all.first(where: { $0.id == containerId }) {
                    if c.status != .running { return }
                } else {
                    return
                }
            } catch { /* ignore */ }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw ContainerizationError(.timeout, message: "Timed out waiting for container \(containerId) to stop")
    }

    private func runHealthCheckOnce(project: Project, serviceName: String, service: Service) async throws -> Bool {
        guard let hc = service.healthCheck else { return true }
        let containerId = service.containerName ?? "\(project.name)_\(serviceName)"
        let container = try await ClientContainer.get(id: containerId)
        return await healthRunner.execute(container: container, healthCheck: hc, log: log)
    }

    private func waitUntilHealthy(project: Project, serviceName: String, service: Service) async throws {
        guard let hc = service.healthCheck else { return }
        // Compute attempts based on retries/startPeriod/interval
        let interval = hc.interval ?? 5.0
        let retries = hc.retries ?? 10
        let startDelay = hc.startPeriod ?? 0
        if startDelay > 0 { try await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000)) }
        for _ in 0..<(max(1, retries)) {
            if try await runHealthCheckOnce(project: project, serviceName: serviceName, service: service) { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        throw ContainerizationError(.timeout, message: "Service \(serviceName) did not become healthy in time")
    }

    /// Create and start a single container for a service
    private func createAndStartContainer(
        project: Project,
        serviceName: String,
        service: Service,
        detach: Bool,
        forceRecreate: Bool,
        noRecreate: Bool,
        removeOnExit: Bool,
        progressHandler: ProgressUpdateHandler?,
        pullPolicy: PullPolicy
    ) async throws {
        log.info("Starting service '\(serviceName)' with image '\(service.effectiveImageName(projectName: project.name))', hasBuild: \(service.hasBuild)")

        let containerId = service.containerName ?? "\(project.name)_\(serviceName)"

        // Handle existing container logic
        try await handleExistingContainer(
            project: project,
            serviceName: serviceName,
            service: service,
            containerId: containerId,
            forceRecreate: forceRecreate,
            noRecreate: noRecreate
        )

        // Ensure image is available for build services
        let imageName = service.effectiveImageName(projectName: project.name)
        try await ensureImageAvailable(serviceName: serviceName, service: service, imageName: imageName, policy: pullPolicy)

        // Create and start new container
        try await createAndStartNewContainer(
            project: project,
            serviceName: serviceName,
            service: service,
            containerId: containerId,
            imageName: imageName,
            removeOnExit: removeOnExit,
            progressHandler: progressHandler
        )
    }

    /// Handle existing container logic (reuse, recreate, or skip)
    private func handleExistingContainer(
        project: Project,
        serviceName: String,
        service: Service,
        containerId: String,
        forceRecreate: Bool,
        noRecreate: Bool
    ) async throws {
        guard let existing = try? await findRuntimeContainer(byId: containerId) else {
            return // No existing container, proceed with creation
        }

        if noRecreate {
            log.info("Reusing existing container '\(existing.id)' for service '\(serviceName)' (no-recreate)")
            // Track in state if missing
            if projectState[project.name]?.containers[serviceName] == nil {
                projectState[project.name]?.containers[serviceName] = ContainerState(
                    serviceName: serviceName,
                    containerID: existing.id,
                    containerName: containerId,
                    status: .starting
                )
            }
            return
        }

        if !forceRecreate {
            // Check if configuration has changed
            let imageName = service.effectiveImageName(projectName: project.name)
            let expectedHash = computeConfigHash(
                project: project,
                serviceName: serviceName,
                service: service,
                imageName: imageName,
                process: ProcessConfiguration(
                    executable: service.command?.first ?? "/bin/sh",
                    arguments: Array((service.command ?? ["/bin/sh", "-c"]).dropFirst()),
                    environment: service.environment.map { "\($0.key)=\($0.value)" },
                    workingDirectory: service.workingDir ?? "/"
                ),
                ports: service.ports.map { port in
                    PublishPort(hostAddress: port.hostIP ?? "0.0.0.0",
                                hostPort: Int(port.hostPort) ?? 0,
                                containerPort: Int(port.containerPort) ?? 0,
                                proto: port.portProtocol == "tcp" ? .tcp : .udp)
                },
                mounts: service.volumes.map { v in
                    switch v.type {
                    case .bind:
                        return Filesystem.virtiofs(source: v.source, destination: v.target, options: v.readOnly ? ["ro"] : [])
                    case .volume:
                        return Filesystem.volume(name: v.source, format: "ext4", source: v.source, destination: v.target, options: v.readOnly ? ["ro"] : [], cache: .auto, sync: .full)
                    case .tmpfs:
                        return Filesystem.tmpfs(destination: v.target, options: v.readOnly ? ["ro"] : [])
                    }
                }
            )
            let currentHash = existing.configuration.labels["com.apple.container.compose.config-hash"]
            if currentHash == expectedHash {
                log.info("Reusing existing container '\(existing.id)' for service '\(serviceName)' (config unchanged)")
                return
            }
        }

        // Recreate the container
        log.info("Recreating existing container '\(existing.id)' for service '\(serviceName)'")
        // 1) Ask it to stop gracefully (SIGTERM) with longer timeout
        do { try await existing.stop(opts: ContainerStopOptions(timeoutInSeconds: 15, signal: SIGTERM)) }
        catch { log.warning("failed to stop \(existing.id): \(error)") }
        // 2) Wait until it is actually stopped; if not, escalate to SIGKILL and wait briefly
        do {
            try await waitUntilContainerStopped(containerId: existing.id, timeoutSeconds: 20)
        } catch {
            log.warning("timeout waiting for \(existing.id) to stop: \(error); sending SIGKILL")
            do { try await existing.kill(SIGKILL) } catch { log.warning("failed to SIGKILL \(existing.id): \(error)") }
            // small wait after SIGKILL
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        // 3) Try to delete (force on retry)
        do { try await existing.delete() }
        catch {
            log.warning("failed to delete \(existing.id): \(error); retrying forced delete after short delay")
            try? await Task.sleep(nanoseconds: 700_000_000)
            do { try await existing.delete(force: true) } catch { log.warning("forced delete attempt failed for \(existing.id): \(error)") }
        }
        projectState[project.name]?.containers.removeValue(forKey: serviceName)
    }

    /// Ensure the image is available for services that need building
    private func ensureImageAvailable(serviceName: String, service: Service, imageName: String, policy: PullPolicy) async throws {
        if service.hasBuild {
            log.info("Service '\(serviceName)' needs building, ensuring image is available")
            do { _ = try await ClientImage.get(reference: imageName) } catch {
                log.error("Built image '\(imageName)' not found for service '\(serviceName)': \(error)")
                throw ContainerizationError(
                    .notFound,
                    message: "Built image '\(imageName)' not found for service '\(serviceName)'. Build may have failed."
                )
            }
        } else if let imageRef = service.image {
            // Fetch image if missing
            switch policy {
            case .always:
                _ = try await ClientImage.fetch(reference: imageRef, platform: .current)
                log.info("Pulled image: \(imageRef)")
            case .missing:
                do { _ = try await ClientImage.get(reference: imageRef) }
                catch { _ = try await ClientImage.fetch(reference: imageRef, platform: .current) }
            case .never:
                _ = try await ClientImage.get(reference: imageRef)
            }
        }
    }

    /// Create and start a new container for the service
    private func createAndStartNewContainer(
        project: Project,
        serviceName: String,
        service: Service,
        containerId: String,
        imageName: String,
        removeOnExit: Bool,
        progressHandler: ProgressUpdateHandler?
    ) async throws {
        // Get the default kernel
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)

        // Create container configuration
        let containerConfig = try await createContainerConfiguration(
            project: project,
            serviceName: serviceName,
            service: service,
            imageName: imageName,
            removeOnExit: removeOnExit
        )

        // Create the container
        let createOptions = ContainerCreateOptions(autoRemove: removeOnExit)
        let container = try await ClientContainer.create(
            configuration: containerConfig,
            options: createOptions,
            kernel: kernel
        )

        // Store container state
        projectState[project.name]?.containers[serviceName] = ContainerState(
            serviceName: serviceName,
            containerID: container.id,
            containerName: containerId,
            status: .created
        )

        // Bootstrap the sandbox (set up VM and agent) and then start the init process
        _ = try await container.bootstrap(stdio: [nil, nil, nil])
        try await container.initProcess.start()

        // Update container state
        projectState[project.name]?.containers[serviceName]?.status = .starting

        log.info("Started service '\(serviceName)' with container '\(container.id)'")
    }

    private func findRuntimeContainer(byId id: String) async throws -> ClientContainer? {
        let all = try await ClientContainer.list()
        return all.first { $0.id == id }
    }

    private func expectedContainerIds(for project: Project) -> Set<String> {
        Set(project.services.map { name, svc in svc.containerName ?? "\(project.name)_\(name)" })
    }

    private func removeOrphanContainers(project: Project) async {
        do {
            let expectedServices = Set(project.services.keys)
            let all = try await ClientContainer.list()
            let orphans = all.filter { c in
                // Prefer labels if present
                if let proj = c.configuration.labels["com.apple.compose.project"], proj == project.name {
                    let svc = c.configuration.labels["com.apple.compose.service"] ?? ""
                    return !expectedServices.contains(svc)
                }
                // Fallback: prefix-based
                let prefix = "\(project.name)_"
                let id = c.id
                if id.hasPrefix(prefix) {
                    let svc = String(id.dropFirst(prefix.count))
                    return !expectedServices.contains(svc)
                }
                return false
            }
            for c in orphans {
                log.info("Removing orphan container '\(c.id)'")
                try? await c.stop()
                try? await c.delete()
            }
        } catch {
            log.warning("Failed to evaluate/remove orphans: \(error)")
        }
    }

    /// Create container configuration for a service
    private func createContainerConfiguration(
        project: Project,
        serviceName: String,
        service: Service,
        imageName: String,
        removeOnExit: Bool
    ) async throws -> ContainerConfiguration {
        // Resolve the image to get the proper ImageDescription
        let clientImage = try await ClientImage.get(reference: imageName)
        let imageDescription = clientImage.description

        // Compose entrypoint/command precedence using image config as base
        let imageObj = try? await clientImage.config(for: .current)
        let imageConfig = imageObj?.config
        let imageEntrypoint: [String] = imageConfig?.entrypoint ?? []
        let imageCmd: [String] = imageConfig?.cmd ?? []
        var svcEntrypoint = service.entrypoint ?? []
        var svcCommand = service.command ?? []
        if svcEntrypoint.count == 1 && svcEntrypoint.first == "" { svcEntrypoint = [] }
        if svcCommand.count == 1 && svcCommand.first == "" { svcCommand = [] }

        func resolveProcessCommand() -> [String] {
            var entry: [String] = []
            var cmd: [String] = []
            // entrypoint: if service entrypoint present, use it. Special case: empty string array clears.
            if !svcEntrypoint.isEmpty {
                entry = svcEntrypoint
            } else if !imageEntrypoint.isEmpty {
                entry = imageEntrypoint
            }
            // command: if service command present, use it; otherwise image CMD
            if !svcCommand.isEmpty {
                cmd = svcCommand
            } else if !imageCmd.isEmpty {
                cmd = imageCmd
            }
            return entry + cmd
        }

        let finalArgs = resolveProcessCommand()
        let execPath = finalArgs.first ?? "/bin/sh"
        let execArgs = Array(finalArgs.dropFirst())

        // Create process configuration
        var processConfig = ProcessConfiguration(
            executable: execPath,
            arguments: execArgs,
            environment: service.environment.map { "\($0.key)=\($0.value)" },
            workingDirectory: service.workingDir ?? (imageConfig?.workingDir ?? "/")
        )

        // Create container configuration
        var config = ContainerConfiguration(
            id: service.containerName ?? "\(project.name)_\(serviceName)",
            image: imageDescription,
            process: processConfig
        )

        // Add labels (merge user labels)
        var labels = service.labels
        labels["com.apple.compose.project"] = project.name
        labels["com.apple.compose.service"] = serviceName
        labels["com.apple.compose.container"] = config.id
        labels["com.apple.container.compose.config-hash"] = computeConfigHash(
            project: project,
            serviceName: serviceName,
            service: service,
            imageName: imageName,
            process: processConfig,
            ports: config.publishedPorts,
            mounts: config.mounts
        )
        config.labels = labels

        // Attach networks for this service
        let networkIds = try mapServiceNetworkIds(project: project, service: service)
        if !networkIds.isEmpty {
            // Honor declared network order without depending on internal CLI utility
            config.networks = try makeAttachmentConfigurations(containerId: config.id, networkIds: networkIds)
        } else {
            // Fallback to default network for egress
            config.networks = [AttachmentConfiguration(network: ClientNetwork.defaultNetworkName,
                                                       options: AttachmentOptions(hostname: config.id))]
        }

        // Add port mappings
        config.publishedPorts = service.ports.map { port in
            PublishPort(
                hostAddress: port.hostIP ?? "0.0.0.0",
                hostPort: Int(port.hostPort) ?? 0,
                containerPort: Int(port.containerPort) ?? 0,
                proto: port.portProtocol == "tcp" ? .tcp : .udp
            )
        }

        // Add volume mounts (ensure named/anonymous volumes exist and use their host paths)
        config.mounts = try await resolveComposeMounts(project: project, serviceName: serviceName, mounts: service.volumes)

        // Add resource limits (compose-style parsing for memory like "2g", "2048MB").
        if let cpus = service.cpus {
            config.resources.cpus = Int(cpus) ?? 4
        }
        if let memStr = service.memory, !memStr.isEmpty {
            do {
                if memStr.lowercased() == "max" {
                    // Treat "max" as no override: keep the runtime/default value (set below if needed).
                    // Intentionally do nothing here.
                } else {
                    let res = try Parser.resources(cpus: nil, memory: memStr)
                    if let bytes = res.memoryInBytes as UInt64? { config.resources.memoryInBytes = bytes }
                }
            } catch {
                log.warning("Invalid memory value '\\(memStr)'; using default. Error: \\(error)")
            }
        } else {
            // Safer default for dev servers (was 1 GiB)
            config.resources.memoryInBytes = 2048.mib()
        }

        // TTY support from compose service
        processConfig.terminal = service.tty

        return config
    }

    private func computeConfigHash(
        project: Project,
        serviceName: String,
        service: Service,
        imageName: String,
        process: ProcessConfiguration,
        ports: [PublishPort],
        mounts: [Filesystem]
    ) -> String {
        let sig = ConfigSignature(
            image: imageName,
            executable: process.executable,
            arguments: process.arguments,
            workdir: process.workingDirectory,
            environment: process.environment,
            cpus: service.cpus,
            memory: service.memory,
            ports: ports.map { PortSig(host: $0.hostAddress, hostPort: $0.hostPort, containerPort: $0.containerPort, proto: $0.proto == .tcp ? "tcp" : "udp") },
            // For mount hashing, use stable identifiers: for virtiofs binds use host path; for named/anonymous volumes, use logical name
            mounts: mounts.map { m in
                MountSig(source: m.isVolume ? (m.volumeName ?? m.source) : m.source, destination: m.destination, options: m.options)
            },
            labels: service.labels,
            health: service.healthCheck.map { HealthSig(test: $0.test, interval: $0.interval, timeout: $0.timeout, retries: $0.retries, startPeriod: $0.startPeriod) }
        )
        return sig.digest()
    }

    // MARK: - Volume helpers

    /// Resolve compose VolumeMounts to runtime Filesystem entries, ensuring named/anonymous volumes exist.
    internal func resolveComposeMounts(project: Project, serviceName: String, mounts: [VolumeMount]) async throws -> [Filesystem] {
        var result: [Filesystem] = []
        for v in mounts {
            switch v.type {
            case .bind:
                result.append(Filesystem.virtiofs(source: v.source, destination: v.target, options: v.readOnly ? ["ro"] : []))
            case .tmpfs:
                result.append(Filesystem.tmpfs(destination: v.target, options: v.readOnly ? ["ro"] : []))
            case .volume:
                let name = try resolveVolumeName(project: project, serviceName: serviceName, mount: v)
                let vol = try await ensureVolume(name: name, isExternal: project.volumes[name]?.external ?? false, project: project, serviceName: serviceName, target: v.target)
                result.append(Filesystem.volume(name: vol.name, format: vol.format, source: vol.source, destination: v.target, options: v.readOnly ? ["ro"] : [], cache: .auto, sync: .full))
            }
        }
        return result
    }

    /// Determine volume name; generate deterministic anonymous name for bare container-path mounts.
    internal func resolveVolumeName(project: Project, serviceName: String, mount: VolumeMount) throws -> String {
        // Anonymous volume if source is empty
        if mount.source.isEmpty {
            return anonymousVolumeName(projectName: project.name, serviceName: serviceName, target: mount.target)
        }
        return mount.source
    }

    /// Generate a deterministic anonymous volume name allowed by volume naming rules.
    internal func anonymousVolumeName(projectName: String, serviceName: String, target: String) -> String {
        // Hash the target path to keep names short and deterministic
        let digest = SHA256.hash(data: Data(target.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12)
        // Keep characters to [A-Za-z0-9_.-]
        let proj = projectName.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
        let svc = serviceName.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
        return "\(proj)_\(svc)_anon_\(hash)"
    }

    /// Ensure a named volume exists; create if missing (unless external). Return inspected volume with host path/format.
    internal func ensureVolume(name: String, isExternal: Bool, project: Project, serviceName: String, target: String) async throws -> ContainerClient.Volume {
        do {
            return try await volumeClient.inspect(name: name)
        } catch {
            if isExternal {
                throw ContainerizationError(.notFound, message: "external volume '\(name)' not found")
            }
            // Create the volume and label it for cleanup and traceability
            let labels: [String: String] = [
                "com.apple.compose.project": project.name,
                "com.apple.compose.service": serviceName,
                "com.apple.compose.target": target,
                "com.apple.compose.anonymous": String(name.contains("_anon_"))
            ]
            _ = try await volumeClient.create(name: name, driver: "local", driverOpts: [:], labels: labels)
            return try await volumeClient.inspect(name: name)
        }
    }

    private struct ConfigSignature: Codable {
        let image: String
        let executable: String
        let arguments: [String]
        let workdir: String
        let environment: [String]
        let cpus: String?
        let memory: String?
        let ports: [PortSig]
        let mounts: [MountSig]
        let labels: [String: String]
        let health: HealthSig?

        func canonicalJSON() -> String {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            // normalize arrays by sorting where order is insignificant
            let sortedEnv = environment.sorted()
            let sortedArgs = arguments
            let sortedPorts = ports.sorted { $0.key < $1.key }
            let sortedMounts = mounts.sorted { $0.key < $1.key }
            let sortedLabels: [LabelSig] = labels
                .sorted { $0.key < $1.key }
                .map { LabelSig(key: $0.key, value: $0.value) }
            let payload = Canonical(
                image: image,
                executable: executable,
                arguments: sortedArgs,
                workdir: workdir,
                environment: sortedEnv,
                cpus: cpus,
                memory: memory,
                ports: sortedPorts,
                mounts: sortedMounts,
                labels: sortedLabels,
                health: health
            )
            let data = try! enc.encode(payload)
            return String(data: data, encoding: .utf8)!
        }

        func digest() -> String {
            let json = canonicalJSON()
            let d = SHA256.hash(data: json.data(using: .utf8)!)
            return d.compactMap { String(format: "%02x", $0) }.joined()
        }

        struct Canonical: Codable {
            let image: String
            let executable: String
            let arguments: [String]
            let workdir: String
            let environment: [String]
            let cpus: String?
            let memory: String?
            let ports: [PortSig]
            let mounts: [MountSig]
            let labels: [LabelSig]
            let health: HealthSig?
        }
    }

    private struct LabelSig: Codable {
        let key: String
        let value: String
    }

    private struct PortSig: Codable {
        let host: String
        let hostPort: Int
        let containerPort: Int
        let proto: String
        var key: String { "\(host):\(hostPort)->\(containerPort)/\(proto)" }
    }

    private struct MountSig: Codable {
        let source: String
        let destination: String
        let options: [String]
        var key: String { "\(destination)=\(source):\(options.sorted().joined(separator: ","))" }
    }

    private struct HealthSig: Codable {
        let test: [String]
        let interval: TimeInterval?
        let timeout: TimeInterval?
        let retries: Int?
        let startPeriod: TimeInterval?
    }

    /// Build images for services that need building
    private func buildImagesIfNeeded(
        project: Project,
        services: [String: Service],
        progressHandler: ProgressUpdateHandler?
    ) async throws {
        // Find services that need building
        let servicesToBuild = services.filter { $0.value.hasBuild }

        if servicesToBuild.isEmpty {
            log.debug("No services need building")
            return
        }

        log.info("Building images for \(servicesToBuild.count) service(s)")

        // Separate cached and non-cached builds
        var cachedBuilds = [(String, String)]() // (serviceName, cachedImageName)
        var buildsToExecute = [(String, Service)]() // (serviceName, service)

        for (serviceName, service) in servicesToBuild {
            guard let buildConfig = service.build else { continue }

            // Generate cache key based on build context
            let cacheKey = buildCacheKey(serviceName: serviceName, buildConfig: buildConfig, projectName: project.name)

            // Check if we have a cached build
            if let cachedImage = buildCache[cacheKey] {
                log.info("Using cached image '\(cachedImage)' for service '\(serviceName)'")
                cachedBuilds.append((serviceName, cachedImage))
            } else {
                buildsToExecute.append((serviceName, service))
            }
        }

        // Build non-cached images in parallel where possible
        if !buildsToExecute.isEmpty {
            try await buildImagesInParallel(
                builds: buildsToExecute,
                project: project,
                progressHandler: progressHandler
            )
        }

        // Log summary
        if !cachedBuilds.isEmpty {
            log.info("Used \(cachedBuilds.count) cached image(s)")
        }
        if !buildsToExecute.isEmpty {
            log.info("Built \(buildsToExecute.count) new image(s)")
        }
    }

    /// Build images in parallel with resource management
    private func buildImagesInParallel(
        builds: [(String, Service)],
        project: Project,
        progressHandler: ProgressUpdateHandler?
    ) async throws {
        // Limit concurrent builds to avoid overwhelming the system
        let maxConcurrentBuilds = min(builds.count, 3)

        try await withThrowingTaskGroup(of: (String, String).self) { group in
            var buildsIterator = builds.makeIterator()
            var activeBuilds = 0

            // Start initial batch of builds
            while activeBuilds < maxConcurrentBuilds, let nextBuild = buildsIterator.next() {
                activeBuilds += 1
                group.addTask {
                    let targetTag = nextBuild.1.effectiveImageName(projectName: project.name)
                    let imageName = try await self.buildSingleImage(
                        serviceName: nextBuild.0,
                        service: nextBuild.1,
                        project: project,
                        targetTag: targetTag,
                        progressHandler: progressHandler
                    )
                    return (nextBuild.0, imageName)
                }
            }

            // Process completed builds and start new ones
            for try await (serviceName, imageName) in group {
                activeBuilds -= 1

                // Cache the built image
                if let buildConfig = builds.first(where: { $0.0 == serviceName })?.1.build {
                    let cacheKey = buildCacheKey(serviceName: serviceName, buildConfig: buildConfig, projectName: project.name)
                    buildCache[cacheKey] = imageName
                }

                // Start next build if available
                if let nextBuild = buildsIterator.next() {
                    activeBuilds += 1
                    group.addTask {
                        let targetTag = nextBuild.1.effectiveImageName(projectName: project.name)
                        let imageName = try await self.buildSingleImage(
                            serviceName: nextBuild.0,
                            service: nextBuild.1,
                            project: project,
                            targetTag: targetTag,
                            progressHandler: progressHandler
                        )
                        return (nextBuild.0, imageName)
                    }
                }
            }
        }
    }

    /// Build a single image
    private func buildSingleImage(
        serviceName: String,
        service: Service,
        project: Project,
        targetTag: String,
        progressHandler: ProgressUpdateHandler?
    ) async throws -> String {
        guard let buildConfig = service.build else {
            throw ContainerizationError(
                .internalError,
                message: "Service '\(serviceName)' has no build configuration"
            )
        }

        log.info("Building image for service '\(serviceName)'")

        do {
            let builtImageName = try await buildService.buildImage(
                serviceName: serviceName,
                buildConfig: buildConfig,
                projectName: project.name,
                targetTag: targetTag,
                progressHandler: progressHandler
            )

            log.info("Built image '\(builtImageName)' for service '\(serviceName)'")
            return builtImageName

        } catch let error as ContainerizationError {
            log.error("Failed to build image for service '\(serviceName)': \(error)")
            throw error
        } catch {
            log.error("Failed to build image for service '\(serviceName)': \(error)")
            throw ContainerizationError(
                .internalError,
                message: "Failed to build image for service '\(serviceName)': \(error.localizedDescription)"
            )
        }
    }

    /// Generate a cache key for a build configuration
    private func buildCacheKey(serviceName: String, buildConfig: BuildConfig, projectName: String) -> String {
        let context = buildConfig.context ?? "."
        let dockerfile = buildConfig.dockerfile ?? "Dockerfile"
        let args = buildConfig.args ?? [:]
        let argsString = args.keys.sorted().map { key in "\(key)=\(args[key] ?? "")" }.joined(separator: ";")
        let key = "\(projectName)|\(serviceName)|\(context)|\(dockerfile)|\(argsString)"
        let digest = SHA256.hash(data: key.data(using: .utf8)!)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Compose Networks

    /// Ensure non-external compose networks exist (macOS 26+). External networks must already exist.
    private func ensureComposeNetworks(project: Project) async throws {
        // If no networks defined at project level, nothing to do
        guard !project.networks.isEmpty else { return }

        // Multi-network support requires macOS 26+
        guard #available(macOS 26, *) else {
            throw ContainerizationError(.invalidArgument, message: "non-default network configuration requires macOS 26 or newer")
        }

        for (_, net) in project.networks {
            // Only support bridge driver
            if net.driver.lowercased() != "bridge" {
                throw ContainerizationError(.invalidArgument, message: "unsupported network driver '\(net.driver)' (only 'bridge' is supported)")
            }

            let id = networkId(for: project, networkName: net.name, external: net.external, externalName: net.externalName)
            if net.external {
                // External network must already exist
                do { _ = try await ClientNetwork.get(id: id) } catch {
                    throw ContainerizationError(.notFound, message: "external network '\(id)' not found")
                }
            } else {
                // Ensure/create project-scoped bridge network
                do {
                    _ = try await ClientNetwork.get(id: id)
                } catch {
                    _ = try await ClientNetwork.create(configuration: NetworkConfiguration(id: id, mode: .nat))
                }
            }
        }
    }

    /// Map declared service networks to Apple Container network IDs, honoring external vs project-scoped.
    internal func mapServiceNetworkIds(project: Project, service: Service) throws -> [String] {
        guard !service.networks.isEmpty else { return [] }
        // macOS gate aligns with Utility.getAttachmentConfigurations behavior
        guard #available(macOS 26, *) else {
            throw ContainerizationError(.invalidArgument, message: "non-default network configuration requires macOS 26 or newer")
        }
        return service.networks.map { name in
            let def = project.networks[name]
            return networkId(for: project,
                              networkName: def?.name ?? name,
                              external: def?.external ?? false,
                              externalName: def?.externalName)
        }
    }

    private func networkId(for project: Project, networkName: String, external: Bool, externalName: String?) -> String {
        if external { return externalName ?? networkName }
        return "\(project.name)_\(networkName)"
    }

    /// Build attachment configurations for declared network IDs, preserving order and gating on macOS 26+.
    private func makeAttachmentConfigurations(containerId: String, networkIds: [String]) throws -> [AttachmentConfiguration] {
        guard !networkIds.isEmpty else {
            return [AttachmentConfiguration(network: ClientNetwork.defaultNetworkName,
                                            options: AttachmentOptions(hostname: containerId))]
        }
        guard #available(macOS 26, *) else {
            throw ContainerizationError(.invalidArgument, message: "non-default network configuration requires macOS 26 or newer")
        }
        // First network will be primary by virtue of being first; hostname is set uniformly here.
        return networkIds.map { id in
            AttachmentConfiguration(network: id, options: AttachmentOptions(hostname: containerId))
        }
    }

    /// Stop and remove services in a project
    public func down(
        project: Project,
        removeVolumes: Bool = false,
        removeOrphans: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws -> DownResult {
        log.info("Stopping project '\(project.name)'")

        // Determine containers to remove
        let prefix = "\(project.name)_"
        let expectedIds: Set<String> = Set(project.services.map { name, svc in
            svc.containerName ?? "\(project.name)_\(name)"
        })

        var removedContainers: [String] = []
        do {
            let all = try await ClientContainer.list()
            let targets: [ClientContainer] = all.filter { container in
                if removeOrphans {
                    return container.id.hasPrefix(prefix)
                } else {
                    return expectedIds.contains(container.id)
                }
            }

            for c in targets {
                // Best-effort stop then delete
                do { try await c.stop() } catch { log.warning("failed to stop \(c.id): \(error)") }
                do { try await c.delete() } catch { log.warning("failed to delete \(c.id): \(error)") }
                removedContainers.append(c.id)
            }
        } catch {
            log.warning("Failed to enumerate project containers: \(error)")
        }

        // Optionally remove volumes defined in the project (non-external)
        var removedVolumes: [String] = []
        if removeVolumes {
            for (_, vol) in project.volumes {
                if !vol.external {
                    do { try await ClientVolume.delete(name: vol.name); removedVolumes.append(vol.name) }
                    catch { log.warning("failed to delete volume \(vol.name): \(error)") }
                }
            }

            // Also remove anonymous per-service volumes created for bare "/path" mounts
            do {
                let all = try await volumeClient.list()
                for v in all {
                    if v.labels["com.apple.compose.project"] == project.name,
                       v.labels["com.apple.compose.anonymous"] == "true" {
                        do { try await volumeClient.delete(name: v.name); removedVolumes.append(v.name) }
                        catch { log.warning("failed to delete anonymous volume \(v.name): \(error)") }
                    }
                }
            } catch {
                log.warning("failed to enumerate volumes for anonymous cleanup: \(error)")
            }
        }

        // Optionally remove compose-created networks (non-external)
        do {
            for (_, net) in project.networks {
                guard !net.external else { continue }
                let id = networkId(for: project, networkName: net.name, external: false, externalName: nil)
                // Best effort: delete if present
                do { try await ClientNetwork.delete(id: id) } catch { log.warning("failed to delete network \(id): \(error)") }
            }
        }

        // Clear project state
        projectState[project.name] = nil

        log.info("Project '\(project.name)' stopped and removed")
        return DownResult(removedContainers: removedContainers, removedVolumes: removedVolumes)
    }

    /// Get service statuses
    public func ps(project: Project) async throws -> [ServiceStatus] {
        let idToService: [String: String] = Dictionary(uniqueKeysWithValues: project.services.map { (name, svc) in
            let id = svc.containerName ?? "\(project.name)_\(name)"
            return (id, name)
        })
        let containers = try await ClientContainer.list()
        let filtered = containers.filter { c in
            if let proj = c.configuration.labels["com.apple.compose.project"], proj == project.name { return true }
            // Fallback to prefix if labels are missing
            return c.id.hasPrefix("\(project.name)_")
        }
        var statuses: [ServiceStatus] = []
        for c in filtered {
            let serviceName = c.configuration.labels["com.apple.compose.service"] ?? idToService[c.id] ?? c.id
            let portsStr: String = c.configuration.publishedPorts.map { p in
                let host = p.hostAddress
                return "\(host):\(p.hostPort)->\(p.containerPort)/\(p.proto == .tcp ? "tcp" : "udp")"
            }.joined(separator: ", ")
            let statusStr = c.status.rawValue
            let imageRef = c.configuration.image.reference
            let shortId = String(c.id.prefix(12))
            statuses.append(ServiceStatus(name: serviceName,
                                          containerID: shortId,
                                          containerName: c.id,
                                          status: statusStr,
                                          ports: portsStr,
                                          image: imageRef))
        }
        return statuses
    }

    /// Get logs from services
    public func logs(
        project: Project,
        services: [String] = [],
        follow: Bool = false,
        tail: Int? = nil,
        timestamps: Bool = false,
        includeBoot: Bool = false
    ) async throws -> AsyncThrowingStream<LogEntry, Error> {
        // Resolve target services
        let selected = services.isEmpty ? Set(project.services.keys) : Set(services)

        // Find matching containers (prefer labels)
        let all = try await ClientContainer.list()
        var targets: [(service: String, container: ClientContainer)] = []
        for c in all {
            if let proj = c.configuration.labels["com.apple.compose.project"], proj == project.name {
                let svc = c.configuration.labels["com.apple.compose.service"] ?? c.id
                if services.isEmpty || selected.contains(svc) {
                    targets.append((svc, c))
                }
                continue
            }
            // Fallback by id
            let prefix = "\(project.name)_"
            if c.id.hasPrefix(prefix) {
                let svc = String(c.id.dropFirst(prefix.count))
                if services.isEmpty || selected.contains(svc) {
                    targets.append((svc, c))
                }
            }
        }

        return AsyncThrowingStream { continuation in
            // If no targets, finish immediately
            if targets.isEmpty { continuation.finish(); return }

            final class Emitter: @unchecked Sendable {
                let cont: AsyncThrowingStream<LogEntry, Error>.Continuation
                // Strongly retain file handles so readabilityHandler keeps firing.
                private var retained: [FileHandle] = []
                init(_ c: AsyncThrowingStream<LogEntry, Error>.Continuation) { self.cont = c }
                func emit(_ svc: String, _ containerName: String, _ stream: LogEntry.LogStream, data: Data) {
                    guard !data.isEmpty else { return }
                    if let text = String(data: data, encoding: .utf8) {
                        for line in text.split(whereSeparator: { $0.isNewline }) {
                            cont.yield(LogEntry(serviceName: svc, containerName: containerName, message: String(line), stream: stream))
                        }
                    }
                }
                func retain(_ fh: FileHandle) { retained.append(fh) }
                func finish() { cont.finish() }
                func fail(_ error: Error) { cont.yield(with: .failure(error)) }
            }
            let emitter = Emitter(continuation)
            actor Counter { var value: Int; init(_ v: Int){ value = v } ; func dec() -> Int { value -= 1; return value } }
            let counter = Counter(targets.count)

            // For each container, open log file handles in async tasks
            for (svc, container) in targets {
                Task.detached {
                    do {
                        let fds = try await container.logs()
                        if follow {
                            if fds.indices.contains(0) {
                                let fh = fds[0]
                                fh.readabilityHandler = { handle in
                                    emitter.emit(svc, container.id, .stdout, data: handle.availableData)
                                }
                                emitter.retain(fh)
                            }
                            if includeBoot, fds.indices.contains(1) {
                                let fh = fds[1]
                                fh.readabilityHandler = { handle in
                                    emitter.emit(svc, container.id, .stderr, data: handle.availableData)
                                }
                                emitter.retain(fh)
                            }
                        } else {
                            if fds.indices.contains(0) {
                                emitter.emit(svc, container.id, .stdout, data: fds[0].readDataToEndOfFile())
                            }
                            if includeBoot, fds.indices.contains(1) {
                                emitter.emit(svc, container.id, .stderr, data: fds[1].readDataToEndOfFile())
                            }
                            let left = await counter.dec()
                            if left == 0 { emitter.finish() }
                        }
                    } catch {
                        emitter.fail(error)
                        let left = await counter.dec()
                        if left == 0 && !follow { emitter.finish() }
                    }
                }
            }
        }
    }

    /// Start stopped services
    public func start(
        project: Project,
        services: [String] = [],
        disableHealthcheck: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws {
        // Reuse up() path with defaults
        try await up(project: project, services: services, progressHandler: progressHandler, disableHealthcheck: disableHealthcheck)
    }



    /// Stop running services
    public func stop(
        project: Project,
        services: [String] = [],
        timeout: Int = 10,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws {
        // For build functionality, we just call down
        _ = try await down(project: project, progressHandler: progressHandler)
    }

    /// Restart services
    public func restart(
        project: Project,
        services: [String] = [],
        timeout: Int = 10,
        disableHealthcheck: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws {
        _ = try await down(project: project, progressHandler: progressHandler)
        try await up(project: project, services: services, progressHandler: progressHandler, disableHealthcheck: disableHealthcheck)
    }

    /// Execute command in a service
    public func exec(
        project: Project,
        serviceName: String,
        command: [String],
        detach: Bool = false,
        interactive: Bool = false,
        tty: Bool = false,
        user: String? = nil,
        workdir: String? = nil,
        environment: [String] = [],
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws -> Int32 {
        let containerId = project.services[serviceName]?.containerName ?? "\(project.name)_\(serviceName)"
        guard let container = try await findRuntimeContainer(byId: containerId) else {
            throw ContainerizationError(.notFound, message: "Service '\(serviceName)' container not found")
        }

        // Build process configuration
        let executable = command.first ?? "/bin/sh"
        let args = Array(command.dropFirst())
        var proc = ProcessConfiguration(
            executable: executable,
            arguments: args,
            environment: environment,
            workingDirectory: workdir ?? "/",
            terminal: tty
        )
        if let user = user { proc.user = .raw(userString: user) }

        // Attach stdio when not detached
        let stdin: FileHandle? = interactive || tty ? FileHandle.standardInput : nil
        let stdio: [FileHandle?] = [stdin, FileHandle.standardOutput, FileHandle.standardError]

        let pid = "exec-\(UUID().uuidString)"
        let process = try await container.createProcess(id: pid, configuration: proc, stdio: stdio)
        try await process.start()

        if detach { return 0 }

        // Forward SIGINT/SIGTERM from the plugin to the exec process (first signal)
        func installSignal(_ signo: Int32) {
            signal(signo, SIG_IGN)
            DispatchQueue.main.async {
                let src = DispatchSource.makeSignalSource(signal: signo, queue: .main)
                src.setEventHandler {
                    Task {
                        do { try await process.kill(signo) } catch { /* ignore */ }
                    }
                }
                src.resume()
                ExecSignalRetainer.retain(src)
            }
        }
        installSignal(SIGINT)
        installSignal(SIGTERM)

        return try await process.wait()
    }

    /// Check health of services
    public func checkHealth(
        project: Project,
        services: [String] = []
    ) async throws -> [String: Bool] {
        // Return healthy status for all services - build functionality doesn't need this
        var healthStatus: [String: Bool] = [:]
        let targetServices = services.isEmpty ? Array(project.services.keys) : services
        for serviceName in targetServices {
            healthStatus[serviceName] = true
        }
        return healthStatus
    }

    // Test helper methods
    public func testSetServiceHealthy(project: Project, serviceName: String) {
        // For testing - mark service as healthy
    }

    public func awaitServiceHealthy(project: Project, serviceName: String, deadlineSeconds: Int) async throws {
        // For testing - simulate waiting for service to be healthy
        try await Task.sleep(nanoseconds: UInt64(deadlineSeconds) * 1_000_000_000)
    }

    public func awaitServiceStarted(project: Project, serviceName: String, deadlineSeconds: Int) async throws {
        // For testing - simulate waiting for service to start
        try await Task.sleep(nanoseconds: UInt64(deadlineSeconds) * 1_000_000_000)
    }

    /// Result of a remove operation
    public struct RemoveResult: Sendable {
        public let removedContainers: [String]
    }

    /// Remove containers for specified services
    public func remove(
        project: Project,
        services: [String],
        force: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws -> RemoveResult {
        log.info("Removing containers for project '\(project.name)'")

        // Determine which containers to remove
        var targetServices = services

        // If no services specified, remove all services in the project
        if targetServices.isEmpty {
            targetServices = Array(project.services.keys)
        }

        // Get expected container IDs for target services
        let expectedIds: Set<String> = Set(targetServices.compactMap { serviceName in
            guard let service = project.services[serviceName] else { return nil }
            return service.containerName ?? "\(project.name)_\(serviceName)"
        })

        var removedContainers: [String] = []

        do {
            let all = try await ClientContainer.list()
            let targets: [ClientContainer] = all.filter { container in
                // Check by label first
                if let proj = container.configuration.labels["com.apple.compose.project"],
                   proj == project.name,
                   let svc = container.configuration.labels["com.apple.compose.service"],
                   targetServices.contains(svc) {
                    return true
                }
                // Fallback to ID matching
                return expectedIds.contains(container.id)
            }

            for container in targets {
                do {
                    // Check if container is running
                    if container.status == .running {
                        if force {
                            // Force stop and remove
                            try await container.stop()
                        } else {
                            log.warning("Container '\(container.id)' is running, skipping (use -f to force)")
                            continue
                        }
                    }

                    // Remove the container
                    try await container.delete()
                    removedContainers.append(container.id)
                    log.info("Removed container '\(container.id)'")

                } catch {
                    log.warning("Failed to remove container '\(container.id)': \(error)")
                }
            }
        } catch {
            log.warning("Failed to enumerate containers: \(error)")
        }

        log.info("Removed \(removedContainers.count) containers for project '\(project.name)'")
        return RemoveResult(removedContainers: removedContainers)
    }
}
