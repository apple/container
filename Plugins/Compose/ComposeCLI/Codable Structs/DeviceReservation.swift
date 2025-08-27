//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

//
//  DeviceReservation.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Device reservations for GPUs or other devices.
struct DeviceReservation: Codable, Hashable {
    /// Device capabilities
    let capabilities: [String]?
    /// Device driver
    let driver: String?
    /// Number of devices
    let count: String?
    /// Specific device IDs
    let device_ids: [String]?
}
