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

#if os(macOS)
import Foundation

public struct LaunchPlist: Encodable {
    static let debugTarget = "CONTAINER_DEBUG_LAUNCHD_LABEL"

    public enum Domain: String, Codable {
        case Aqua
        case Background
        case System
    }

    public let label: String
    public let arguments: [String]

    public let environment: [String: String]?
    public let cwd: String?
    public let username: String?
    public let groupname: String?
    public let limitLoadToSessionType: [Domain]?
    public let runAtLoad: Bool?
    public let stdin: String?
    public let stdout: String?
    public let stderr: String?
    public let disabled: Bool?
    public let program: String?
    public let keepAlive: Bool?
    public let machServices: [String: Bool]?
    public let waitForDebugger: Bool?

    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case arguments = "ProgramArguments"
        case environment = "EnvironmentVariables"
        case cwd = "WorkingDirectory"
        case username = "UserName"
        case groupname = "GroupName"
        case limitLoadToSessionType = "LimitLoadToSessionType"
        case runAtLoad = "RunAtLoad"
        case stdin = "StandardInPath"
        case stdout = "StandardOutPath"
        case stderr = "StandardErrorPath"
        case disabled = "Disabled"
        case program = "Program"
        case keepAlive = "KeepAlive"
        case machServices = "MachServices"
        case waitForDebugger = "WaitForDebugger"
    }

    static private func getWaitForDebugger(label: String, fromArg: Bool?) -> Bool? {
        if let fromArg {
            return fromArg
        }

        let env = ProcessInfo.processInfo.environment
        if let debugTarget = env[Self.debugTarget],
            label == debugTarget || label.starts(with: debugTarget + ".")
        {
            return true
        }

        return nil
    }

    public init(
        label: String,
        arguments: [String],
        environment: [String: String]? = nil,
        cwd: String? = nil,
        username: String? = nil,
        groupname: String? = nil,
        limitLoadToSessionType: [Domain]? = nil,
        runAtLoad: Bool? = nil,
        stdin: String? = nil,
        stdout: String? = nil,
        stderr: String? = nil,
        disabled: Bool? = nil,
        program: String? = nil,
        keepAlive: Bool? = nil,
        machServices: [String]? = nil,
        waitForDebugger: Bool? = nil
    ) {
        self.label = label
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.username = username
        self.groupname = groupname
        self.limitLoadToSessionType = limitLoadToSessionType
        self.runAtLoad = runAtLoad
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.disabled = disabled
        self.program = program
        self.keepAlive = keepAlive
        self.waitForDebugger = Self.getWaitForDebugger(label: label, fromArg: waitForDebugger)
        if let services = machServices {
            var machServices: [String: Bool] = [:]
            for service in services {
                machServices[service] = true
            }
            self.machServices = machServices
        } else {
            self.machServices = nil
        }
    }
}

extension LaunchPlist {
    public func encode() throws -> Data {
        let enc = PropertyListEncoder()
        enc.outputFormat = .xml
        return try enc.encode(self)
    }
}
#endif
