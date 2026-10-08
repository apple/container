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

import ContainerTestSupport
import Containerization
import Foundation
import Testing

@Suite
struct TestCLIRunSecurityPaths {
    private let alpine = WarmupImage.alpine320

    /// Mount points inside the container. A masked file is a bind mount of
    /// /dev/null, a masked directory is a tmpfs, and a read-only path is a bind
    /// mount of itself, so every applied path appears here.
    private func mountPoints(_ f: ContainerFixture, _ c: String) throws -> Set<String> {
        let mounts = try f.doExec(c, cmd: ["cat", "/proc/mounts"])
        return Set(
            mounts.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: " ")
                return fields.count > 1 ? String(fields[1]) : nil
            })
    }

    // Whether an individual default path is applied depends on the guest kernel.
    // To make the tests independent of the kernel and its config,
    // our assertions should only claim that a default set is entirely
    // absent, or that at least some of it is present. We don't check for a particular path.
    private var maskedDefaults: Set<String> { Set(LinuxContainer.defaultMaskedPaths()) }
    private var readonlyDefaults: Set<String> { Set(LinuxContainer.defaultReadonlyPaths()) }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Invalid paths

    @Test func testRelativePathsRejected() async throws {
        try await ContainerFixture.with { f in
            let masked = try f.run(["run", "--rm", "--masked-path", "proc/kcore", alpine.rawValue, "true"])
            #expect(masked.status != 0)
            #expect(masked.error.contains("proc/kcore"))

            let readonly = try f.run(["run", "--rm", "--read-only-path", "proc/sys", alpine.rawValue, "true"])
            #expect(readonly.status != 0)
            #expect(readonly.error.contains("proc/sys"))
        }
    }

    // MARK: - Runtime defaults

    @Test func testNoFlagsUsesRuntimeDefaults() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            try await f.doLongRun(name: c, image: alpine.rawValue, autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            // Absent from the stored config, so the runtime applies its defaults.
            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.maskedPaths == nil)
            #expect(inspect.configuration.readonlyPaths == nil)

            // At least one read-only default is always applied (/proc/sys and
            // friends exist on every kernel); the masked set is kernel-dependent,
            // so masking behavior is asserted on a path the image guarantees in
            // testCustomPathsAppendToDefaults instead.
            let mounted = try mountPoints(f, c)
            #expect(!mounted.isDisjoint(with: readonlyDefaults))
        }
    }

    // MARK: - Paths added on top of the defaults

    @Test func testCustomPathsAppendToDefaults() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            try await f.doLongRun(
                name: c, image: alpine.rawValue,
                args: ["--masked-path", "/etc/alpine-release", "--read-only-path", "/tmp"],
                autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.maskedPaths == LinuxContainer.defaultMaskedPaths() + ["/etc/alpine-release"])
            #expect(inspect.configuration.readonlyPaths == LinuxContainer.defaultReadonlyPaths() + ["/tmp"])

            // The custom masked file reads as empty and the custom read-only
            // directory rejects writes.
            #expect(trimmed(try f.doExec(c, cmd: ["sh", "-c", "wc -c < /etc/alpine-release"])) == "0")
            let write = try f.run(["exec", c, "sh", "-c", "touch /tmp/nope && echo WROTE"])
            #expect(write.status != 0)
            #expect(trimmed(write.output) != "WROTE")

            // The defaults are still applied alongside them.
            let mounted = try mountPoints(f, c)
            #expect(mounted.contains("/etc/alpine-release"))
            #expect(mounted.contains("/tmp"))
            #expect(!mounted.isDisjoint(with: readonlyDefaults))
        }
    }

    // MARK: - NONE sentinel

    @Test func testMaskedPathNoneClearsOnlyMaskedDefaults() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            try await f.doLongRun(
                name: c, image: alpine.rawValue,
                args: ["--masked-path", "NONE"], autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.maskedPaths == [])
            #expect(inspect.configuration.readonlyPaths == nil)

            // An empty list reaches the runtime as "mask nothing", and leaves the
            // read-only defaults alone.
            let mounted = try mountPoints(f, c)
            #expect(mounted.isDisjoint(with: maskedDefaults))
            #expect(!mounted.isDisjoint(with: readonlyDefaults))
        }
    }

    @Test func testReadOnlyPathNoneClearsOnlyReadOnlyDefaults() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            try await f.doLongRun(
                name: c, image: alpine.rawValue,
                args: ["--read-only-path", "NONE", "--masked-path", "/etc/alpine-release"],
                autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.readonlyPaths == [])
            #expect(inspect.configuration.maskedPaths == LinuxContainer.defaultMaskedPaths() + ["/etc/alpine-release"])

            // Nothing is read-only, while masking still works — the sentinel
            // applies only to the flag it was passed to.
            let mounted = try mountPoints(f, c)
            #expect(mounted.isDisjoint(with: readonlyDefaults))
            #expect(trimmed(try f.doExec(c, cmd: ["sh", "-c", "wc -c < /etc/alpine-release"])) == "0")
        }
    }
}
