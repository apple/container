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

import Darwin
import Foundation
import Logging
import SystemPackage
import Testing
import Yams

@testable import ContainerK8s

// MARK: - Helpers

private func makeTempFile() throws -> (FilePath, cleanup: () -> Void) {
    let path = FilePath(FileManager.default.temporaryDirectory.path)
        .appending("kubeconfig-test-\(UUID().uuidString)")
    return (path, { try? FileManager.default.removeItem(atPath: path.string) })
}

private func decode(_ yaml: String) throws -> KubeConfig {
    try YAMLDecoder().decode(KubeConfig.self, from: yaml)
}

private func encode(_ config: KubeConfig) throws -> String {
    try YAMLEncoder().encode(config)
}

private let log = Logger(label: "test")

// MARK: - Round-trip fidelity

@Suite("KubeConfig round-trip fidelity")
struct KubeconfigRoundTripTests {

    @Test func execAuthRoundTrip() throws {
        let yaml = """
            apiVersion: v1
            kind: Config
            clusters:
            - name: gke-cluster
              cluster:
                server: https://1.2.3.4
                certificate-authority-data: dGVzdA==
            contexts:
            - name: gke-context
              context:
                cluster: gke-cluster
                user: gke-user
                namespace: production
            current-context: gke-context
            users:
            - name: gke-user
              user:
                exec:
                  apiVersion: client.authentication.k8s.io/v1beta1
                  command: gke-gcloud-auth-plugin
                  args:
                  - --some-flag
                  env:
                  - name: USE_GKE_GCLOUD_AUTH_PLUGIN
                    value: "True"
                  installHint: Install gke-gcloud-auth-plugin
                  provideClusterInfo: true
                  interactiveMode: IfAvailable
            """
        let config = try decode(yaml)
        let user = try #require(config.users.first)
        let exec = try #require(user.authInfo.exec)
        #expect(exec.command == "gke-gcloud-auth-plugin")
        #expect(exec.args == ["--some-flag"])
        #expect(exec.env?.first?.name == "USE_GKE_GCLOUD_AUTH_PLUGIN")
        #expect(exec.env?.first?.value == "True")
        #expect(exec.installHint == "Install gke-gcloud-auth-plugin")
        #expect(exec.provideClusterInfo == true)
        #expect(exec.interactiveMode == "IfAvailable")

        // Re-encode and decode again — fields must survive the round-trip
        let reencoded = try encode(config)
        let redecoded = try decode(reencoded)
        let exec2 = try #require(redecoded.users.first?.authInfo.exec)
        #expect(exec2.command == exec.command)
        #expect(exec2.args == exec.args)
        #expect(exec2.env?.first?.name == exec.env?.first?.name)
        #expect(exec2.provideClusterInfo == exec.provideClusterInfo)
        #expect(redecoded.contexts.first?.context.namespace == "production")
    }

    @Test func tokenAuthRoundTrip() throws {
        let yaml = """
            apiVersion: v1
            kind: Config
            clusters:
            - name: my-cluster
              cluster:
                server: https://1.2.3.4
            contexts:
            - name: my-context
              context:
                cluster: my-cluster
                user: my-user
            current-context: my-context
            users:
            - name: my-user
              user:
                token: supersecrettoken
            """
        let config = try decode(yaml)
        #expect(config.users.first?.authInfo.token == "supersecrettoken")

        let redecoded = try decode(try encode(config))
        #expect(redecoded.users.first?.authInfo.token == "supersecrettoken")
    }

    @Test func authProviderRoundTrip() throws {
        let yaml = """
            apiVersion: v1
            kind: Config
            clusters:
            - name: legacy-gke
              cluster:
                server: https://1.2.3.4
            contexts:
            - name: legacy-context
              context:
                cluster: legacy-gke
                user: legacy-user
            current-context: legacy-context
            users:
            - name: legacy-user
              user:
                auth-provider:
                  name: gcp
                  config:
                    cmd-path: /usr/lib/google-cloud-sdk/bin/gcloud
                    token-key: '{.credential.access_token}'
            """
        let config = try decode(yaml)
        let provider = try #require(config.users.first?.authInfo.authProvider)
        #expect(provider.name == "gcp")
        #expect(provider.config?["cmd-path"] == "/usr/lib/google-cloud-sdk/bin/gcloud")

        let redecoded = try decode(try encode(config))
        let provider2 = try #require(redecoded.users.first?.authInfo.authProvider)
        #expect(provider2.name == provider.name)
        #expect(provider2.config?["cmd-path"] == provider.config?["cmd-path"])
    }

    @Test func clusterFieldsRoundTrip() throws {
        let yaml = """
            apiVersion: v1
            kind: Config
            clusters:
            - name: proxied-cluster
              cluster:
                server: https://1.2.3.4
                tls-server-name: my-server.example.com
                insecure-skip-tls-verify: true
                proxy-url: http://proxy.example.com:8080
            contexts:
            - name: proxied-context
              context:
                cluster: proxied-cluster
                user: proxied-user
            current-context: proxied-context
            users:
            - name: proxied-user
              user:
                token: abc
            """
        let config = try decode(yaml)
        let cluster = try #require(config.clusters.first?.cluster)
        #expect(cluster.tlsServerName == "my-server.example.com")
        #expect(cluster.insecureSkipTLSVerify == true)
        #expect(cluster.proxyURL == "http://proxy.example.com:8080")

        let redecoded = try decode(try encode(config))
        let cluster2 = try #require(redecoded.clusters.first?.cluster)
        #expect(cluster2.tlsServerName == cluster.tlsServerName)
        #expect(cluster2.insecureSkipTLSVerify == cluster.insecureSkipTLSVerify)
        #expect(cluster2.proxyURL == cluster.proxyURL)
    }
}

// MARK: - mergeConfig behavior

@Suite("K8sHelper.mergeConfig")
struct MergeConfigTests {

    private func makeConfig(clusterName: String, server: String = "https://127.0.0.1:6443") -> KubeConfig {
        var config = KubeConfig()
        config.clusters = [NamedCluster(name: clusterName, cluster: Cluster(server: server, certificateAuthorityData: "dGVzdA=="))]
        config.contexts = [NamedContext(name: clusterName, context: Context(cluster: clusterName, user: clusterName))]
        config.users = [NamedAuthInfo(name: clusterName, authInfo: AuthInfo(clientCertificateData: "dGVzdA==", clientKeyData: "dGVzdA=="))]
        config.currentContext = clusterName
        return config
    }

    @Test func mergeIntoEmptyFileCreatesFile() throws {
        let (path, cleanup) = try makeTempFile()
        defer { cleanup() }

        try K8sHelper.mergeConfig(makeConfig(clusterName: "dev"), containerId: "dev", targetPath: path, setCurrentContext: true, log: log)

        let written = try decode(String(contentsOfFile: path.string, encoding: .utf8))
        #expect(written.clusters.count == 1)
        #expect(written.clusters[0].name == "dev")
        #expect(written.currentContext == "dev")
    }

    @Test func mergePreservesExistingExecAuthEntry() throws {
        let (path, cleanup) = try makeTempFile()
        defer { cleanup() }

        // Write an existing kubeconfig with a GKE exec-auth entry
        let existingYAML = """
            apiVersion: v1
            kind: Config
            clusters:
            - name: gke-prod
              cluster:
                server: https://5.6.7.8
                certificate-authority-data: dGVzdA==
            contexts:
            - name: gke-prod
              context:
                cluster: gke-prod
                user: gke-prod-user
                namespace: production
            current-context: gke-prod
            users:
            - name: gke-prod-user
              user:
                exec:
                  apiVersion: client.authentication.k8s.io/v1beta1
                  command: gke-gcloud-auth-plugin
                  provideClusterInfo: true
                  interactiveMode: IfAvailable
            """
        try existingYAML.write(toFile: path.string, atomically: true, encoding: .utf8)

        try K8sHelper.mergeConfig(makeConfig(clusterName: "dev"), containerId: "dev", targetPath: path, log: log)

        let result = try decode(String(contentsOfFile: path.string, encoding: .utf8))

        // New entry present
        #expect(result.clusters.contains { $0.name == "dev" })
        #expect(result.currentContext == "gke-prod")  // existing context preserved — not overwritten

        // GKE entry fully preserved
        let gkeCluster = try #require(result.clusters.first { $0.name == "gke-prod" })
        #expect(gkeCluster.cluster.server == "https://5.6.7.8")

        let gkeUser = try #require(result.users.first { $0.name == "gke-prod-user" })
        let exec = try #require(gkeUser.authInfo.exec)
        #expect(exec.command == "gke-gcloud-auth-plugin")
        #expect(exec.provideClusterInfo == true)
        #expect(exec.interactiveMode == "IfAvailable")

        let gkeContext = try #require(result.contexts.first { $0.name == "gke-prod" })
        #expect(gkeContext.context.namespace == "production")
    }

    @Test func mergePreservesTokenAuthEntry() throws {
        let (path, cleanup) = try makeTempFile()
        defer { cleanup() }

        let existingYAML = """
            apiVersion: v1
            kind: Config
            clusters:
            - name: staging
              cluster:
                server: https://9.10.11.12
            contexts:
            - name: staging
              context:
                cluster: staging
                user: staging-user
            current-context: staging
            users:
            - name: staging-user
              user:
                token: verysecrettoken
            """
        try existingYAML.write(toFile: path.string, atomically: true, encoding: .utf8)

        try K8sHelper.mergeConfig(makeConfig(clusterName: "dev"), containerId: "dev", targetPath: path, log: log)

        let result = try decode(String(contentsOfFile: path.string, encoding: .utf8))
        let stagingUser = try #require(result.users.first { $0.name == "staging-user" })
        #expect(stagingUser.authInfo.token == "verysecrettoken")
    }

    @Test func mergeReplacesExistingEntryWithSameName() throws {
        let (path, cleanup) = try makeTempFile()
        defer { cleanup() }

        try K8sHelper.mergeConfig(makeConfig(clusterName: "dev", server: "https://127.0.0.1:6445"), containerId: "dev", targetPath: path, log: log)
        try K8sHelper.mergeConfig(makeConfig(clusterName: "dev", server: "https://127.0.0.1:6446"), containerId: "dev", targetPath: path, log: log)

        let result = try decode(String(contentsOfFile: path.string, encoding: .utf8))
        #expect(result.clusters.filter { $0.name == "dev" }.count == 1)
        #expect(result.contexts.filter { $0.name == "dev" }.count == 1)
        #expect(result.users.filter { $0.name == "dev" }.count == 1)
        #expect(result.clusters.first { $0.name == "dev" }?.cluster.server == "https://127.0.0.1:6446")
    }

    @Test func mergeThrowsWhenExistingFileIsInvalidYAML() throws {
        let (path, cleanup) = try makeTempFile()
        defer { cleanup() }

        try "this: is: not: valid: yaml: [[[".write(toFile: path.string, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try K8sHelper.mergeConfig(makeConfig(clusterName: "dev"), containerId: "dev", targetPath: path, log: log)
        }
    }

    @Test func mergeAlwaysSetsCurrentContext() throws {
        let (path, cleanup) = try makeTempFile()
        defer { cleanup() }

        // First create: sets current-context
        try K8sHelper.mergeConfig(makeConfig(clusterName: "first"), containerId: "first", targetPath: path, setCurrentContext: true, log: log)
        // Second create: overwrites current-context to point to the new cluster
        try K8sHelper.mergeConfig(makeConfig(clusterName: "second"), containerId: "second", targetPath: path, setCurrentContext: true, log: log)

        let result = try decode(String(contentsOfFile: path.string, encoding: .utf8))
        #expect(result.currentContext == "second")  // always switches to the most recently created cluster
        #expect(result.clusters.count == 2)
    }
}

// MARK: - env-dependent tests
// Both suites mutate the KUBECONFIG environment variable; wrap them in a
// common .serialized parent so they cannot race against each other.

@Suite("K8sHelper env-dependent", .serialized)
struct KubeconfigEnvTests {

    // MARK: - resolveKubeconfigMergePath

    @Suite("K8sHelper.resolveKubeconfigMergePath")
    struct ResolveKubeconfigMergePathTests {

        private func withKubeconfigEnv(_ value: String?, _ body: () -> Void) {
            let key = "KUBECONFIG"
            let original = Darwin.getenv(key).map { String(cString: $0) }
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
            body()
            if let original {
                setenv(key, original, 1)
            } else {
                unsetenv(key)
            }
        }

        @Test func noEnvDefaultsToHomeKubeConfig() {
            withKubeconfigEnv(nil) {
                let path = K8sHelper.resolveKubeconfigMergePath()
                #expect(path.string.hasSuffix(".kube/config"))
            }
        }

        @Test func singleEnvPathUsedDirectly() {
            withKubeconfigEnv("/tmp/my-kubeconfig") {
                let path = K8sHelper.resolveKubeconfigMergePath()
                #expect(path.string == "/tmp/my-kubeconfig")
            }
        }

        @Test func multiplePathsFirstExistingWins() throws {
            let existing = FilePath(FileManager.default.temporaryDirectory.path)
                .appending("kube-exists-\(UUID().uuidString)")
            try "".write(toFile: existing.string, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: existing.string) }

            withKubeconfigEnv("/tmp/does-not-exist-a:\(existing.string):/tmp/does-not-exist-b") {
                let path = K8sHelper.resolveKubeconfigMergePath()
                #expect(path.string == existing.string)
            }
        }

        @Test func multiplePathsNoneExistUsesLast() {
            withKubeconfigEnv("/tmp/no-exist-a:/tmp/no-exist-b:/tmp/no-exist-c") {
                let path = K8sHelper.resolveKubeconfigMergePath()
                #expect(path.string == "/tmp/no-exist-c")
            }
        }
    }

    // MARK: - removeConfig behavior

    @Suite("K8sHelper.removeConfig")
    struct RemoveConfigTests {

        private func makeConfig(clusterName: String) -> KubeConfig {
            var config = KubeConfig()
            config.clusters = [NamedCluster(name: clusterName, cluster: Cluster(server: "https://127.0.0.1:6443"))]
            config.contexts = [NamedContext(name: clusterName, context: Context(cluster: clusterName, user: clusterName))]
            config.users = [NamedAuthInfo(name: clusterName, authInfo: AuthInfo())]
            return config
        }

        private func withKubeconfig(_ initial: KubeConfig, _ body: () throws -> Void) throws {
            let tmp = FilePath(FileManager.default.temporaryDirectory.path)
                .appending("kubeconfig-remove-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(atPath: tmp.string) }
            try encode(initial).write(toFile: tmp.string, atomically: true, encoding: .utf8)
            let original = Darwin.getenv("KUBECONFIG").map { String(cString: $0) }
            setenv("KUBECONFIG", tmp.string, 1)
            defer {
                if let original { setenv("KUBECONFIG", original, 1) } else { unsetenv("KUBECONFIG") }
            }
            try body()
        }

        private func currentKubeconfig() throws -> KubeConfig {
            let path = K8sHelper.resolveKubeconfigMergePath()
            return try decode(String(contentsOfFile: path.string, encoding: .utf8))
        }

        @Test func removesClusterContextAndUserEntries() throws {
            var initial = makeConfig(clusterName: "dev")
            let other = makeConfig(clusterName: "other")
            initial.clusters += other.clusters
            initial.contexts += other.contexts
            initial.users += other.users
            initial.currentContext = "other"

            try withKubeconfig(initial) {
                try K8sHelper.removeConfig(containerId: "dev", log: log)
                let result = try currentKubeconfig()
                #expect(result.clusters.count == 1)
                #expect(!result.clusters.contains { $0.name == "dev" })
                #expect(result.users.count == 1)
                #expect(result.contexts.count == 1)
            }
        }

        @Test func clearsCurrentContextWhenItMatchesDeletedCluster() throws {
            var initial = makeConfig(clusterName: "dev")
            initial.currentContext = "dev"

            try withKubeconfig(initial) {
                try K8sHelper.removeConfig(containerId: "dev", log: log)
                #expect(try currentKubeconfig().currentContext == nil)
            }
        }

        @Test func preservesCurrentContextWhenItPointsElsewhere() throws {
            var initial = makeConfig(clusterName: "dev")
            let other = makeConfig(clusterName: "other")
            initial.clusters += other.clusters
            initial.contexts += other.contexts
            initial.users += other.users
            initial.currentContext = "other"

            try withKubeconfig(initial) {
                try K8sHelper.removeConfig(containerId: "dev", log: log)
                #expect(try currentKubeconfig().currentContext == "other")
            }
        }

        @Test func noopWhenFileDoesNotExist() throws {
            let missing = FilePath(FileManager.default.temporaryDirectory.path)
                .appending("kubeconfig-missing-\(UUID().uuidString)")
            let original = Darwin.getenv("KUBECONFIG").map { String(cString: $0) }
            setenv("KUBECONFIG", missing.string, 1)
            defer {
                if let original { setenv("KUBECONFIG", original, 1) } else { unsetenv("KUBECONFIG") }
            }
            try K8sHelper.removeConfig(containerId: "dev", log: log)
        }
    }
}
