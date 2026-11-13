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
import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Foundation

/// A set of identical worker nodes described by one `--workers` value.
///
/// A value is either a bare number (`3`) or a comma-separated list of `key=value` pairs
/// (`count=2,cpus=4,memory=8g,virtualization=true,kernel=/path/to/vmlinux`). Omitted `cpus` and `memory` are left unset,
/// so those workers get the single-node default (1/4 of host CPUs and memory, minimum 2 CPUs and 2g). Omitted `virtualization`
/// is `false`, and omitted `kernel` uses the default kernel, as for `container run`.
struct WorkerGroup: Equatable {
    let count: UInt
    let cpus: Int64?
    let memory: String?
    let virtualization: Bool
    /// Absolute path of the kernel the workers boot, or `nil` for the default kernel.
    let kernel: String?

    /// Creates a group, validating every field.
    ///
    /// - Throws: `ValidationError` if `count` exceeds the most workers a cluster may have, if the group configures
    ///   workers but has `count == 0`, or if `cpus` or `memory` is outside what a container may be created with.
    init(count: UInt, cpus: Int64? = nil, memory: String? = nil, virtualization: Bool = false, kernel: String? = nil) throws {
        guard count <= ClusterConfiguration.maxWorkers else {
            throw ValidationError("worker count \(count) is more than the \(ClusterConfiguration.maxWorkers) workers a cluster may have")
        }
        guard count > 0 || (cpus == nil && memory == nil && !virtualization && kernel == nil) else {
            throw ValidationError("a worker group that sets cpus, memory, virtualization or kernel must have a count of at least 1")
        }
        if let cpus {
            do { _ = try Parser.cpus(cpus) } catch { throw ValidationError(wrapping: error) }
        }
        if let memory {
            do { _ = try Parser.memoryInBytes(memory) } catch { throw ValidationError("invalid memory '\(memory)': \(ValidationError(wrapping: error).message)") }
        }
        self.count = count
        self.cpus = cpus
        self.memory = memory
        self.virtualization = virtualization
        self.kernel = kernel.map(Self.absoluteKernelPath)
    }

    /// Resolves `path` against the current directory, as `container run --kernel` does.
    static func absoluteKernelPath(_ path: String) -> String {
        URL(fileURLWithPath: path, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
    }

    /// Parses one `--workers` value. Suitable as an `@Option` transform.
    init(parsing value: String) throws {
        if let count = UInt(value) {
            do {
                try self.init(count: count)
            } catch let error as ValidationError {
                throw ValidationError("\(error.message) in '\(value)'")
            }
            return
        }

        var count: UInt = 1
        var cpus: Int64?
        var memory: String?
        var virtualization = false
        var kernel: String?
        var seen = Set<String>()
        for pair in value.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ValidationError("invalid worker option '\(pair)' in '\(value)': expected a number or key=value pairs (count, cpus, memory, virtualization, kernel)")
            }
            let (key, val) = (String(parts[0]), String(parts[1]))
            guard seen.insert(key).inserted else {
                throw ValidationError("duplicate worker option '\(key)' in '\(value)'")
            }
            switch key {
            case "count":
                guard let parsed = UInt(val) else {
                    throw ValidationError("invalid worker count '\(val)' in '\(value)'")
                }
                count = parsed
            case "cpus":
                guard let parsed = Int64(val) else {
                    throw ValidationError("invalid worker cpus '\(val)' in '\(value)'")
                }
                cpus = parsed
            case "memory":
                memory = val
            case "virtualization":
                guard let parsed = Parser.parseBool(string: val) else {
                    throw ValidationError("invalid worker virtualization '\(val)' in '\(value)': expected true or false")
                }
                virtualization = parsed
            case "kernel":
                kernel = val
            default:
                throw ValidationError("unknown worker option '\(key)' in '\(value)'. Available options: count, cpus, memory, virtualization, kernel")
            }
        }
        do {
            try self.init(count: count, cpus: cpus, memory: memory, virtualization: virtualization, kernel: kernel)
        } catch let error as ValidationError {
            throw ValidationError("\(error.message) in '\(value)'")
        }
    }
}

extension ValidationError {
    /// A `ValidationError` carrying the message of `error`, so ArgumentParser reports it cleanly.
    init(wrapping error: any Error) {
        if let error = error as? ContainerizationError {
            self.init(error.message)
        } else {
            self.init("\(error)")
        }
    }
}
