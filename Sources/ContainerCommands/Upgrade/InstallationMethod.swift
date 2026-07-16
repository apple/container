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

/// How the `container` toolset was installed on this host, which determines
/// how `container upgrade` performs the upgrade.
enum InstallationMethod: Equatable {
    /// Installed with the installer package from the GitHub release page;
    /// identified by the `com.apple.container-installer` receipt.
    case installerPackage
    /// Installed with the Homebrew `container` formula; identified by the
    /// executable resolving into a Homebrew Cellar.
    case homebrew
    /// No known installation source, e.g. a build from source.
    case unknown

    /// The package identifier recorded by the release-page installer,
    /// matching `scripts/uninstall-container.sh`.
    static let installerPackageID = "com.apple.container-installer"

    /// Classifies the installation from the symlink-resolved path of the
    /// running executable and the presence of the installer receipt. The
    /// Cellar check runs first: on Intel Macs Homebrew shares the
    /// `/usr/local` prefix with the installer package, and the resolved
    /// path identifies which copy is actually running.
    static func classify(resolvedExecutablePath: String, hasInstallerReceipt: Bool) -> InstallationMethod {
        if resolvedExecutablePath.contains("/Cellar/container/") {
            return .homebrew
        }
        if hasInstallerReceipt {
            return .installerPackage
        }
        return .unknown
    }

    /// Detects the installation method of the running executable.
    static func detect() -> InstallationMethod {
        let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        return classify(resolvedExecutablePath: resolved, hasInstallerReceipt: hasInstallerReceipt())
    }

    private static func hasInstallerReceipt() -> Bool {
        let query = Process()
        query.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        query.arguments = ["--pkg-info", installerPackageID]
        query.standardOutput = FileHandle.nullDevice
        query.standardError = FileHandle.nullDevice
        do {
            try query.run()
        } catch {
            return false
        }
        query.waitUntilExit()
        return query.terminationStatus == 0
    }
}
