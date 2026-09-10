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

// MARK: - KubeConfig

struct KubeConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case apiVersion, kind, clusters, contexts, users
        case currentContext = "current-context"
    }

    var apiVersion: String = "v1"
    var kind: String = "Config"
    var clusters: [NamedCluster] = []
    var contexts: [NamedContext] = []
    var users: [NamedAuthInfo] = []
    var currentContext: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion) ?? "v1"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "Config"
        clusters = try c.decodeIfPresent([NamedCluster].self, forKey: .clusters) ?? []
        contexts = try c.decodeIfPresent([NamedContext].self, forKey: .contexts) ?? []
        users = try c.decodeIfPresent([NamedAuthInfo].self, forKey: .users) ?? []
        currentContext = try c.decodeIfPresent(String.self, forKey: .currentContext)
    }

    static let empty = KubeConfig()
}

// MARK: - NamedCluster

struct NamedCluster: Codable {
    var name: String
    var cluster: Cluster
}

// MARK: - Cluster

struct Cluster: Codable {
    enum CodingKeys: String, CodingKey {
        case server
        case tlsServerName = "tls-server-name"
        case insecureSkipTLSVerify = "insecure-skip-tls-verify"
        case certificateAuthority = "certificate-authority"
        case certificateAuthorityData = "certificate-authority-data"
        case proxyURL = "proxy-url"
    }

    var server: String
    var tlsServerName: String?
    var insecureSkipTLSVerify: Bool?
    var certificateAuthority: String?
    var certificateAuthorityData: String?
    var proxyURL: String?
}

// MARK: - NamedContext

struct NamedContext: Codable {
    var name: String
    var context: Context
}

// MARK: - Context

struct Context: Codable {
    var cluster: String
    var user: String
    var namespace: String?
}

// MARK: - NamedAuthInfo

struct NamedAuthInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case name
        case authInfo = "user"
    }

    var name: String
    var authInfo: AuthInfo
}

// MARK: - AuthInfo

struct AuthInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case clientCertificate = "client-certificate"
        case clientCertificateData = "client-certificate-data"
        case clientKey = "client-key"
        case clientKeyData = "client-key-data"
        case token
        case tokenFile = "token-file"
        case impersonate
        case impersonateGroups = "impersonate-groups"
        case impersonateUserExtra = "impersonate-user-extra"
        case username
        case password
        case authProvider = "auth-provider"
        case exec
    }

    var clientCertificate: String?
    var clientCertificateData: String?
    var clientKey: String?
    var clientKeyData: String?
    var token: String?
    var tokenFile: String?
    var impersonate: String?
    var impersonateGroups: [String]?
    var impersonateUserExtra: [String: String]?
    var username: String?
    var password: String?
    var authProvider: AuthProviderConfig?
    var exec: ExecConfig?
}

// MARK: - AuthProviderConfig

struct AuthProviderConfig: Codable {
    var name: String
    var config: [String: String]?
}

// MARK: - ExecConfig

struct ExecConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case command, args, env, apiVersion
        case installHint = "installHint"
        case provideClusterInfo = "provideClusterInfo"
        case interactiveMode = "interactiveMode"
    }

    var command: String
    var args: [String]?
    var env: [ExecEnvVar]?
    var apiVersion: String
    var installHint: String?
    var provideClusterInfo: Bool?
    var interactiveMode: String?
}

// MARK: - ExecEnvVar

struct ExecEnvVar: Codable {
    var name: String
    var value: String
}
