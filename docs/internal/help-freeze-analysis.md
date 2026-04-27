# `container --help` freeze — root cause analysis

> Status: investigation document for the fix proposed in this PR. Reviewers — please critique the reasoning below; the patches in this PR are the smallest changes that follow from it.

## Reproduction

On a system where `com.apple.container.apiserver` is dead, wedged, or stale-registered in launchd:

```bash
container --help     # hangs indefinitely (not bounded by any visible timeout)
container help       # hangs indefinitely
container            # hangs indefinitely
```

This matches the symptom pattern in [#1329](https://github.com/apple/container/issues/1329), [#798](https://github.com/apple/container/issues/798), and [#621](https://github.com/apple/container/issues/621), which all describe XPC handshake hangs against `com.apple.container.apiserver` requiring `launchctl bootout` to recover.

User-visible workaround:

```bash
launchctl bootout gui/$(id -u)/com.apple.container.apiserver 2>/dev/null
launchctl bootout user/$(id -u)/com.apple.container.apiserver 2>/dev/null
container system start
```

## Root cause: there are *two* defects, not one

### Defect A — the help path requires the daemon to be reachable

`Application.main()` catches the `--help` parse signal and, before printing help, calls `createPluginLoader()` so the help text can be enriched with installed plugin commands.

```
Application.main
  └─ catch (CleanExit from --help)
      └─ createPluginLoader()                                   [Application.swift:137]
          └─ ClientHealthCheck.ping(timeout: .seconds(10))      [Application.swift:169]
              └─ XPCClient.send(... responseTimeout: 10s)       [ClientHealthCheck.swift:34]
                  └─ xpc_connection_send_message_with_reply     [XPCClient.swift:89]
                      └── waiting on com.apple.container.apiserver
```

The same pattern exists in:

| File | Line | Path |
|---|---|---|
| `Sources/ContainerCommands/Application.swift` | 121–126 | root `--help` / `-h` |
| `Sources/ContainerCommands/HelpCommand.swift` | 29–32 | `container help` subcommand |
| `Sources/ContainerCommands/DefaultCommand.swift` | 35–41 | `container` (no args) |

The intent is to enrich help text with plugin commands. The implementation reaches the daemon to fetch `appRoot/installRoot/logRoot`, even though `PluginLoader.alterCLIHelpText()` only reads `pluginDirectories` and `pluginFactories` (verifiable in `Sources/ContainerPlugin/PluginLoader.swift:70-88`, `91-176`). The daemon ping is structurally unnecessary for help rendering; it only became necessary because `PluginLoader.init` happens to take roots that `alterCLIHelpText` does not use.

### Defect B — `XPCClient.send`'s timeout cannot actually unblock the function

This is the reason the hang is *indefinite* rather than the 10 seconds suggested by the call site.

```swift
// Sources/ContainerXPC/XPCClient.swift:74-112
public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
    try await withThrowingTaskGroup(of: XPCMessage.self, returning: XPCMessage.self) { group in
        if let responseTimeout {
            group.addTask {
                try await Task.sleep(for: responseTimeout)
                throw ContainerizationError(.internalError, message: "XPC timeout ...")
            }
        }
        group.addTask {
            try await withCheckedThrowingContinuation { cont in
                xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { reply in
                    /* resume cont with parsed reply or error */
                }
            }
        }
        let response = try await group.next()   // ← rethrows the timeout
        group.cancelAll()                       // ← UNREACHABLE on throw
        try? await group.waitForAll()           // ← UNREACHABLE on throw
        guard let response else { throw ... }
        return response
    }
}
```

When `Task.sleep` wins the race:

1. `try await group.next()` rethrows the timeout error. The explicit `cancelAll() / waitForAll()` lines never execute.
2. Swift unwinds the throwing TaskGroup, which **must** await every pending child task before the group scope can return. (This is the structured concurrency contract — the group cannot outlive its children.)
3. The XPC child is suspended inside `withCheckedThrowingContinuation`, waiting for the C callback supplied to `xpc_connection_send_message_with_reply`.
4. **Cancelling a Swift `Task` does not cancel `xpc_connection_send_message_with_reply`.** `withCheckedThrowingContinuation` has no cancellation handler installed. The C call only resumes the continuation when its callback fires — and the callback only fires when XPC delivers a reply or invalidates the connection.
5. If the apiserver is wedged but launchd has not invalidated the registration, the callback never fires → TaskGroup cleanup blocks forever → `XPCClient.send` blocks forever — regardless of `responseTimeout`.

Net effect: every advertised timeout in the codebase is unreliable in exactly the failure modes timeouts are supposed to mitigate.

## Audit: callers that share Defect B

Every caller of `ClientHealthCheck.ping(...)` and every caller of `XPCClient.send(...)` is subject to the same indefinite-hang behavior in the wedged-daemon failure mode. The seven `ClientHealthCheck.ping` call sites:

```
Sources/ContainerCommands/Application.swift:169                 (--help, container help, no-args)
Sources/ContainerCommands/Builder/BuilderStart.swift:101
Sources/ContainerCommands/BuildCommand.swift:259
Sources/ContainerCommands/System/SystemStart.swift:120
Sources/ContainerCommands/System/SystemStop.swift:57
Sources/ContainerCommands/System/SystemStatus.swift:76
Sources/ContainerCommands/System/SystemVersion.swift:48
```

Plus every `XPCClient.send` call without a timeout (most callers in `Sources/Services/ContainerAPIService/Client/`).

This is why we treat Defect B as a separate fix: the help freeze is the symptom that motivated the investigation, but Defect B is a hazard the entire CLI shares.

## Fix design

### Defect A — `Sources/ContainerCommands/{Application,HelpCommand,DefaultCommand}.swift`

For the three help-rendering paths, drop the call to `createPluginLoader()` and pass `pluginLoader: nil` directly to `printModifiedHelpText`. Extend `printModifiedHelpText` with an optional `unavailableMessage:` so the help paths can suppress the `"PLUGINS: not available, run 'container system start'"` notice that would otherwise be misleading on a healthy system.

For `DefaultCommand`, also reorder `createPluginLoader()` to happen **after** the no-args/help guard, so only the actual plugin-dispatch path pays the daemon round-trip.

**Tradeoff (please critique).** This patch removes plugin enrichment from `--help` / `help` / no-args output. We chose this over a "filesystem-only plugin discovery" path because:

- It is a strictly local change (~15 lines across 3 files); it can be reviewed and reverted independently.
- It does not introduce new public API on `PluginLoader`.
- A follow-up can reintroduce plugin enrichment by extracting filesystem-only discovery from `PluginLoader.findPlugins()` (which already needs only `pluginDirectories` and `pluginFactories`). The blockers for that refactor are design-flavored, not freeze-flavored, so we'd rather decouple them.

If reviewers prefer to keep plugin enrichment in help, the natural follow-up is:

```swift
// PluginLoader.swift — proposed but NOT in this PR
public static func discoverFromDisk(
    in pluginDirectories: [URL],
    using pluginFactories: [PluginFactory],
    log: Logger? = nil
) -> [Plugin]

public static func alterCLIHelpText(original: String, plugins: [Plugin]) -> String
```

Then `Application.printModifiedHelpText` would call those two static helpers instead of needing a constructed `PluginLoader`.

### Defect B — `Sources/ContainerXPC/XPCClient.swift`

We need the timeout to actually return control to the caller without breaking `XPCClient` instances that are reused across multiple sends.

#### Why we did not use Oracle's first-pass recommendation (`onCancel: self.close()`)

The simplest patch — wrap the XPC continuation in `withTaskCancellationHandler` and call `xpc_connection_cancel` in `onCancel` — works correctly for one-shot clients (`ClientHealthCheck`, `ClientImage`, `ClientKernel`, `ClientVolume`, `ClientDiskUsage`, `RemoteContentStoreClient`). But:

```
Sources/Services/ContainerAPIService/Client/ContainerClient.swift:36     self.xpcClient = XPCClient(service: ...)
Sources/Services/ContainerAPIService/Client/NetworkClient.swift:56       self.xpcClient = XPCClient(service: ...)
```

These callers stash an `XPCClient` on the instance and reuse it across many `send` calls. `xpc_connection_cancel` is irreversible — once called, every subsequent `send` on that connection fails with `XPC_ERROR_CONNECTION_INVALID`. So a single timeout would silently brick the client for the rest of its lifetime.

#### What this PR does instead — single-resume continuation gated by a small state object

The XPC C callback is allowed to fire at any time; we just stop *waiting* for it once a timeout (or cancellation) wins. A small `ResumptionState` class guards a single `CheckedContinuation` so that exactly one of {reply received, timeout fired, parent cancelled} resumes the continuation, and the others become no-ops. The connection is never cancelled, so reusable clients keep working.

```swift
public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
    let state = ResumptionState<XPCMessage>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
            state.set(cont)
            xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { reply in
                do {
                    state.tryResume(returning: try self.parseReply(reply))
                } catch {
                    state.tryResume(throwing: error)
                }
            }
            if let responseTimeout {
                let service = self.service
                let route = message.string(key: XPCMessage.routeKey) ?? "nil"
                Task { [state] in
                    try? await Task.sleep(for: responseTimeout)
                    state.tryResume(throwing: ContainerizationError(
                        .timeout,
                        message: "XPC timeout for \(service)/\(route)"
                    ))
                }
            }
        }
    } onCancel: {
        state.tryResume(throwing: CancellationError())
    }
}
```

**Known leak.** When a timeout (or cancel) wins, the C-level reply callback eventually fires and is ignored. XPC retains the pending reply and its associated buffers until the connection is cancelled or released. For short-lived clients this is GC'd within milliseconds; for long-lived reusable clients the worst case is one orphaned `xpc_object_t` per timed-out send. We consider this acceptable until a deeper XPC-layer redesign is appropriate; an alternative (cancelling and reconstructing the connection on timeout) would require coordination with every reusable-client owner.

**Cancellation race window.** If `Task.cancel` is delivered before `state.set(cont)` runs, the cancellation handler's `tryResume` becomes a no-op against an empty state, and the continuation will never resume. We close this window by checking `Task.isCancelled` immediately after `state.set(cont)` and resuming with `CancellationError()` if so.

## What we explicitly chose **not** to fix in this PR

1. **Plugin enrichment in `--help` / `help` / no-args output.** Removed by this PR; can be reintroduced by the follow-up sketched above. Filed as a known regression in the PR description.
2. **`ClientHealthCheck.ping`'s default timeout being `XPCClient.xpcRegistrationTimeout` (60s).** All current call sites override the default to 2–10s, so the 60s default is dormant in practice. Worth fixing in a follow-up.
3. **The reusable `ContainerClient` / `NetworkClient` instances calling `XPCClient.send` without a timeout.** Defect B's fix makes timeouts work *when supplied*. Adding sensible default timeouts to those call sites is a separate concern.
4. **`launchctl bootout` style recovery as a CLI command.** Out of scope; the user-visible workaround is documented in the PR description.

## Verification this PR does and does not provide

| Claim | Verified by |
|---|---|
| Help path no longer pings the apiserver | Static — three `ClientHealthCheck.ping` call sites in help paths are removed |
| Help text still renders the original `OVERVIEW: ...` block | `Tests/CLITests/TestCLIHelp.swift` (covers `container help`) |
| `XPCClient.send` returns within `responseTimeout` when the C callback never fires | Not yet — needs a unit test that injects a connection with a non-firing reply. Reviewers: would you like one in this PR, or as a follow-up? |
| Reusable `XPCClient` instances survive a single-send timeout | Not yet — would benefit from the same kind of injected-connection test |

The two missing tests are the highest-value follow-ups to this PR.
