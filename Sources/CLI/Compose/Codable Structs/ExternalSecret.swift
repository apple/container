//
//  ExternalSecret.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents an external secret reference.
struct ExternalSecret: Codable {
    let isExternal: Bool // True if the secret is external
    let name: String? // Optional name of the external secret if different from key
}