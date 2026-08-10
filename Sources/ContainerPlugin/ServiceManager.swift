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
    private static func runLaunchctlCommand(args: [String]) throws -> Int32 {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = args

        let null = FileHandle.nullDevice
        launchctl.standardOutput = null
        launchctl.standardError = null

        try launchctl.run()
        launchctl.waitUntilExit()

        return launchctl.terminationStatus
    }

    /// Register a service by providing the path to a plist.
    public static func register(plistPath: String) throws {
        let domain = try Self.getDomainString()
        _ = try runLaunchctlCommand(args: ["bootstrap", domain, plistPath])
    }

    /// Deregister a service by a launchd label.
    public static func deregister(fullServiceLabel label: String) throws {
        _ = try runLaunchctlCommand(args: ["bootout", label])
    }

    /// Deregister a service and pass return status
    public static func deregister(fullServiceLabel label: String, status: inout Int32) throws {
        status = try runLaunchctlCommand(args: ["bootout", label])
    }

    /// Deregister a service by its bare label, from whichever domain holds it.
    ///
    /// The domain a service sits in belongs to the session that registered it,
    /// not to the session asking about it now: `register` bootstraps into the
    /// domain of whoever called it, so a system started from a terminal no
    /// window server owns lands in `user/<uid>`, and the same command from a
    /// login session lands in `gui/<uid>`. Either one can drive the other's
    /// services afterwards, because reaching them is a matter of the Mach
    /// namespace rather than of the domain they were bootstrapped into.
    ///
    /// Returns whether a domain gave the service up, so that a caller looking
    /// in the wrong place is told so rather than left to assume it was heard.
    @discardableResult
    public static func deregisterAnyDomain(serviceLabel label: String) throws -> Bool {
        for domain in try Self.getDomainStrings() {
            var status: Int32 = -1
            try Self.deregister(fullServiceLabel: "\(domain)/\(label)", status: &status)
            if status == 0 {
                return true
            }
        }
        return false
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
    public static func isRegistered(fullServiceLabel label: String) throws -> Bool {
        let exitStatus = try runLaunchctlCommand(args: ["list", label])
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

    /// Every launchd domain a service of this user's could be registered in,
    /// the caller's own first so that the common case is answered first.
    public static func getDomainStrings() throws -> [String] {
        let own = try Self.getDomainString()
        let userDomains = ["user/\(getuid())", "gui/\(getuid())"]
        return [own] + userDomains.filter { $0 != own }
    }

    public static func getDomainString() throws -> String {
        let currentSessionType = try getLaunchdSessionType()
        switch currentSessionType {
        case LaunchPlist.Domain.System.rawValue:
            return LaunchPlist.Domain.System.rawValue.lowercased()
        case LaunchPlist.Domain.Background.rawValue:
            return "user/\(getuid())"
        case LaunchPlist.Domain.Aqua.rawValue:
            return "gui/\(getuid())"
        default:
            throw ContainerizationError(.internalError, message: "unsupported session type \(currentSessionType)")
        }
    }
}
