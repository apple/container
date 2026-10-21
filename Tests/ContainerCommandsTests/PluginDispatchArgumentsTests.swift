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

import Testing

@testable import ContainerCommands

/// Regression coverage for https://github.com/apple/container/issues/1936.
///
/// `Application` no longer relies on ArgumentParser's `defaultSubcommand`
/// mechanism to route unrecognized input to `DefaultCommand` (plugin
/// dispatch), because combining `defaultSubcommand` with a
/// `.captureForPassthrough` argument breaks flag parsing for legitimately
/// matched subcommands throughout the whole tree (e.g. `container system
/// status --debug` would fail with "Unknown option '--debug'"). Instead,
/// `Application.pluginDispatchArguments` decides up front whether input
/// should go to `DefaultCommand`.
struct PluginDispatchArgumentsTests {
    @Test
    func knownSubcommandIsNotTreatedAsPluginDispatch() {
        #expect(Application.pluginDispatchArguments(["system", "status", "--debug"]) == nil)
        #expect(Application.pluginDispatchArguments(["s", "status", "--debug"]) == nil)
        #expect(Application.pluginDispatchArguments(["image", "list"]) == nil)
        #expect(Application.pluginDispatchArguments(["list"]) == nil)
        #expect(Application.pluginDispatchArguments(["help"]) == nil)
    }

    @Test
    func helpAndVersionAreNotTreatedAsPluginDispatch() {
        #expect(Application.pluginDispatchArguments(["--help"]) == nil)
        #expect(Application.pluginDispatchArguments(["-h"]) == nil)
        #expect(Application.pluginDispatchArguments(["--version"]) == nil)
    }

    @Test
    func unrecognizedTopLevelWordIsPluginDispatch() {
        guard let dispatch = Application.pluginDispatchArguments(["some-plugin", "arg1", "--flag"]) else {
            Issue.record("expected plugin dispatch for an unrecognized subcommand")
            return
        }
        #expect(dispatch.logOptions.debug == false)
        #expect(dispatch.remaining == ["some-plugin", "arg1", "--flag"])
    }

    @Test
    func leadingDebugFlagIsConsumedBeforePluginDispatch() {
        guard let dispatch = Application.pluginDispatchArguments(["--debug", "some-plugin", "arg1"]) else {
            Issue.record("expected plugin dispatch")
            return
        }
        #expect(dispatch.logOptions.debug == true)
        #expect(dispatch.remaining == ["some-plugin", "arg1"])
    }

    @Test
    func pluginsOwnDebugFlagIsPassedThroughUnchanged() {
        // A plugin that accepts its own `--debug` flag must receive it
        // verbatim, rather than having it stolen by `container`'s own
        // global `--debug` flag.
        guard let dispatch = Application.pluginDispatchArguments(["some-plugin", "--debug"]) else {
            Issue.record("expected plugin dispatch")
            return
        }
        #expect(dispatch.logOptions.debug == false)
        #expect(dispatch.remaining == ["some-plugin", "--debug"])
    }

    @Test
    func bareAndDebugOnlyInvocationsDispatchWithEmptyRemaining() {
        guard let bare = Application.pluginDispatchArguments([]) else {
            Issue.record("expected dispatch for bare invocation")
            return
        }
        #expect(bare.remaining.isEmpty)

        guard let debugOnly = Application.pluginDispatchArguments(["--debug"]) else {
            Issue.record("expected dispatch for --debug-only invocation")
            return
        }
        #expect(debugOnly.logOptions.debug == true)
        #expect(debugOnly.remaining.isEmpty)
    }
}
