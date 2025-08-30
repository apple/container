//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerBuildIR
import Foundation

enum AddOptions: String {
    case keepGitDir = "--keep-git-dir"
    case checksum = "--checksum"
    case chown = "--chown"
    case chmod = "--chmod"
    case link = "--link"
}

struct AddInstruction: DockerInstruction {
    let sources: [String]
    let destination: String
    let checksum: String?
    let keepGitDir: Bool?
    let chown: Ownership?
    let chmod: Permissions?
    let link: Bool?

    internal init(
        sources: [String],
        destination: String?,
        chown: String? = nil,
        chmod: String? = nil,
        checksum: String? = nil,
        keepGitDir: Bool? = nil,
        link: Bool? = nil,
    ) throws {
        if sources.count > 1 && checksum != nil {
            // specifying a checksum is only valid with a single source
            throw ParseError.unexpectedValue
        }

        guard let destination = destination else {
            throw ParseError.missingRequiredField("destination")
        }

        if let cs = checksum, !cs.hasPrefix("sha256:") {
            throw ParseError.unexpectedValue
        }

        self.sources = sources
        self.destination = destination
        self.checksum = checksum
        self.keepGitDir = keepGitDir
        self.chown = try parseOwnership(input: chown)
        self.chmod = try parsePermissions(input: chmod)
        self.link = link
    }

    func accept(_ visitor: DockerInstructionVisitor) throws {
        try visitor.visit(self)
    }

    static internal func isHTTP(source: String) -> Bool {
        source.hasPrefix("https://") || source.hasPrefix("http://")
    }

    static internal func resolveSources(sources: [String], checksum: String?, keepGitDir: Bool? = nil) throws -> FilesystemSource {
        guard !sources.isEmpty else {
            throw ParseError.invalidSyntax
        }
        let firstSource = sources[0]

        let sourceIsHTTP = isHTTP(source: firstSource)
        if !sourceIsHTTP && checksum != nil {
            throw ParseError.invalidOption(checksum!)
        }

        let isGit = AddInstruction.isGitSource(source: firstSource, keepGitDir: keepGitDir)
        if isGit == nil && keepGitDir != nil {
            throw ParseError.invalidBoolOption("keepGitDir")
        }

        if isGit != nil {
            let gitSources = try sources.map { source in
                guard let git = AddInstruction.isGitSource(source: source, keepGitDir: keepGitDir) else {
                    throw ParseError.unexpectedValue
                }
                return git
            }
            return .git(gitSources)
        } else if sourceIsHTTP {
            let remoteSources = try sources.map { source in
                guard isHTTP(source: source) else {
                    throw ParseError.unexpectedValue
                }
                guard let url = URL(string: source) else {
                    throw ParseError.unexpectedValue
                }
                return RemoteSource(url: url, checksum: checksum)
            }
            return .remote(remoteSources)
        }

        let contextSource = ContextSource(paths: sources)
        return .context(contextSource)
    }

    static private func isGitSource(source: String, keepGitDir: Bool?) -> GitSource? {
        let urlFragments = source.split(separator: "#", maxSplits: 1).map(String.init)

        guard !urlFragments.isEmpty else {
            return nil
        }

        let url = urlFragments[0]
        if !url.hasPrefix("git@") && !url.hasSuffix(".git") {
            return nil
        }

        let reference: String? = {
            if urlFragments.count == 2 {
                return urlFragments[1]
            }
            return nil
        }()

        return GitSource(repository: url, reference: reference, keepGitDir: keepGitDir ?? false)
    }
}
