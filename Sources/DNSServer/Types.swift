//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import DNS
import Foundation

public typealias Message = DNS.Message
public typealias ResourceRecord = DNS.ResourceRecord
public typealias HostRecord = DNS.HostRecord
public typealias IPv4 = DNS.IPv4
public typealias IPv6 = DNS.IPv6
public typealias ReturnCode = DNS.ReturnCode

public enum DNSResolverError: Swift.Error, CustomStringConvertible {
    case serverError(_ msg: String)
    case invalidHandlerSpec(_ spec: String)
    case unsupportedHandlerType(_ t: String)
    case invalidIP(_ v: String)
    case invalidHandlerOption(_ v: String)
    case handlerConfigError(_ msg: String)

    public var description: String {
        switch self {
        case .serverError(let msg):
            return "server error: \(msg)"
        case .invalidHandlerSpec(let msg):
            return "invalid handler spec: \(msg)"
        case .unsupportedHandlerType(let t):
            return "unsupported handler type specified: \(t)"
        case .invalidIP(let ip):
            return "invalid IP specified: \(ip)"
        case .invalidHandlerOption(let v):
            return "invalid handler option specified: \(v)"
        case .handlerConfigError(let msg):
            return "error configuring handler: \(msg)"
        }
    }
}
