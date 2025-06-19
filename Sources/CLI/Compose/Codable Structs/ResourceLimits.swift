//
//  ResourceLimits.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// CPU and memory limits.
struct ResourceLimits: Codable, Hashable {
    let cpus: String? // CPU limit (e.g., "0.5")
    let memory: String? // Memory limit (e.g., "512M")
}
