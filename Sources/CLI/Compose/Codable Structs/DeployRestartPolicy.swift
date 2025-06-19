//
//  DeployRestartPolicy.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Restart policy for deployed tasks.
struct DeployRestartPolicy: Codable, Hashable {
    let condition: String? // Condition to restart on (e.g., 'on-failure', 'any')
    let delay: String? // Delay before attempting restart
    let max_attempts: Int? // Maximum number of restart attempts
    let window: String? // Window to evaluate restart policy
}
