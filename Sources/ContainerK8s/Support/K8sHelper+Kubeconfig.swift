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

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Darwin
import Foundation
import Logging
import SystemPackage
import Yams

extension K8sHelper {
    // MARK: - Kubeconfig

    private static var kubeconfigDir: FilePath {
        FilePath(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))
            .appending(".kube")
    }

    static func fetchConfig(containerId: String, client: ContainerClient, log: Logger) async throws -> KubeConfig {
        log.info("Fetching kubeconfig", metadata: ["cluster": "\(containerId)"])

        let container = try await client.get(id: containerId)
        guard container.configuration.labels[ResourceLabelKeys.plugin] == pluginName else {
            log.error("container is not a k8s cluster, refusing config fetch", metadata: ["name": "\(containerId)"])
            throw ContainerizationError(.invalidArgument, message: "\(containerId) is not a k8s cluster")
        }

        let (exitCode, yaml) = try await execCapture(
            containerId: containerId, executable: "/bin/cat",
            arguments: [kubeconfigPath], client: client)
        guard exitCode == 0 else {
            throw ContainerizationError(.internalError, message: "failed to read kubeconfig from \(containerId): exit \(exitCode)")
        }
        do {
            return try YAMLDecoder().decode(KubeConfig.self, from: yaml)
        } catch {
            throw ContainerizationError(.internalError, message: "failed to decode kubeconfig from \(containerId): \(error)")
        }
    }

    /// Rewrites the kubeconfig fetched from a cluster container into a host-safe entry.
    ///
    /// The source document comes from `/etc/kubernetes/admin.conf` inside a container,
    /// which is untrusted. We rebuild the entry from explicitly allowed fields.
    ///
    /// Fields that provide code-execution primitives fail the whole operation, since a
    /// node image or compromised workload that supplies one needs the user's attention.
    /// Fields that are just not needed are dropped quietly.
    static func transformConfig(_ config: KubeConfig, containerId: String, fqdn: String?, client: ContainerClient) async throws -> KubeConfig {
        guard config.clusters.count == 1, config.users.count == 1, config.contexts.count == 1 else {
            throw ContainerizationError(
                .invalidArgument,
                message:
                    "admin.conf for cluster \(containerId) does not match the expected kubeadm shape (expected exactly one cluster, user, and context); refusing to merge into kubeconfig"
            )
        }

        let serverAddress: String
        if let fqdn {
            serverAddress = "https://\(fqdn):6443"
        } else {
            let snapshot = try await client.get(id: containerId)
            guard
                let hostPort = snapshot.configuration.publishedPorts
                    .first(where: { $0.containerPort == clusterContainerPort })?.hostPort
            else {
                throw ContainerizationError(.internalError, message: "no published port for cluster \(containerId)")
            }
            serverAddress = "https://127.0.0.1:\(hostPort)"
        }

        let rawCluster = config.clusters[0].cluster
        let sanitizedCluster = Cluster(
            server: serverAddress,
            certificateAuthorityData: rawCluster.certificateAuthorityData
        )

        let rawUser = config.users[0].authInfo
        guard rawUser.exec == nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "admin.conf for cluster \(containerId) contains an unsupported exec credential entry; refusing to merge into kubeconfig")
        }
        guard rawUser.authProvider == nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "admin.conf for cluster \(containerId) contains an unsupported auth-provider credential entry; refusing to merge into kubeconfig")
        }
        let sanitizedUser = AuthInfo(
            clientCertificateData: rawUser.clientCertificateData,
            clientKeyData: rawUser.clientKeyData,
            token: rawUser.token
        )

        let sanitizedContext = Context(
            cluster: containerId,
            user: containerId,
            namespace: config.contexts[0].context.namespace
        )

        // Rename all entries to containerId. kubeadm uses fixed names ("kubernetes",
        // "kubernetes-admin@kubernetes", etc.) rather than "default", so we rename
        // unconditionally.
        var result = KubeConfig()
        result.clusters = [NamedCluster(name: containerId, cluster: sanitizedCluster)]
        result.users = [NamedAuthInfo(name: containerId, authInfo: sanitizedUser)]
        result.contexts = [NamedContext(name: containerId, context: sanitizedContext)]
        result.currentContext = containerId
        return result
    }

    static func resolveKubeconfigMergePath() -> FilePath {
        let defaultPath = kubeconfigDir.appending("config")
        guard let raw = Darwin.getenv("KUBECONFIG") else { return defaultPath }
        let env = String(cString: raw)
        guard !env.isEmpty else { return defaultPath }
        let paths = env.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return defaultPath }
        if paths.count == 1 { return FilePath(paths[0]) }
        for p in paths where FileManager.default.fileExists(atPath: p) {
            return FilePath(p)
        }
        return FilePath(paths[paths.count - 1])
    }

    static func mergeConfig(_ config: KubeConfig, containerId: String, targetPath: FilePath? = nil, setCurrentContext: Bool = false, log: Logger) throws {
        let path = targetPath ?? resolveKubeconfigMergePath()
        log.info("Writing kubeconfig", metadata: ["cluster": "\(containerId)", "path": "\(path)"])

        let targetDir = path.removingLastComponent()
        try FileManager.default.createDirectory(atPath: targetDir.string, withIntermediateDirectories: true)

        var existing: KubeConfig
        if FileManager.default.fileExists(atPath: path.string) {
            do {
                let yaml = try String(contentsOfFile: path.string, encoding: .utf8)
                existing = try YAMLDecoder().decode(KubeConfig.self, from: yaml)
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "kubeconfig at \(path) could not be parsed: \(error)"
                )
            }
        } else {
            existing = .empty
        }

        existing.clusters.removeAll { $0.name == containerId }
        existing.contexts.removeAll { $0.name == containerId }
        existing.users.removeAll { $0.name == containerId }

        existing.clusters.append(contentsOf: config.clusters)
        existing.contexts.append(contentsOf: config.contexts)
        existing.users.append(contentsOf: config.users)
        if setCurrentContext {
            existing.currentContext = containerId
        }

        let output = try YAMLEncoder().encode(existing)
        try output.write(toFile: path.string, atomically: true, encoding: .utf8)
    }

    static func removeConfig(containerId: String, log: Logger) throws {
        let path = resolveKubeconfigMergePath()
        log.info("Removing kubeconfig", metadata: ["cluster": "\(containerId)", "path": "\(path)"])

        guard FileManager.default.fileExists(atPath: path.string) else { return }

        let existing: KubeConfig
        do {
            let yaml = try String(contentsOfFile: path.string, encoding: .utf8)
            existing = try YAMLDecoder().decode(KubeConfig.self, from: yaml)
        } catch {
            log.warning("kubeconfig exists but could not be parsed, skipping removal", metadata: ["path": "\(path)", "error": "\(error)"])
            return
        }

        var updated = existing

        updated.clusters.removeAll { $0.name == containerId }
        updated.contexts.removeAll { $0.name == containerId }
        updated.users.removeAll { $0.name == containerId }

        if updated.currentContext == containerId {
            updated.currentContext = nil
        }

        let output = try YAMLEncoder().encode(updated)
        try output.write(toFile: path.string, atomically: true, encoding: .utf8)
    }
}
