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

// MARK: - Volume lifecycle helpers

extension ContainerFixture {

    /// Creates a named volume, optionally with extra `--opt` arguments.
    func doVolumeCreate(_ name: String, opts: [String] = []) throws {
        var args = ["volume", "create"]
        for opt in opts { args += ["--opt", opt] }
        args.append(name)
        try run(args).check()
    }

    /// Deletes a volume, throwing on failure.
    func doVolumeDelete(_ name: String) throws {
        try run(["volume", "rm", name]).check()
    }

    /// Deletes a volume, silently ignoring errors.
    func doVolumeDeleteIfExists(_ name: String) {
        _ = try? run(["volume", "rm", name])
    }

    /// Returns `true` if `volume rm` exits non-zero (i.e. the delete was blocked).
    func doesVolumeDeleteFail(_ name: String) throws -> Bool {
        try run(["volume", "rm", name]).status != 0
    }

    /// Returns the names of all volume attachments on a container
    /// (the UUID name for anonymous volumes, the explicit name for named volumes).
    func getContainerMountedVolumeNames(_ containerName: String) throws -> [String] {
        let inspect = try inspectContainer(containerName)
        return inspect.configuration.mounts.compactMap { mount in
            if case .volume(let name, _, _, _) = mount.type { return name }
            return nil
        }
    }

    /// Returns the names of all anonymous volumes (UUID-format names) in the local store.
    func getAnonymousVolumeNames() throws -> [String] {
        let result = try run(["volume", "list", "--quiet"]).check()
        return result.output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isAnonymousVolumeName($0) }
    }

    /// Deletes all currently known anonymous volumes. Useful before count-based assertions.
    func doCleanupAnonymousVolumes() {
        for vol in (try? getAnonymousVolumeNames()) ?? [] {
            doVolumeDeleteIfExists(vol)
        }
    }

    /// Returns `true` if a volume with the given name appears in `volume list`.
    func volumeExists(_ name: String) throws -> Bool {
        let result = try run(["volume", "list", "--quiet"]).check()
        return result.output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains(name)
    }

    /// Returns `true` if `name` has the UUID format used for anonymous volumes.
    private func isAnonymousVolumeName(_ name: String) -> Bool {
        let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        guard let regex = try? Regex(pattern) else { return false }
        return (try? regex.firstMatch(in: name)) != nil
    }
}
