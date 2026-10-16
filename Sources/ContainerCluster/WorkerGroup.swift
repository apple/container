//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import Foundation

/// A set of identical worker nodes described by one `--workers` value.
///
/// A value is either a bare number (`3`) or a comma-separated list of `key=value` pairs
/// (`count=2,cpus=4,memory=8g`). Omitted `cpus` and `memory` are left unset for the single-node default.
struct WorkerGroup: Equatable {
    var count: UInt
    var cpus: Int64?
    var memory: String?

    init(count: UInt, cpus: Int64? = nil, memory: String? = nil) {
        self.count = count
        self.cpus = cpus
        self.memory = memory
    }

    /// Parses one `--workers` value. Suitable as an `@Option` transform.
    init(parsing value: String) throws {
        if let count = UInt(value) {
            self.init(count: count)
            return
        }

        self.init(count: 1)
        var seen = Set<String>()
        for pair in value.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ValidationError("invalid worker option '\(pair)' in '\(value)': expected a number or key=value pairs (count, cpus, memory)")
            }
            let (key, val) = (String(parts[0]), String(parts[1]))
            guard seen.insert(key).inserted else {
                throw ValidationError("duplicate worker option '\(key)' in '\(value)'")
            }
            switch key {
            case "count":
                guard let count = UInt(val) else {
                    throw ValidationError("invalid worker count '\(val)' in '\(value)'")
                }
                self.count = count
            case "cpus":
                guard let cpus = Int64(val), cpus > 0 else {
                    throw ValidationError("invalid worker cpus '\(val)' in '\(value)'")
                }
                self.cpus = cpus
            case "memory":
                try Self.validateMemory(val, in: value)
                self.memory = val
            default:
                throw ValidationError("unknown worker option '\(key)' in '\(value)'. Available options: count, cpus, memory")
            }
        }
        guard count > 0 || (cpus == nil && memory == nil) else {
            throw ValidationError("worker group '\(value)' sizes workers but has count=0")
        }
    }

    /// Validates a memory size such as `8g`; rejects unparsable, zero, negative, and out-of-range values.
    private static func validateMemory(_ size: String, in value: String) throws {
        let mib: Double
        do {
            mib = try Measurement<UnitInformationStorage>.parse(parsing: size).converted(to: .mebibytes).value
        } catch {
            throw ValidationError("invalid memory '\(size)' in '\(value)': \(error)")
        }
        // Leave headroom so converting to bytes cannot overflow.
        guard mib.isFinite, mib >= 1, mib < Double(Int64.max / (1024 * 1024)) else {
            throw ValidationError("memory '\(size)' in '\(value)' is out of range")
        }
    }
}
