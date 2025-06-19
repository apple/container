//
//  ResourceReservations.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// **FIXED**: Renamed from `ResourceReservables` to `ResourceReservations` and made `Codable`.
/// CPU and memory reservations.
struct ResourceReservations: Codable, Hashable { // Changed from ResourceReservables to ResourceReservations
    let cpus: String? // CPU reservation (e.g., "0.25")
    let memory: String? // Memory reservation (e.g., "256M")
    let devices: [DeviceReservation]? // Device reservations for GPUs or other devices
}
