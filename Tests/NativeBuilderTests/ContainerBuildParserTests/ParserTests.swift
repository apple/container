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

import ContainerBuildIR
import Foundation
import Testing

@testable import ContainerBuildParser

@Suite class ParserTest {
    @Test func testSimpleDockerfile() throws {
        let imageRef = ImageReference(parsing: "alpine:latest")
        #expect(imageRef != nil, "Failed to parse image reference")
        let dockerfile =
            #"""
            FROM alpine:latest AS build
            """#
        let parser = DockerfileParser()
        let actualGraph = try parser.parse(dockerfile)

        // check the image reference
        #expect(!actualGraph.stages.isEmpty)
        #expect(actualGraph.stages.count == 1, "expected 1 stage, instead got \(actualGraph.stages.count)")
        #expect(actualGraph.stages[0].name == "build", "expected stage name build, got \(actualGraph.stages[0].name)")
    }

    @Test func testSimpleDockerfileLowercase() throws {
        let imageRef = ImageReference(parsing: "alpine:latest")
        #expect(imageRef != nil, "Failed to parse image reference")
        let dockerfile =
            #"""
            from alpine:latest as base
            """#
        let parser = DockerfileParser()
        let actualGraph = try parser.parse(dockerfile)

        // check the image reference
        #expect(!actualGraph.stages.isEmpty)
        #expect(actualGraph.stages.count == 1, "expected 1 stage, instead got \(actualGraph.stages.count)")
        #expect(actualGraph.stages[0].name == "base", "expected stage name build, got \(actualGraph.stages[0].name)")
    }

    @Test func testDockerfileWithContinuation() throws {
        let imageRef = ImageReference(parsing: "alpine:latest")
        #expect(imageRef != nil, "Failed to parse image reference")
        let dockerfile =
            #"""
            FROM alpine:latest \
                AS \        
                build
            """#
        let parser = DockerfileParser()
        let actualGraph = try parser.parse(dockerfile)

        // check the image reference
        #expect(!actualGraph.stages.isEmpty)
        #expect(actualGraph.stages.count == 1, "expected 1 stage, instead got \(actualGraph.stages.count)")
        #expect(actualGraph.stages[0].name == "build", "expected stage name build, got \(actualGraph.stages[0].name)")
    }

    static let invalidDockerfileFROM: [String] = [
        #"""
        FROM alpine:latest build
        """#,
        #"FROM alpine:latest build"#,
        #"FROM alpine:latest AS"#,
        #"FROM AS alpine:latest"#,
        #"FROM "" AS build"#,
        #"FROM"#,
        #"""
        FROM alpine:latest \
            build
        """#,
    ]

    @Test("Invalid FROM instruction throws ParseError", arguments: invalidDockerfileFROM)
    func invalidFromDockerfile(_ dockerfile: String) throws {
        let parser = DockerfileParser()
        #expect(throws: ParseError.self) {
            try parser.parse(dockerfile)
        }
    }

    @Test func testSimpleDockerfileWithCopy() throws {
        let imageRef = ImageReference(parsing: "alpine:latest")
        #expect(imageRef != nil, "Failed to parse image reference")
        let dockerfile =
            #"""
            FROM alpine AS build-context

            FROM alpine AS stage-two
            COPY --from=build-context /test /test
            """#
        let parser = DockerfileParser()
        let actualGraph = try parser.parse(dockerfile)

        #expect(!actualGraph.stages.isEmpty)
        let stages = actualGraph.stages

        #expect(stages.count == 2, "expected 2 stages, instead got \(stages.count)")
        #expect(stages[0].name == "build-context", "expected stage name build-context, got \(stages[0].name)")
        #expect(stages[1].name == "stage-two", "expected stage name stage-two, got \(stages[1].name)")
        #expect(stages[1].nodes.count == 1, "expected 1 node, instead got \(stages[1].nodes.count)")

        let node = stages[1].nodes[0]
        #expect(node.operation is FilesystemOperation)

        let copy = node.operation as! FilesystemOperation
        #expect(copy.action == .copy)
    }

    @Test func testSimpleDockerfileRun() throws {
        let imageRef = ImageReference(parsing: "alpine:latest")
        #expect(imageRef != nil, "Failed to parse image reference")
        let dockerfile =
            #"""
            FROM alpine:latest AS build

            RUN ["ls", "-la"]
            """#
        let parser = DockerfileParser()
        let actualGraph = try parser.parse(dockerfile)

        #expect(!actualGraph.stages.isEmpty)

        let stages = actualGraph.stages
        #expect(stages.count == 1, "expected 1 stage, instead got \(actualGraph.stages.count)")

        let stage = stages[0]
        #expect(stage.nodes.count == 1, "expected 1 node, instead got \(stage.nodes.count)")

        let run = stage.nodes[0].operation as! ExecOperation
        #expect(run.command.displayString == "ls -la")
    }

    @Test func testSimpleDockerfileRunShell() throws {
        let imageRef = ImageReference(parsing: "alpine:latest")
        #expect(imageRef != nil, "Failed to parse image reference")
        let dockerfile =
            #"""
            FROM alpine:latest AS build

            RUN build.sh --verbose
            """#
        let parser = DockerfileParser()
        let actualGraph = try parser.parse(dockerfile)

        #expect(!actualGraph.stages.isEmpty)

        let stages = actualGraph.stages
        #expect(stages.count == 1, "expected 1 stage, instead got \(actualGraph.stages.count)")

        let stage = stages[0]
        #expect(stage.nodes.count == 1, "expected 1 node, instead got \(stage.nodes.count)")

        let run = stage.nodes[0].operation as! ExecOperation
        #expect(run.command.displayString == "build.sh --verbose")

    }

    @Test func testSimpleDockerfileLabel() throws {
        let imageRef = ImageReference(parsing: "alpine:latest")
        #expect(imageRef != nil, "Failed to parse image reference")
        let dockerfile =
            #"""
            FROM alpine:latest AS build

            LABEL label1=value1
            """#
        let parser = DockerfileParser()
        let actualGraph = try parser.parse(dockerfile)

        #expect(!actualGraph.stages.isEmpty)

        let stages = actualGraph.stages
        #expect(stages.count == 1, "expected 1 stage, instead got \(actualGraph.stages.count)")

        let stage = stages[0]
        #expect(stage.nodes.count == 1, "expected 1 node, instead got \(stage.nodes.count)")

        let label = stage.nodes[0].operation as! MetadataOperation
        #expect(label.action == .setLabelBatch(["label1": "value1"]))
    }

    @Test func testSimpleDockerfileCMD() throws {
        let imageRef = ImageReference(parsing: "alpine:latest")
        #expect(imageRef != nil, "Failed to parse image reference")
        let dockerfile =
            #"""
            FROM alpine:latest AS build

            CMD ["./test.sh", "--verbose"]
            """#
        let parser = DockerfileParser()
        let actualGraph = try parser.parse(dockerfile)

        #expect(!actualGraph.stages.isEmpty)

        let stages = actualGraph.stages
        #expect(stages.count == 1, "expected 1 stage, instead got \(actualGraph.stages.count)")

        let stage = stages[0]
        #expect(stage.nodes.count == 1, "expected 1 node, instead got \(stage.nodes.count)")

        let cmd = stage.nodes[0].operation as! MetadataOperation
        switch cmd.action {
        case .setCmd(let command):
            #expect(command.displayString == "./test.sh --verbose")
        default:
            Issue.record("expected .setCmd action type, instead got \(cmd.action)")
            return
        }
    }
}

// tests for parsing options for the different instructions
extension ParserTest {
    struct RunMountTestCase {
        let rawMount: String
        let expectedRunMount: RunMount?

        init(rawMount: String, expectedRunMount: RunMount? = nil) {
            self.rawMount = rawMount
            self.expectedRunMount = expectedRunMount
        }
    }

    static let runMountTestCases = [
        // bind
        // basic bind mount with different target option names
        RunMountTestCase(
            rawMount: "type=bind,dst=/container/dst",
            expectedRunMount: RunMount(type: .bind, source: "/", target: "/container/dst", options: RunMountOptions(readonly: true))
        ),
        RunMountTestCase(
            rawMount: "type=bind,target=/container/target",
            expectedRunMount: RunMount(type: .bind, source: "/", target: "/container/target", options: RunMountOptions(readonly: true))
        ),
        RunMountTestCase(
            rawMount: "type=bind,destination=/container/destination",
            expectedRunMount: RunMount(type: .bind, source: "/", target: "/container/destination", options: RunMountOptions(readonly: true))
        ),
        // defaults to bind type if none provided
        RunMountTestCase(
            rawMount: "dst=/container/dst",
            expectedRunMount: RunMount(type: .bind, source: "/", target: "/container/dst", options: RunMountOptions(readonly: true))
        ),
        // with source
        RunMountTestCase(
            rawMount: "dst=/container/dst,source=/source",
            expectedRunMount: RunMount(type: .bind, source: "/source", target: "/container/dst", options: RunMountOptions(readonly: true))
        ),
        // with from
        RunMountTestCase(
            rawMount: "dst=/container/dst,from=earlierstage",
            expectedRunMount: RunMount(type: .bind, source: "/", from: "earlierstage", target: "/container/dst", options: RunMountOptions(readonly: true))
        ),
        // with readwrite explicitly set
        RunMountTestCase(
            rawMount: "type=bind,dst=/container/dst,readwrite=true",
            expectedRunMount: RunMount(type: .bind, source: "/", target: "/container/dst", options: RunMountOptions(readonly: false))
        ),
        RunMountTestCase(
            rawMount: "type=bind,dst=/container/dst,rw=true",
            expectedRunMount: RunMount(type: .bind, source: "/", target: "/container/dst", options: RunMountOptions(readonly: false))
        ),
        RunMountTestCase(
            rawMount: "type=bind,dst=/container/dst,readwrite=false",
            expectedRunMount: RunMount(type: .bind, source: "/", target: "/container/dst", options: RunMountOptions(readonly: true))
        ),
        RunMountTestCase(
            rawMount: "type=bind,dst=/container/dst,readwrite=false",
            expectedRunMount: RunMount(type: .bind, source: "/", target: "/container/dst", options: RunMountOptions(readonly: true))
        ),

        /* Cache cases */
        // minimal valid cache
        RunMountTestCase(
            rawMount: "type=cache,target=/mycache",
            expectedRunMount: RunMount(
                type: .cache,
                source: "/",
                from: "",
                id: "/mycache",
                target: "/mycache",
                options: RunMountOptions(
                    readonly: false,
                    uid: 0,
                    gid: 0,
                    mode: 0755,
                    sharing: .shared
                )
            )
        ),
        // normal with all options
        RunMountTestCase(
            rawMount: "type=cache,id=0987087,target=/target,readonly=false,sharing=private,from=build,source=/source,mode=0,uid=0,gid=0",
            expectedRunMount: RunMount(
                type: .cache,
                source: "/source",
                from: "build",
                id: "0987087",
                target: "/target",
                options: RunMountOptions(
                    readonly: false,
                    uid: 0,
                    gid: 0,
                    mode: 0,
                    sharing: .private
                )
            )
        ),
        // cache with sharing
        RunMountTestCase(
            rawMount: "type=cache,target=/mycache,sharing=shared",
            expectedRunMount: RunMount(
                type: .cache,
                source: "/",
                from: "",
                id: "/mycache",
                target: "/mycache",
                options: RunMountOptions(
                    readonly: false,
                    uid: 0,
                    gid: 0,
                    mode: 0755,
                    sharing: .shared
                )
            )
        ),
        RunMountTestCase(
            rawMount: "type=cache,target=/mycache,sharing=private",
            expectedRunMount: RunMount(
                type: .cache,
                source: "/",
                from: "",
                id: "/mycache",
                target: "/mycache",
                options: RunMountOptions(
                    readonly: false,
                    uid: 0,
                    gid: 0,
                    mode: 0755,
                    sharing: .private
                )
            )
        ),
        RunMountTestCase(
            rawMount: "type=cache,target=/mycache,sharing=locked",
            expectedRunMount: RunMount(
                type: .cache,
                source: "/",
                from: "",
                id: "/mycache",
                target: "/mycache",
                options: RunMountOptions(
                    readonly: false,
                    uid: 0,
                    gid: 0,
                    mode: 0755,
                    sharing: .locked
                )
            )
        ),

        // readonly
        RunMountTestCase(
            rawMount: "type=cache,target=/mycache,readonly=true",
            expectedRunMount: RunMount(
                type: .cache,
                source: "/",
                from: "",
                id: "/mycache",
                target: "/mycache",
                options: RunMountOptions(
                    readonly: true,
                    uid: 0,
                    gid: 0,
                    mode: 0755,
                    sharing: .shared
                )
            )
        ),

        // cache with id, mode, uid, gid
        RunMountTestCase(
            rawMount: "type=cache,target=/cache,id=cacheid,mode=0444,uid=1001,gid=1002",
            expectedRunMount: RunMount(
                type: .cache,
                source: "/",
                from: "",
                id: "cacheid",
                target: "/cache",
                options: RunMountOptions(
                    readonly: false,
                    uid: 1001,
                    gid: 1002,
                    mode: 0444,
                    sharing: .shared
                )
            )
        ),

        /* tmpfs cases */
        // minimal tmpfs
        RunMountTestCase(
            rawMount: "type=tmpfs,target=/tmpfs",
            expectedRunMount: RunMount(
                type: .tmpfs,
                target: "/tmpfs",
                options: RunMountOptions(readonly: false)
            )
        ),

        // size
        RunMountTestCase(
            rawMount: "type=tmpfs,target=/tmpfs,size=1000",
            expectedRunMount: RunMount(
                type: .tmpfs,
                target: "/tmpfs",
                options: RunMountOptions(readonly: false, size: 1000)
            )
        ),

        /* secret cases */
        // minimal secret case
        RunMountTestCase(
            rawMount: "type=secret,target=/run/secrets/mysecret",
            expectedRunMount: RunMount(
                type: .secret,
                id: "mysecret",
                target: "/run/secrets/mysecret",
                options: RunMountOptions(
                    readonly: true,
                    required: false,
                    uid: 0,
                    gid: 0,
                    mode: 0400,
                )
            )
        ),

        // secret with id
        RunMountTestCase(
            rawMount: "type=secret,id=mysecret,target=/run/secrets/mysecret",
            expectedRunMount: RunMount(
                type: .secret,
                id: "mysecret",
                target: "/run/secrets/mysecret",
                options: RunMountOptions(
                    readonly: true,
                    required: false,
                    uid: 0,
                    gid: 0,
                    mode: 0400,
                )
            )
        ),

        // secret using env
        RunMountTestCase(
            rawMount: "type=secret,id=mysecret,target=/run/secrets/mysecret,env=TEST",
            expectedRunMount: RunMount(
                type: .secret,
                id: "mysecret",
                env: "TEST",
                target: "/run/secrets/mysecret",
                options: RunMountOptions(
                    readonly: true,
                    required: false,
                    uid: 0,
                    gid: 0,
                    mode: 0400,
                )
            )
        ),

        // secret with required, uid/gid/mode
        RunMountTestCase(
            rawMount: "type=secret,id=mysecret,target=/run/secrets/mysecret,required=true,uid=1000,gid=1001,mode=0400",
            expectedRunMount: RunMount(
                type: .secret,
                id: "mysecret",
                target: "/run/secrets/mysecret",
                options: RunMountOptions(
                    readonly: true,
                    required: true,
                    uid: 1000,
                    gid: 1001,
                    mode: 0400
                )
            )
        ),

        /* ssh cases */
        // minimal ssh mount
        RunMountTestCase(
            rawMount: "type=ssh",
            expectedRunMount: RunMount(
                type: .ssh,
                id: "default",
                target: "/run/buildkit/ssh_agent",
                options: RunMountOptions(
                    readonly: true,
                    required: false,
                    uid: 0,
                    gid: 0,
                    mode: 0600
                )
            )
        ),

        // ssh with id
        RunMountTestCase(
            rawMount: "type=ssh,id=myssh,target=/run/ssh",
            expectedRunMount: RunMount(
                type: .ssh,
                id: "myssh",
                target: "/run/ssh",
                options: RunMountOptions(
                    readonly: true,
                    required: false,
                    uid: 0,
                    gid: 0,
                    mode: 0600
                )
            )
        ),

        // ssh with required and id
        RunMountTestCase(
            rawMount: "type=ssh,id=deploykey,target=/run/ssh,required=true",
            expectedRunMount: RunMount(
                type: .ssh,
                id: "deploykey",
                target: "/run/ssh",
                options: RunMountOptions(
                    readonly: true,
                    required: true,
                    uid: 0,
                    gid: 0,
                    mode: 0600
                )
            )
        ),
    ]

    @Test("Run mounts are parsed correctly", arguments: runMountTestCases)
    func runParseMount(_ testCase: RunMountTestCase) throws {
        let actual = try RunInstruction.parseMount(testCase.rawMount)
        #expect(actual == testCase.expectedRunMount)
    }

    static let invalidRunMounts: [String] = [
        /* Common cases */
        // missing or mispelled
        "type=",
        "tyep=bind,target=/container",
        "type=bind,targte=/container",

        // duplicate keys
        "type=bind,target=/one,target=/two",
        "type=bind,dst=/one,destination=/two",
        "type=bind,readwrite=true,readwrite=false",

        /* Bind cases */
        // missing or empty values
        "type=bind",
        "type=bind,target=",
        "type=bind,destination",

        // invalid readwrite
        "type=bind,target=/target,rw=Not false",
        "type=bind,destination=/destination,rw=Totally false",
        "type=bind,target=/target,readwrite=yes",
        "type=bind,destination=/destination,readwrite=0",

        // malformed key-value format
        "type=bind,target=/container,readwrite",
        "type=bind,target=/container,readwrite==true",
        "type=bind,target=/container,=true",
        "type=bind,=true,target=/container",

        // uses options that bind does not support
        "type=bind,destination=/destination,mode=0",
        "type=bind,target=/destination,gid=0",
        "type=bind,dst=/destination,uid=0",
        "type=bind,destination=/destination,sharing=private",
        "type=bind,target=/destination,required=true",
        "type=bind,dst=/destination,size=10",
        "type=bind,target=/destination,id=780707",
        "type=bind,destination=/destination,env=TEST",

        // uses options that do not exist
        "type=bind,target=/target,foo=bar",
        "type=bind,target=/target,readwrite=true,invalid-key=value",

        /* Cache cases */
        // missing required target
        "type=cache",
        "type=cache,target=",
        "type=cache,destination",

        // invalid readonly
        "type=cache,target=/cache,readonly=",
        "type=cache,target=/cache,readonly=Totally",
        "type=cache,target=/cache,ro=Forsure",

        // invalid sharing type
        "type=cache,target=/cache,sharing=cache",
        "type=cache,target=/cache,sharing=none",

        // invalid mode,uid, or gid
        "type=cache,target=/cache,mode=-0777",
        "type=cache,target=/cache,uid=-1001",
        "type=cache,target=/cache,gid=-100",

        // unsupported options
        "type=cache,target=/cache,env=TEST",
        "type=cache,target=/cache,required=true",

        /* tmpfs cases */
        // tmpfs missing target
        "type=tmpfs",
        "type=tmpfs,target=",
        "type=tmpfs,dst",

        // invalid size
        "type=tmpfs,target=/tmpfs,size=",
        "type=tmpfs,target=/tmpfs,size=abc",
        "type=tmpfs,target=/tmpfs,size=-100",
        "type=tmpfs,target=/tmpfs,size=1.5",

        // unsupported options
        "type=tmpfs,target=/tmpfs,mode=0755",
        "type=tmpfs,target=/tmpfs,uid=0",
        "type=tmpfs,target=/tmpfs,gid=0",
        "type=tmpfs,target=/tmpfs,id=myid",
        "type=tmpfs,target=/tmpfs,from=build",
        "type=tmpfs,target=/tmpfs,env=TEST",
        "type=tmpfs,target=/tmpfs,required=true",
        "type=tmpfs,target=/tmpfs,sharing=private",

        /* secret cases */
        // invalid mode, uid, gid
        "type=secret,target=/secret,mode=-0777",
        "type=secret,target=/secret,uid=-1001",
        "type=secret,target=/secret,gid=-100",

        // missing a target, env, AND id
        "type=secret,readonly=true",

        // env set but no target or id
        "type=secret,env=TEST,readonly=true",

        // unsupported options
        "type=secret,target=/secret,from=build",
        "type=secret,target=/secret,source=/",
        "type=secret,target=/secret,sharing=private",

        /* ssh cases */
        // invalid mode,uid,gid
        "type=ssh,mode=-0755",
        "type=ssh,uid=-079",
        "type=ssh,gid=",

        // unsupported options
        "type=ssh,target=/ssh,from=build",
        "type=ssh,target=/ssh,source=/",
        "type=ssh,target=/ssh,env=SSH_TEST",
        "type=ssh,target=/ssh,sharing=private",
    ]

    @Test("Invalid run mount configuration throws error", arguments: invalidRunMounts)
    func testInvalidRunMounts(_ testCase: String) throws {
        #expect(throws: ParseError.self) {
            let _ = try RunInstruction.parseMount(testCase)
        }
    }

    struct RunNetworkTest {
        let rawNetwork: String?
        let expectedNetwork: NetworkMode?

        init(rawNetwork: String?, expectedNetwork: NetworkMode? = nil) {
            self.rawNetwork = rawNetwork
            self.expectedNetwork = expectedNetwork
        }
    }

    static let runNetworkTests: [RunNetworkTest] = [
        RunNetworkTest(rawNetwork: "default", expectedNetwork: .default),
        RunNetworkTest(rawNetwork: "none", expectedNetwork: NetworkMode.none),
        RunNetworkTest(rawNetwork: "host", expectedNetwork: .host),
        RunNetworkTest(rawNetwork: nil, expectedNetwork: .default),
    ]

    @Test("Successful run network parsing", arguments: runNetworkTests)
    func runNetworkParseTest(_ testCase: RunNetworkTest) throws {
        let actual = try RunInstruction.parseNetworkMode(mode: testCase.rawNetwork)
        #expect(actual == testCase.expectedNetwork)
    }

    @Test func invalidNetworkParse() throws {
        let invalidMode = "fake"
        #expect(throws: ParseError.self) {
            let _ = try RunInstruction.parseNetworkMode(mode: invalidMode)
        }
    }

    struct CopyOwnershipTest {
        let rawOwnership: String?
        let expectedOwnership: Ownership?
    }

    static let copyOwnershipTests = [
        CopyOwnershipTest(
            rawOwnership: "55:mygroup",
            expectedOwnership: Ownership(user: .numeric(id: 55), group: .named(id: "mygroup"))
        ),
        CopyOwnershipTest(
            rawOwnership: "bin",
            expectedOwnership: Ownership(user: .named(id: "bin"), group: nil)
        ),
        CopyOwnershipTest(
            rawOwnership: "1",
            expectedOwnership: Ownership(user: .numeric(id: 1), group: nil)
        ),
        CopyOwnershipTest(
            rawOwnership: "10:11",
            expectedOwnership: Ownership(user: .numeric(id: 10), group: .numeric(id: 11))
        ),
        CopyOwnershipTest(
            rawOwnership: "myuser:mygroup",
            expectedOwnership: Ownership(user: .named(id: "myuser"), group: .named(id: "mygroup"))
        ),
        CopyOwnershipTest(
            rawOwnership: "",
            expectedOwnership: Ownership(user: .numeric(id: 0), group: .numeric(id: 0))
        ),
        CopyOwnershipTest(
            rawOwnership: nil,
            expectedOwnership: Ownership(user: .numeric(id: 0), group: .numeric(id: 0))
        ),
        CopyOwnershipTest(
            rawOwnership: ":mygroup",
            expectedOwnership: Ownership(user: nil, group: .named(id: "mygroup"))
        ),
    ]

    @Test("Expected parsing of chown options", arguments: copyOwnershipTests)
    func testCopyParseOwnership(_ testcase: CopyOwnershipTest) throws {
        let actual = try CopyInstruction.parseOwnership(input: testcase.rawOwnership)
        #expect(actual == testcase.expectedOwnership)
    }

    @Test func testCopyParseOwnershipInvalid() throws {
        let rawInput = "myuser:mygroup:extra"
        #expect(throws: ParseError.self) {
            let _ = try CopyInstruction.parseOwnership(input: rawInput)
        }
    }

    @Test func testCopyParsePermissions() throws {
        let rawPermission = "777"
        let actual = try CopyInstruction.parsePermissions(input: rawPermission)
        #expect(actual == .mode(777))
    }

    @Test func testCopyParsePermissionsInvalid() throws {
        let rawPermission = "u+x"
        #expect(throws: ParseError.self) {
            let _ = try CopyInstruction.parsePermissions(input: rawPermission)
        }
    }
}
