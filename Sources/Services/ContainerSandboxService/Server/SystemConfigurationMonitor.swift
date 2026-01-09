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

import Foundation
import Logging
import Synchronization
import SystemConfiguration

final public class SystemConfigurationMonitor: AsyncSequence {
    public typealias Element = [String]
    public typealias AsyncIterator = AsyncStream<[String]>.Iterator

    private let stream: AsyncStream<[String]>
    private let cleanup: () -> Void
    private let configStore: SCDynamicStore

    public init(keys: [String], log: Logger) throws {
        let eventInfo = EventInfo(log: log)
        let callback: SCDynamicStoreCallBack = { _, modifiedKeys, opaqueInfo in
            guard let opaqueInfo else { return }
            let eventInfo = Unmanaged<EventInfo>.fromOpaque(opaqueInfo).takeUnretainedValue()
            guard let keys = modifiedKeys as? [String] else {
                eventInfo.log.warning("keys not present, skipping")
                return
            }
            eventInfo.continuationMutex.withLock { wrapper in
                eventInfo.log.debug("enter callback")
                guard let continuation = wrapper.continuation else {
                    eventInfo.log.warning("continuation not present, skipping")
                    return
                }
                continuation.yield(keys)
                eventInfo.log.debug("exit callback")
            }
        }

        var context: SCDynamicStoreContext = .init(
            version: 0,
            info: Unmanaged.passUnretained(eventInfo).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let name = "com.apple.birdsc.\(UUID())" as CFString
        guard let configStore = SCDynamicStoreCreate(nil, name, callback, &context) else {
            throw DynamicStoreError.cannotCreate
        }
        self.configStore = configStore

        SCDynamicStoreSetNotificationKeys(configStore, nil, keys as CFArray)
        SCDynamicStoreSetDispatchQueue(configStore, DispatchQueue.main)

        let stream = AsyncStream<[String]> { continuation in
            eventInfo.continuationMutex.withLock { wrapper in
                eventInfo.log.debug("enter continuation mutex - stream")
                wrapper.continuation = continuation
                eventInfo.log.debug("exit continuation mutex - stream")
            }
        }

        self.stream = stream
        self.cleanup = {
            SCDynamicStoreSetNotificationKeys(configStore, nil, nil)
            eventInfo.continuationMutex.withLock { wrapper in
                wrapper.continuation = nil
            }
        }
    }

    deinit {
        cleanup()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        stream.makeAsyncIterator()
    }

    public func get(keyPatterns: [String]) -> [String: [String: Any]] {
        var keys: [CFString] = []
        for keyPattern in keyPatterns {
            keys.append(contentsOf: (SCDynamicStoreCopyKeyList(configStore, keyPattern as CFString) as? [CFString]) ?? [])
        }

        let values =
            keys
            .map { SCDynamicStoreCopyValue(configStore, $0 as CFString) }
            .map { $0 as? [CFString: Any] }

        var result: [String: [String: Any]] = [:]
        for (key, cfDict) in zip(keys, values) {
            guard let cfDict else {
                continue
            }
            result[key as String] = Dictionary(uniqueKeysWithValues: cfDict.map { ($0.key as String, $0.value) })
        }

        return result
    }
}

final class ContinuationWrapper {
    var continuation: AsyncStream<[String]>.Continuation?
}

final class EventInfo {
    let log: Logger
    let continuationMutex: Mutex<ContinuationWrapper>

    init(log: Logger) {
        self.log = log
        self.continuationMutex = .init(ContinuationWrapper())
    }
}

public enum DynamicStoreError: Error {
    case cannotCreate
}
