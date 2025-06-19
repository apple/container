//
//  DeviceReservation.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Device reservations for GPUs or other devices.
struct DeviceReservation: Codable, Hashable {
    let capabilities: [String]? // Device capabilities
    let driver: String? // Device driver
    let count: String? // Number of devices
    let device_ids: [String]? // Specific device IDs
}
