//
//  DeployResources.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Resource constraints for deployment.
struct DeployResources: Codable, Hashable {
    let limits: ResourceLimits? // Hard limits on resources
    let reservations: ResourceReservations? // Guarantees for resources
}
