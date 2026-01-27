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

import ContainerizationExtras
import TerminalProgress

public enum ContainerizationProgressAdapter: ProgressAdapter {
    public static func handler(from progressUpdate: ProgressUpdateHandler?) -> ProgressHandler? {
        guard let progressUpdate else {
            return nil
        }
        return { events in
            var updateEvents = [ProgressUpdateEvent]()
            for event in events {
                if event.event == "add-items" {
                    if let items = event.value as? Int {
                        updateEvents.append(.addItems(items))
                    }
                } else if event.event == "add-total-items" {
                    if let totalItems = event.value as? Int {
                        updateEvents.append(.addTotalItems(totalItems))
                    }
                } else if event.event == "add-size" {
                    if let size = event.value as? Int64 {
                        updateEvents.append(.addSize(size))
                    }
                } else if event.event == "add-total-size" {
                    if let totalSize = event.value as? Int64 {
                        updateEvents.append(.addTotalSize(totalSize))
                    }
                }
            }
            await progressUpdate(updateEvents)
        }
    }
}
