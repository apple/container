import ContainerClient
import ComposeCore
import Foundation

/// Utilities for resolving targeted containers and computing display widths
enum TargetsUtil {
    /// Resolve targeted containers for a project/services selection, mirroring Orchestrator.logs logic
    static func resolveTargets(project: Project, services: [String]) async throws -> [(service: String, container: ClientContainer)] {
        let selected = services.isEmpty ? Set(project.services.keys) : Set(services)
        let all = try await ClientContainer.list()
        var targets: [(String, ClientContainer)] = []
        for c in all {
            if let proj = c.configuration.labels["com.apple.compose.project"], proj == project.name {
                let svc = c.configuration.labels["com.apple.compose.service"] ?? c.id
                if services.isEmpty || selected.contains(svc) {
                    targets.append((svc, c))
                }
                continue
            }
            let prefix = "\(project.name)_"
            if c.id.hasPrefix(prefix) {
                let svc = String(c.id.dropFirst(prefix.count))
                if services.isEmpty || selected.contains(svc) {
                    targets.append((svc, c))
                }
            }
        }
        return targets
    }

    /// Compute padding width as the longest container name among targets
    static func computePrefixWidth(project: Project, services: [String], maxWidth: Int = 40) async throws -> Int {
        let t = try await resolveTargets(project: project, services: services)
        let maxLen = t.map { $0.container.id.count }.max() ?? 0
        return min(maxLen, maxWidth)
    }
}
