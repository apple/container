//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerizationError
import Foundation

public struct ServiceManager {
    private static func runLaunchctlCommand(args: [String]) throws -> (status: Int32, stderr: String) {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = args

        let null = FileHandle.nullDevice
        let stderrPipe = Pipe()
        launchctl.standardOutput = null
        launchctl.standardError = stderrPipe

        try launchctl.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()

        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (launchctl.terminationStatus, stderr)
    }

    /// Register a service by providing the path to a plist.
    public static func register(plistPath: String) throws {
        let domain = try Self.getDomainString()
        let command = "launchctl bootstrap \(domain) \(plistPath)"
        let (status, stderr) = try runLaunchctlCommand(args: ["bootstrap", domain, plistPath])
        guard status == 0 else {
            // `container system start` is idempotent: if the service is already
            // bootstrapped, launchctl returns non-zero. Treat that as success.
            // Use try? so a launchctl spawn failure does not replace the bootstrap error.
            // Query the same domain we bootstrapped into.
            if let label = try? launchdLabel(fromPlistAt: plistPath),
                (try? isRegistered(fullServiceLabel: "\(domain)/\(label)")) == true
            {
                return
            }
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message =
                detail.isEmpty
                ? "command `\(command)` failed with status \(status)"
                : "command `\(command)` failed with status \(status), message: \(detail)"
            throw ContainerizationError(.internalError, message: message)
        }
    }

    /// Deregister a service by a launchd label.
    public static func deregister(fullServiceLabel label: String) throws {
        _ = try runLaunchctlCommand(args: ["bootout", label])
    }

    /// Deregister a service and pass return status
    public static func deregister(fullServiceLabel label: String, status: inout Int32) throws {
        status = try runLaunchctlCommand(args: ["bootout", label]).status
    }

    /// Restart a service by a launchd label.
    public static func kickstart(fullServiceLabel label: String) throws {
        _ = try runLaunchctlCommand(args: ["kickstart", "-k", label])
    }

    /// Send a signal to a service by a launchd label.
    public static func kill(fullServiceLabel label: String, signal: Int32 = 15) throws {
        _ = try runLaunchctlCommand(args: ["kill", "\(signal)", label])
    }

    /// Retrieve labels for all loaded launch units.
    public static func enumerate() throws -> [String] {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["list"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        launchctl.standardOutput = stdoutPipe
        launchctl.standardError = stderrPipe

        try launchctl.run()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()
        let status = launchctl.terminationStatus
        guard status == 0 else {
            throw ContainerizationError(
                .internalError, message: "command `launchctl list` failed with status \(status), message: \(String(data: stderrData, encoding: .utf8) ?? "no error message")")
        }

        guard let outputText = String(data: outputData, encoding: .utf8) else {
            throw ContainerizationError(
                .internalError, message: "could not decode output of command `launchctl list`, message: \(String(data: stderrData, encoding: .utf8) ?? "no error message")")
        }

        // The third field of each line of launchctl list output is the label
        return outputText.split { $0.isNewline }
            .map { String($0).split { $0.isWhitespace } }
            .filter { $0.count >= 3 }
            .map { String($0[2]) }
    }

    /// Check if a service has been registered or not.
    ///
    /// Prefer a domain-qualified service target (`gui/501/label`, `system/label`)
    /// so the lookup agrees with the domain used by `register`. Bare labels still
    /// use `launchctl list` for compatibility with existing callers.
    public static func isRegistered(fullServiceLabel label: String) throws -> Bool {
        let args = label.contains("/") ? ["print", label] : ["list", label]
        let exitStatus = try runLaunchctlCommand(args: args).status
        return exitStatus == 0
    }

    private static func getLaunchdSessionType() throws -> String {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["managername"]

        let null = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        launchctl.standardOutput = stdoutPipe
        launchctl.standardError = null

        try launchctl.run()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()
        let status = launchctl.terminationStatus
        guard status == 0 else {
            throw ContainerizationError(.internalError, message: "command `launchctl managername` failed with status \(status)")
        }
        guard let outputText = String(data: outputData, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "could not decode output of command `launchctl managername`")
        }
        return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func getDomainString() throws -> String {
        try domainString(sessionType: getLaunchdSessionType(), uid: getuid(), euid: geteuid())
    }

    /// Compute the launchd domain target for the given session and credentials.
    ///
    /// When running as root outside an Aqua session (for example `sudo` on a CI
    /// runner), bootstrap into the `system` domain. `user/0` and `gui/0` are not
    /// valid bootstrap targets in that context.
    static func domainString(sessionType: String, uid: uid_t, euid: uid_t) throws -> String {
        if euid == 0 && sessionType != LaunchPlist.Domain.Aqua.rawValue {
            return LaunchPlist.Domain.System.rawValue.lowercased()
        }
        switch sessionType {
        case LaunchPlist.Domain.System.rawValue:
            return LaunchPlist.Domain.System.rawValue.lowercased()
        case LaunchPlist.Domain.Background.rawValue:
            return "user/\(uid)"
        case LaunchPlist.Domain.Aqua.rawValue:
            return "gui/\(uid)"
        default:
            throw ContainerizationError(.internalError, message: "unsupported session type \(sessionType)")
        }
    }

    private static func launchdLabel(fromPlistAt path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any],
            let label = dict[LaunchPlist.CodingKeys.label.rawValue] as? String
        else {
            throw ContainerizationError(.internalError, message: "launchd plist at \(path) is missing Label")
        }
        return label
    }
}
