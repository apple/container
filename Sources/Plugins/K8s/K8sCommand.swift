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

import ArgumentParser
import ContainerVersion

@main
struct K8sCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "k8s",
        abstract: "Manage local Kubernetes development clusters (EXPERIMENTAL)",
        discussion: """
            EXAMPLES:
              Create a cluster by name and list clusters:
                $ container k8s create --name my-cluster
                $ container k8s list

              Switch between clusters:
                $ container k8s create --name second-cluster
                $ kubectl config use-context second-cluster
                $ kubectl config use-context my-cluster

              Write the cluster context to an alternate configuration file:
                $ container k8s write-config --name my-cluster --kubeconfig ~/.kube/my-cluster.kubeconfig
                $ KUBECONFIG=~/.kube/my-cluster.kubeconfig kubectl cluster-info

              Load a local image into the cluster and run it:
                $ container image pull docker.io/library/hello-world:latest
                $ container image tag docker.io/library/hello-world:latest my-hello-world:latest
                $ container k8s load-image --name my-cluster my-hello-world:latest
                $ kubectl run hello-job --image=my-hello-world:latest --restart=Never --attach --rm -i

              Stop and delete the cluster:
                $ container k8s delete --name my-cluster
            """,
        version: ReleaseVersion.singleLine(appName: "k8s"),
        subcommands: [
            K8sCreate.self,
            K8sDelete.self,
            K8sList.self,
            K8sLoadImage.self,
            K8sStart.self,
            K8sWriteConfig.self,
        ]
    )
}
