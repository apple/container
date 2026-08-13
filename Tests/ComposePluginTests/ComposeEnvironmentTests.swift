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
import Testing

@testable import ContainerCompose

@Suite("Compose environment")
struct ComposeEnvironmentTests {
    @Test
    func hostSSHAgentIsNotForwardedToComposeEnvironment() throws {
        let environment = try ComposeEnvironment.make(
            hostEnvironment: [
                "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
                "GIT_SSH_COMMAND": "ssh -A",
                "PATH": "/host/bin",
            ],
            homeDirectory: FilePath("/Users/tester"),
            workingDirectory: FilePath("/Users/tester/project")
        )
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["GIT_SSH_COMMAND"] == nil)
        #expect(environment["PATH"] != "/host/bin")
    }

    @Test
    func reservedOptionsAreClassifiedWithoutParsingCompose() {
        #expect(ComposeInvocation.reservedOption(in: ["up", "--socket-path"]) == .socketPath)
        #expect(ComposeInvocation.reservedOption(in: ["up", "--completions=bash"]) == .completions)
        #expect(ComposeInvocation.reservedOption(in: ["run", "--", "--socket-path"]) == nil)
        #expect(ComposeInvocation.reservedOption(in: ["up", "--file", "compose.yaml"]) == nil)
    }

    @Test
    func forwardedHelpIsDetectedBeforeComposePassthroughArguments() {
        #expect(ComposeInvocation.requestsHelp(in: ["up", "--help"]))
        #expect(ComposeInvocation.requestsHelp(in: ["config", "-h"]))
        #expect(!ComposeInvocation.requestsHelp(in: ["run", "api", "--", "--help"]))
        #expect(!ComposeInvocation.requestsHelp(in: ["up", "--help=verbose"]))
    }

    @Test
    func forwardedHelpUsesContainerComposeName() {
        let output = "Usage:  docker compose up [OPTIONS] [SERVICE ...]"

        #expect(
            ComposeHelpOutput.rewrite(output)
                == "Usage:  container compose up [OPTIONS] [SERVICE ...]"
        )
    }

    @Test
    func composeHelpUsesHostCommandAndSubcommandArgument() {
        #expect(
            ComposeCommand.usageString(for: ComposeCommand.self)
                == "container compose [--completions <bash|zsh|fish> | --socket-path | <subcommand> ...]"
        )
    }

    @Test
    func helpOutputRewritesOnlyDockerComposeInvocation() {
        let output = "docker compose up\ncompose uses docker compose internally\n"

        #expect(
            ComposeHelpOutput.rewrite(output)
                == "container compose up\ncompose uses container compose internally\n"
        )
    }

    @Test
    func socketEndpointIsPureAndStable() {
        let endpoint = ComposeSocketEndpoint(homeDirectory: FilePath("/Users/tester"))

        #expect(endpoint.path == FilePath("/Users/tester/.local/run/docker.socket"))
        #expect(endpoint.dockerHost == "unix:///Users/tester/.local/run/docker.socket")
    }

    @Test
    func workingDirectoryMustBeVisibleInMachine() throws {
        let cwd = try ComposeEnvironment.workingDirectory(
            currentDirectory: FilePath("/Users/tester/project"),
            homeDirectory: FilePath("/Users/tester")
        )

        #expect(cwd == "/Users/tester/project")
    }

    @Test
    func workingDirectoryOutsideHomeIsRejected() {
        #expect(throws: ContainerizationError.self) {
            try ComposeEnvironment.workingDirectory(
                currentDirectory: FilePath("/private/tmp/project"),
                homeDirectory: FilePath("/Users/tester")
            )
        }
    }

    @Test
    func environmentUsesInnerDockerEndpointAndPreservesComposeValues() throws {
        let environment = try ComposeEnvironment.make(
            hostEnvironment: [
                "COMPOSE_PROJECT_NAME": "demo",
                "DOCKER_HOST": "unix:///host/docker.sock",
                "DOCKER_CONTEXT": "desktop-linux",
                "DOCKER_TLS_VERIFY": "1",
                "DOCKER_CONFIG": "/Users/tester/.docker",
                "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
                "TMPDIR": "/var/folders/host",
                "USER_SETTING": "kept",
            ],
            homeDirectory: FilePath("/Users/tester"),
            workingDirectory: FilePath("/Users/tester/project")
        )

        #expect(environment["COMPOSE_PROJECT_NAME"] == "demo")
        #expect(environment["USER_SETTING"] == "kept")
        #expect(environment["DOCKER_HOST"] == "unix:///etc/docker/docker.sock")
        #expect(environment["DOCKER_CONTEXT"] == nil)
        #expect(environment["DOCKER_TLS_VERIFY"] == nil)
        #expect(environment["DOCKER_CONFIG"] == "/root/.docker")
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["TMPDIR"] == "/tmp")
        #expect(environment["HOME"] == "/Users/tester")
        #expect(environment["PWD"] == "/Users/tester/project")
    }
}
