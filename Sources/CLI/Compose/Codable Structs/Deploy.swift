//
//  Deploy.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents the `deploy` configuration for a service (primarily for Swarm orchestration).
struct Deploy: Codable, Hashable {
    let mode: String? // Deployment mode (e.g., 'replicated', 'global')
    let replicas: Int? // Number of replicated service tasks
    let resources: DeployResources? // Resource constraints (limits, reservations)
    let restart_policy: DeployRestartPolicy? // Restart policy for tasks
}
