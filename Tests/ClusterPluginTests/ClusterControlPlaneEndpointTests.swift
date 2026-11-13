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

import Testing

@testable import ContainerCluster

@Suite("ClusterHelper.controlPlaneEndpointHost")
struct ClusterControlPlaneEndpointTests {
    @Test func endpointHostIsFQDNWhenSet() {
        #expect(ClusterHelper.controlPlaneEndpointHost(clusterName: "dev", fqdn: "dev.test") == "dev.test")
    }

    @Test func endpointHostIsClusterNameWithoutFQDN() {
        #expect(ClusterHelper.controlPlaneEndpointHost(clusterName: "dev", fqdn: nil) == "dev")
    }
}

@Suite("ClusterBootstrapper.initConfigYAML")
struct InitConfigYAMLTests {
    @Test func initConfigYAMLEmitsControlPlaneEndpoint() {
        let yaml = ClusterBootstrapper.initConfigYAML(
            kubernetesVersion: "v1.35.5", advertiseAddress: "192.168.64.5",
            controlPlaneEndpoint: "dev.test", certSANs: ["127.0.0.1"], sharedImageStore: false)

        #expect(yaml.contains("controlPlaneEndpoint: dev.test:\(ClusterHelper.clusterContainerPort)"))
    }
}

@Suite("ClusterHelper.hostsFileScript")
struct HostsFileScriptTests {
    @Test func scriptReplacesExistingLine() {
        let script = ClusterHelper.hostsFileScript(host: "dev", address: "192.168.64.7")

        #expect(
            script == """
                set -e
                grep -v ' dev$' /etc/hosts > /tmp/hosts.new || true
                echo '192.168.64.7 dev' >> /tmp/hosts.new
                cat /tmp/hosts.new > /etc/hosts
                rm -f /tmp/hosts.new
                """)
    }
}
