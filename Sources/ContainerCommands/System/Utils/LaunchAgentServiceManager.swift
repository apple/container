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

public struct LaunchAgentServiceManager {
    public static let launchAgentLabel = "com.apple-container.launchagent"
    public static let launchAgentPlist = "com.apple-container.launchagent.plist"
    public static let launchAgentPath = "Library/LaunchAgents"
    public static let launchContainerExecutable = "launch-container"

    /// Registers the LaunchAgent and creates its plist file.
    /// - Parameters:
    ///   - appRoot: The URL of the application's root directory.
    ///   - installRoot: The URL of the installation root directory.
    /// - Throws: An error if creating the plist or registering the service fails.
    public static func registerLaunchAgent(appRoot: URL, installRoot: URL) throws {
        let launchContainerExecutableURL = CommandLine.executablePathUrl
            .deletingLastPathComponent()
            .appendingPathComponent(launchContainerExecutable)
            .resolvingSymlinksInPath()

        var args = [launchContainerExecutableURL.absolutePath()]
        args.append("start")

        let fileManager = FileManager.default
        let launchAgentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(launchAgentPath)

        try fileManager.createDirectory(
            at: launchAgentsDirectory,
            withIntermediateDirectories: true
        )

        var env = PluginLoader.filterEnvironment()
        env[ApplicationRoot.environmentName] = appRoot.path(percentEncoded: false)
        env[InstallRoot.environmentName] = installRoot.path(percentEncoded: false)

        let plist = LaunchPlist(
            label: launchAgentLabel,
            arguments: args,
            environment: env,
            runAtLoad: true,
            stdout: "/tmp/\(launchAgentLabel).out.log",
            stderr: "/tmp/\(launchAgentLabel).err.log",
            keepAlive: false,
        )

        let plistURL =
            launchAgentsDirectory
            .appendingPathComponent(launchAgentPlist)

        let data = try plist.encode()
        try data.write(to: plistURL)
        try ServiceManager.register(plistPath: plistURL.path)
    }

    /// Deregisters the LaunchAgent and removes its plist file if it exists.
    ///
    /// - Throws: An error if deregistering the service or removing the file fails.
    public static func deregisterLaunchAgent() throws {
        let fileManager = FileManager.default
        let launchAgentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(launchAgentPath)

        let plistURL =
            launchAgentsDirectory
            .appendingPathComponent(launchAgentPlist)

        let launchdDomainString = try ServiceManager.getDomainString()
        let fullLabel = "\(launchdDomainString)/\(launchAgentLabel)"
        try ServiceManager.deregister(fullServiceLabel: fullLabel)
        if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }
    }
}
