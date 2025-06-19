//
//  Healthcheck.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Healthcheck configuration for a service.
struct Healthcheck: Codable, Hashable {
    let test: [String]? // Command to run to check health
    let start_period: String? // Grace period for the container to start
    let interval: String? // How often to run the check
    let retries: Int? // Number of consecutive failures to consider unhealthy
    let timeout: String? // Timeout for each check
}
