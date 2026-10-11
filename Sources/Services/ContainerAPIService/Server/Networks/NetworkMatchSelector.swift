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

import ContainerNetworkClient

/// Chooses the best answer to a name from the matches that individual networks report.
///
/// A hostname or an exact alias is decisive. Both are unique across all networks, so no other network
/// can have a better match, and the search can stop. A subtree alias is not decisive: another network
/// may have a hostname, an exact alias, or a subtree alias with a longer base, which is the most
/// specific. Two different subtrees that match a name and have the same number of labels in the base
/// must have the same base, and a base belongs to one container, so there is no tie to break.
struct NetworkMatchSelector {
    /// The best match offered so far.
    private(set) var best: NetworkMatch?

    /// Considers a match reported by a network.
    ///
    /// - Returns: `true` if the match is decisive and the search can stop.
    @discardableResult
    mutating func offer(_ match: NetworkMatch) -> Bool {
        switch match.kind {
        case .hostname, .alias:
            best = match
            return true
        case .subtree(let baseLabelCount):
            switch best?.kind {
            case .hostname?, .alias?:
                // A decisive match was already found, and nothing beats it.
                return true
            case .subtree(let bestBaseLabelCount)?:
                if bestBaseLabelCount >= baseLabelCount {
                    return false
                }
            case nil:
                break
            }
            best = match
            return false
        }
    }
}
