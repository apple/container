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

import ArgumentParser
import Foundation

public struct Flags {
    public struct Global: ParsableArguments {
        public init() {}

        @Flag(name: .long, help: "Enable debug output [environment: CONTAINER_DEBUG]")
        public var debug = false
    }

    public struct Process: ParsableArguments {
        public init() {}

        @Option(
            name: [.customLong("cwd"), .customShort("w"), .customLong("workdir")],
            help: "Current working directory for the container")
        public var cwd: String?

        @Option(name: [.customLong("env"), .customShort("e")], help: "Set environment variables")
        public var env: [String] = []

        @Option(name: .customLong("env-file"), help: "Read in a file of environment variables")
        public var envFile: [String] = []

        @Option(name: .customLong("uid"), help: "Set the uid for the process")
        public var uid: UInt32?

        @Option(name: .customLong("gid"), help: "Set the gid for the process")
        public var gid: UInt32?

        @Flag(name: [.customLong("interactive"), .customShort("i")], help: "Keep Stdin open even if not attached")
        public var interactive = false

        @Flag(name: [.customLong("tty"), .customShort("t")], help: "Open a tty with the process")
        public var tty = false

        @Option(name: [.customLong("user"), .customShort("u")], help: "Set the user for the process")
        public var user: String?
    }

    public struct Resource: ParsableArguments {
        public init() {}

        @Option(name: [.customLong("cpus"), .customShort("c")], help: "Number of CPUs to allocate to the container")
        public var cpus: Int64?

        @Option(
            name: [.customLong("memory"), .customShort("m")],
            help:
                "Amount of memory in bytes, kilobytes (K), megabytes (M), or gigabytes (G) for the container, with MB granularity (for example, 1024K will result in 1MB being allocated for the container)"
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

        @Flag(name: [.customLong("detach"), .customShort("d")], help: "Run the container and detach from the process")
        public var detach = false

        @Option(name: .customLong("entrypoint"), help: "Override the entrypoint of the image")
        public var entryPoint: String?

        @Option(name: .customLong("mount"), help: "Add a mount to the container (type=<>,source=<>,target=<>,readonly)")
        public var mounts: [String] = []

        @Option(name: .customLong("publish-socket"), help: "Publish a socket from container to host (format: host_path:container_path)")
        public var publishSockets: [String] = []

        @Option(name: .customLong("tmpfs"), help: "Add a tmpfs mount to the container at the given path")
        public var tmpFs: [String] = []

        @Option(name: .customLong("name"), help: "Assign a name to the container. If excluded will be a generated UUID")
        public var name: String?

        @Flag(name: [.customLong("remove"), .customLong("rm")], help: "Remove the container after it stops")
        public var remove = false

        @Option(name: .customLong("os"), help: "Set OS if image can target multiple operating systems")
        public var os = "linux"

        @Option(
            name: [.customLong("arch"), .customShort("a")], help: "Set arch if image can target multiple architectures")
        public var arch: String = Arch.hostArchitecture().rawValue

        @Option(name: [.customLong("volume"), .customShort("v")], help: "Bind mount a volume into the container")
        public var volumes: [String] = []

        @Option(
            name: [.customLong("kernel"), .customShort("k")], help: "Set a custom kernel path", completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            })
        public var kernel: String?

        @Option(name: .customLong("cidfile"), help: "Write the container ID to the path provided")
        public var cidfile = ""

        @Flag(name: [.customLong("no-dns")], help: "Do not configure DNS in the container")
        public var dnsDisabled = false

        @Option(name: .customLong("dns"), help: "DNS nameserver IP address")
        public var dnsNameservers: [String] = []

        @Option(name: .customLong("dns-domain"), help: "Default DNS domain")
        public var dnsDomain: String? = nil

        @Option(name: .customLong("dns-search"), help: "DNS search domains")
        public var dnsSearchDomains: [String] = []

        @Option(name: .customLong("dns-option"), help: "DNS options")
        public var dnsOptions: [String] = []

        @Option(name: [.customLong("label"), .customShort("l")], help: "Add a key=value label to the container")
        public var labels: [String] = []
    }

    public struct Progress: ParsableArguments {
        public init() {}

        public init(disableProgressUpdates: Bool) {
            self.disableProgressUpdates = disableProgressUpdates
        }

        @Flag(name: .customLong("disable-progress-updates"), help: "Disable progress bar updates")
        public var disableProgressUpdates = false
    }
}
