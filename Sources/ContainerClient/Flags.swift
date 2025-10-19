//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import ContainerizationError
import Foundation

public struct Flags {
    public struct Global: ParsableArguments {
        public init() {}

        @Flag(name: .long, help: "Enable debug output [environment: CONTAINER_DEBUG]")
        public var debug = false
    }

    public struct Process: ParsableArguments {
        public init() {}

        @Option(name: .shortAndLong, help: "Set environment variables (format: key=value)")
        public var env: [String] = []

        @Option(
            name: .long,
            help: "Read in a file of environment variables (key=value format, ignores # comments and blank lines)"
        )
        public var envFile: [String] = []

        @Option(name: .long, help: "Set the group ID for the process")
        public var gid: UInt32?

        @Flag(name: .shortAndLong, help: "Keep the standard input open even if not attached")
        public var interactive = false

        @Flag(name: .shortAndLong, help: "Open a TTY with the process")
        public var tty = false

        @Option(name: .shortAndLong, help: "Set the user for the process (format: name|uid[:gid])")
        public var user: String?

        @Option(name: .long, help: "Set the user ID for the process")
        public var uid: UInt32?

        @Option(
            name: [.customShort("w"), .customLong("workdir"), .long],
            help: .init(
                "Set the initial working directory inside the container",
                valueName: "dir"
            )
        )
        public var cwd: String?
    }

    public struct Resource: ParsableArguments {
        public init() {}

        @Option(name: .shortAndLong, help: "Number of CPUs to allocate to the container")
        public var cpus: Int64?

        @Option(
            name: .shortAndLong,
            help: "Amount of memory (1MiByte granularity), with optional K, M, G, T, or P suffix"
        )
        public var memory: String?
    }

    public struct Registry: ParsableArguments {
        public init() {}

        public init(scheme: String) {
            self.scheme = scheme
        }

        @Option(help: "Scheme to use when connecting to the container registry. One of (http, https, auto)")
        public var scheme: String = "auto"
    }

    public struct Management: ParsableArguments {
        public init() {}

        @Option(name: .shortAndLong, help: "Set arch if image can target multiple architectures")
        public var arch: String = Arch.hostArchitecture().rawValue

        @Option(name: .long, help: "Write the container ID to the path provided")
        public var cidfile = ""

        @Flag(name: .shortAndLong, help: "Run the container and detach from the process")
        public var detach = false

        @Option(
            name: .customLong("dns"),
            help: .init("DNS nameserver IP address", valueName: "ip")
        )
        public var dnsNameservers: [String] = []

        @Option(
            name: .long,
            help: .init("Default DNS domain", valueName: "domain")
        )
        public var dnsDomain: String? = nil

        @Option(
            name: .customLong("dns-option"),
            help: .init("DNS options", valueName: "option")
        )
        public var dnsOptions: [String] = []

        @Option(
            name: .customLong("dns-search"),
            help: .init("DNS search domains", valueName: "domain")
        )
        public var dnsSearchDomains: [String] = []

        @Option(
            name: .long,
            help: .init(
                "Override the entrypoint of the image",
                valueName: "cmd"
            )
        )
        public var entrypoint: String?

        @Option(
            name: .shortAndLong,
            help: .init("Set a custom kernel path", valueName: "path"),
            completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            }
        )
        public var kernel: String?

        @Option(name: [.short, .customLong("label")], help: "Add a key=value label to the container")
        public var labels: [String] = []

        @Option(name: .customLong("mount"), help: "Add a mount to the container (format: type=<>,source=<>,target=<>,readonly)")
        public var mounts: [String] = []

        @Option(name: .long, help: "Use the specified name as the container ID")
        public var name: String?

        @Option(name: [.customLong("network")], help: "Attach the container to a network")
        public var networks: [String] = []

        @Flag(name: [.customLong("no-dns")], help: "Do not configure DNS in the container")
        public var dnsDisabled = false

        @Option(name: .long, help: "Set OS if image can target multiple operating systems")
        public var os = "linux"

        @Option(
            name: [.customShort("p"), .customLong("publish")],
            help: .init(
                "Publish a port from container to host (format: [host-ip:]host-port:container-port[/protocol])",
                valueName: "spec"
            )
        )
        public var publishPorts: [String] = []

        @Option(name: .long, help: "Platform for the image if it's multi-platform. This takes precedence over --os and --arch")
        public var platform: String?

        @Option(
            name: .customLong("publish-socket"),
            help: .init(
                "Publish a socket from container to host (format: host_path:container_path)",
                valueName: "spec"
            )
        )
        public var publishSockets: [String] = []

        @Flag(name: [.customLong("rm"), .long], help: "Remove the container after it stops")
        public var remove = false

        @Flag(name: .long, help: "Forward SSH agent socket to container")
        public var ssh = false

        @Option(name: .customLong("tmpfs"), help: "Add a tmpfs mount to the container at the given path")
        public var tmpFs: [String] = []

        @Option(name: [.customLong("volume"), .short], help: "Bind mount a volume into the container")
        public var volumes: [String] = []

        @Flag(
            name: .long,
            help:
                "Expose virtualization capabilities to the container (requires host and guest support)"
        )
        public var virtualization: Bool = false
    }

    public struct Progress: ParsableArguments {
        public init() {}

        public init(disableProgressUpdates: Bool) {
            self.disableProgressUpdates = disableProgressUpdates
        }

        @Flag(name: .long, help: "Disable progress bar updates")
        public var disableProgressUpdates = false
    }
}
