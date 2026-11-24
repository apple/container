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

import ContainerPlugin
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

struct RuntimeCleanupHookTests {
    private static func script(_ body: String) throws -> (plugin: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-hook-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("plugin")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, dir)
    }

    private static func plugin(_ url: URL) -> Plugin {
        Plugin(binaryURL: url, config: PluginConfig(abstract: "test", author: nil, servicesConfig: nil))
    }

    private static func pid(in dir: URL, file: String) throws -> pid_t {
        let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
        return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    // An orphaned child is reaped by launchd asynchronously, so poll.
    private static func isGone(_ pid: pid_t) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH {
                return true
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test
    func passesCleanupArgumentsAndReportsSuccess() async throws {
        let (plugin, dir) = try Self.script(#"echo "$@" > "$(dirname "$0")/args""#)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(
            await RuntimeCleanupHook.run(
                plugin: Self.plugin(plugin), root: URL(fileURLWithPath: "/bundles/abc"), id: "abc", log: Logger(label: "test"), timeout: .seconds(5)))

        let args = try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
        #expect(args.trimmingCharacters(in: .whitespacesAndNewlines) == "cleanup --root /bundles/abc --uuid abc")
    }

    @Test
    func reportsNonZeroExit() async throws {
        let (plugin, dir) = try Self.script("exit 3")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await !RuntimeCleanupHook.run(plugin: Self.plugin(plugin), root: dir, id: "abc", log: Logger(label: "test"), timeout: .seconds(5)))
    }

    @Test
    func reportsUnimplementedCleanup() async throws {
        let (plugin, dir) = try Self.script("exit \(EX_USAGE)")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await !RuntimeCleanupHook.run(plugin: Self.plugin(plugin), root: dir, id: "abc", log: Logger(label: "test"), timeout: .seconds(5)))
    }

    @Test
    func killsAHungPlugin() async throws {
        let (plugin, dir) = try Self.script(#"echo $$ > "$(dirname "$0")/pid"; trap '' TERM; sleep 30"#)
        defer { try? FileManager.default.removeItem(at: dir) }

        let start = ContinuousClock.now
        #expect(await !RuntimeCleanupHook.run(plugin: Self.plugin(plugin), root: dir, id: "abc", log: Logger(label: "test"), timeout: .milliseconds(300)))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(try await Self.isGone(Self.pid(in: dir, file: "pid")))
    }

    @Test
    func killsThePluginsChildren() async throws {
        let (plugin, dir) = try Self.script(#"sleep 30 & echo $! > "$(dirname "$0")/child"; wait"#)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await !RuntimeCleanupHook.run(plugin: Self.plugin(plugin), root: dir, id: "abc", log: Logger(label: "test"), timeout: .milliseconds(300)))
        #expect(try await Self.isGone(Self.pid(in: dir, file: "child")))
    }

    @Test
    func reportsMissingExecutable() async {
        let plugin = Self.plugin(URL(fileURLWithPath: "/nonexistent/plugin"))
        #expect(await !RuntimeCleanupHook.run(plugin: plugin, root: URL(fileURLWithPath: "/tmp"), id: "abc", log: Logger(label: "test"), timeout: .seconds(1)))
    }
}
