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

/// A downloadable asset attached to a GitHub release.
struct GitHubReleaseAsset: Decodable, Equatable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

/// The subset of the GitHub release API response needed to upgrade `container`.
struct GitHubRelease: Decodable, Equatable {
    let tagName: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

/// An installer package selected from a release's assets.
struct InstallerPackage: Equatable {
    let url: URL
    let isSigned: Bool
}

extension GitHubRelease {
    /// The GitHub API endpoint for a release: the latest release when
    /// `version` is nil, otherwise the release tagged `version`.
    static func endpoint(forVersion version: String?) -> URL {
        let base = "https://api.github.com/repos/apple/container/releases"
        guard let version else {
            return URL(string: "\(base)/latest")!
        }
        return URL(string: "\(base)/tags/\(version)")!
    }

    /// Selects the installer package, preferring signed packages, with the
    /// same name precedence as `scripts/update-container.sh`.
    func installerPackage() -> InstallerPackage? {
        let signedNames = [
            "container-installer-signed.pkg",
            "container-\(tagName)-installer-signed.pkg",
        ]
        let unsignedNames = [
            "container-installer-unsigned.pkg",
            "container-\(tagName)-installer-unsigned.pkg",
        ]
        for name in signedNames {
            if let match = assets.first(where: { $0.name == name }) {
                return InstallerPackage(url: match.browserDownloadURL, isSigned: true)
            }
        }
        for name in unsignedNames {
            if let match = assets.first(where: { $0.name == name }) {
                return InstallerPackage(url: match.browserDownloadURL, isSigned: false)
            }
        }
        return nil
    }
}

/// Decides whether an upgrade should proceed, mirroring the plain string
/// comparison in `scripts/update-container.sh` (no semver ordering).
enum UpgradePolicy {
    static func shouldUpgrade(target: String, installed: String, force: Bool) -> Bool {
        force || target != installed
    }
}
