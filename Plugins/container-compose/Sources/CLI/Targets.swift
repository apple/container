import ContainerAPIClient
import ContainerResource
import ComposeCore
import Foundation

/// Utilities for resolving targeted containers and computing display widths
enum TargetsUtil {
    /// Resolve targeted containers for a project/services selection, mirroring Orchestrator.logs logic
    static func resolveTargets(project: Project, services: [String]) async throws -> [(service: String, container: ContainerSnapshot)] {
        let selected = services.isEmpty ? Set(project.services.keys) : Set(services)
        let all = try await ContainerClient().list()
        return selectTargets(project: project, selected: selected, containers: all)
    }

    static func selectTargets(
        project: Project,
        services: [String],
        containers: [ContainerSnapshot]
    ) -> [(service: String, container: ContainerSnapshot)] {
        let selected = services.isEmpty ? Set(project.services.keys) : Set(services)
        return selectTargets(project: project, selected: selected, containers: containers)
    }

    static func computePrefixWidth(
        targets: [(service: String, container: ContainerSnapshot)],
        maxWidth: Int = 40
    ) -> Int {
        let maxLen = targets.map { $0.container.id.count }.max() ?? 0
        return min(maxLen, maxWidth)
    }

    private static func selectTargets(
        project: Project,
        selected: Set<String>,
        containers: [ContainerSnapshot]
    ) -> [(service: String, container: ContainerSnapshot)] {
        var targets: [(String, ContainerSnapshot)] = []
        for c in containers {
            if let proj = c.configuration.labels["com.apple.compose.project"], proj == project.name {
                let svc = c.configuration.labels["com.apple.compose.service"] ?? c.id
                if selected.contains(svc) {
                    targets.append((svc, c))
                }
                continue
            }
            let prefix = "\(project.name)_"
            if c.id.hasPrefix(prefix) {
                let svc = String(c.id.dropFirst(prefix.count))
                if selected.contains(svc) {
                    targets.append((svc, c))
                }
            }
        }
        return targets
    }

    /// Compute padding width as the longest container name among targets
    static func computePrefixWidth(project: Project, services: [String], maxWidth: Int = 40) async throws -> Int {
        let targets = try await resolveTargets(project: project, services: services)
        return computePrefixWidth(targets: targets, maxWidth: maxWidth)
    }
}
