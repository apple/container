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

import ContainerizationError
import Foundation
import SystemPackage

/// Host-to-machine path and environment policy for the Compose process.
enum ComposeEnvironment {
    static let innerDockerHost = "unix:///etc/docker/docker.sock"
    private static let linuxPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    static func workingDirectory(
        currentDirectory: FilePath,
        homeDirectory: FilePath
    ) throws -> String {
        let home = homeDirectory.lexicallyNormalized()
        let current = currentDirectory.lexicallyNormalized()
        guard current == home || current.starts(with: home) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Compose working directory \(current) is outside the mounted host home \(home)"
            )
        }
        return current.string
    }

    static func make(
        hostEnvironment: [String: String],
        homeDirectory: FilePath,
        workingDirectory: FilePath
    ) throws -> [String: String] {
        let cwd = try self.workingDirectory(
            currentDirectory: workingDirectory,
            homeDirectory: homeDirectory
        )

        var environment = hostEnvironment
        for key in [
            "DOCKER_HOST",
            "DOCKER_CONTEXT",
            "DOCKER_TLS_VERIFY",
            "DOCKER_CERT_PATH",
            "DOCKER_CONFIG",
            "SSH_AUTH_SOCK",
            "GIT_SSH_COMMAND",
            "HOME",
            "PATH",
            "PWD",
            "OLDPWD",
            "TMPDIR",
            "TMP",
            "TEMP",
        ] {
            environment.removeValue(forKey: key)
        }

        environment["DOCKER_HOST"] = Self.innerDockerHost
        // Do not reuse a host Docker config that names macOS-only credential
        // helpers. Users can authenticate explicitly inside the machine, or
        // supply DOCKER_AUTH_CONFIG for non-interactive registry access.
        environment["DOCKER_CONFIG"] = "/root/.docker"
        environment["HOME"] = homeDirectory.lexicallyNormalized().string
        // The machine container deliberately runs Compose as root so the
        // nested daemon can manage its own containers. Do not pass the host
        // SSH agent into that rootful trust domain.
        environment.removeValue(forKey: "GIT_SSH_COMMAND")
        environment["PATH"] = Self.linuxPath
        environment["PWD"] = cwd
        environment["TMPDIR"] = "/tmp"
        environment["TMP"] = "/tmp"
        environment["TEMP"] = "/tmp"

        return environment
    }
}
