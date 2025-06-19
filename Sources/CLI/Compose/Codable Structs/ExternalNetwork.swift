//
//  ExternalNetwork.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents an external network reference.
struct ExternalNetwork: Codable {
    let isExternal: Bool // True if the network is external
    let name: String? // Optional name of the external network if different from key
}