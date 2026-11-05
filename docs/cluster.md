# Container cluster

Kubernetes is an open-source orchestration platform for automating deployment, scaling, and management of containerized workloads across clusters of machines. With `container`, you can run local Kubernetes clusters for development and testing.

> [!WARNING]
> `container cluster create --shared-image-store` lets cluster nodes use your local image store, so pods can run images you build or pull with `container` without a registry. Sharing is off by default. With sharing on:
>
> - Anything with root on a node, including privileged pods and pods with a `hostPath` mount, can read every image in your local image store, including private images you pulled with your registry credentials.
> - A local image is used before a registry image with the same name, for every pull policy, and without the pod's pull secrets.
> - Nodes cannot add, change, or delete images in your local image store.
>
> Without `--shared-image-store`, nodes pull every image from a registry, as in a standard Kubernetes cluster.

## Why Kubernetes on container

Running Kubernetes locally with `container` gives you a streamlined workflow to build and test workloads before deploying to production:

- **Fast iteration.** Create and destroy clusters in seconds. Test your deployments locally before pushing to a remote cluster.
- **Multiple cluster versions.** Run different Kubernetes versions side-by-side without conflicts. Test compatibility across versions with ease.
- **Load your own images.** Images built with `container build` can be loaded directly into your cluster. Build once, run anywhere — local Kubernetes or production.
- **Lightweight VMs.** Clusters run as lightweight VMs on your Mac.
- **No special setup.** Uses standard Kubernetes tooling (`kubectl`, kubeconfig) — the same CLI and configuration files you use with production clusters.

## Quickstart

```bash
# Create a cluster
container cluster create

# Verify the cluster is running
container cluster list

# Interact with the cluster using kubectl
kubectl cluster-info
kubectl get nodes

# Clean up when done
container cluster delete
```

The cluster is automatically added to your `~/.kube/config`, so standard Kubernetes tools just work.

## Working with clusters

### Create and list clusters

Create a cluster with `container cluster create`. By default, it creates a cluster named `cluster-dev`:

```bash
container cluster create
```

You can create multiple named clusters:

```bash
container cluster create --name staging
container cluster create --name testing
```

List all clusters and their status:

```bash
container cluster list
```

Add `--nodes` to show one row per node instead of one row per cluster. Clusters created with an earlier version are not listed.

### Cluster lifecycle

Create a cluster, use it with kubectl, and delete it when finished:

```bash
# Create a cluster
container cluster create --name my-cluster

# Use the cluster with kubectl
kubectl --context my-cluster get pods

# Delete the cluster when finished
container cluster delete --name my-cluster
```

### Customize resources

Allocate CPU and memory based on your needs:

```bash
# Create a cluster with 4 CPUs and 8GB memory
container cluster create --name high-resource --cpus 4 --memory 8g
```

By default, clusters use 1/4 of your host's CPUs (minimum 2) and 1/4 of your host's memory (minimum 2GB).

### Multi-node clusters

By default, `container cluster create` creates a single node that acts as both control plane and worker. Use `--workers` to add dedicated worker nodes instead:

```bash
# Create a cluster with a control plane and 3 worker nodes
container cluster create --name my-cluster --workers 3
```

When `--workers` is greater than `0`, the control-plane node is tainted so pods only schedule onto worker nodes, matching typical multi-node cluster behavior. Worker nodes share the same `--node-image`, `--cpus`, and `--memory` settings as the control plane, and are named `<cluster-name>-worker-<n>`.

### Access clusters with kubectl

Once a cluster is created, `kubectl` works normally:

```bash
# Use your created cluster
kubectl --context cluster-dev get pods
kubectl --context cluster-dev describe node

# Switch between clusters
kubectl config use-context staging
```

## Use container images in your cluster

A cluster created with `--shared-image-store` can pull the images in your local image store. Build or pull an image with `container`, and reference it by name in a pod spec:

```bash
container cluster create --shared-image-store
container build -t my-app:dev .
kubectl run my-app --image=my-app:dev
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-app
spec:
  containers:
  - name: app
    image: my-app:dev
  restartPolicy: Never
```

If the local image store does not have an image, or has none of its content for the node's platform, the node pulls it from its registry as usual.

An image name without a registry, such as `my-app:dev`, is looked up in the local image store the same way `container` resolves it, using your default registry domain (`registry.domain`). Inside the cluster, Kubernetes shows such an image under its docker.io name, for example `docker.io/library/my-app:dev`.

> [!NOTE]
> - Every pull policy works, including `imagePullPolicy: Never`.
> - Sharing is set when the cluster is created. To change it, delete the cluster and create it again.
> - After rebuilding a tag, use `imagePullPolicy: Always` or a new tag so the node picks up the new image. With `IfNotPresent`, a node keeps the image it already has.

## Kubernetes node image

By default, clusters use `kindest/node:v1.35.5`, a Kubernetes-in-Docker image optimized for local development. You can use a different node image when creating a cluster:

```bash
container cluster create --node-image docker.io/kindest/node:v1.34.11
```

## Custom CNI

By default, clusters install the bundled kindnet CNI for pod networking. Use `--cni` to apply a different CNI manifest instead:

```bash
container cluster create --name my-cluster --cni ./my-cni.yaml
```

The manifest must be a plain Kubernetes YAML file (the same shape `kubectl apply -f` expects), not a Helm chart.

### Example: Cilium

Cilium is distributed as a Helm chart, so render a plain manifest from it first:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm template cilium cilium/cilium --version 1.20.1 --namespace kube-system --set ipam.mode=kubernetes > cilium.yaml
```

`--set ipam.mode=kubernetes` avoids a CIDR conflict: the chart's default (`cluster-pool`, `10.0.0.0/8`) overlaps kubeadm's pod subnet and service CIDR on these clusters.

Then create the cluster with that manifest:

```bash
container cluster create --name cilium-demo --cni ./cilium.yaml
```

Verify Cilium came up:

```bash
kubectl --context cilium-demo get pods -n kube-system
kubectl --context cilium-demo get nodes -o wide
```

## Cluster cleanup

Remove a cluster and its data:

```bash
container cluster delete --name my-cluster
```

To have a cluster automatically remove itself when stopped, create it with `--rm`:

```bash
container cluster create --name temp-cluster --rm
```

The node containers are removed when they stop, but the cluster's stored configuration remains, so the cluster shows as `stopped` in `container cluster list` until you run `container cluster delete --name temp-cluster` or create a cluster with the same name again (which clears the stale configuration).

### Recovering a stopped cluster

If a cluster's control plane node stops (for example, after `container stop`), delete and re-create the cluster:

```bash
container cluster delete --name my-cluster
container cluster create --name my-cluster
```

### Debugging a failed create

When `container cluster create` fails, it removes the nodes it started and the cluster's stored configuration (its metadata). To keep them so you can inspect the nodes, create the cluster with `--retain`:

```bash
container cluster create --name my-cluster --retain
container exec my-cluster journalctl -u kubelet
```

If the failure happened after `kubeadm init` completed, you can also use `kubectl` inside the control-plane node:

```bash
container exec my-cluster kubectl get pods -A
container exec my-cluster kubectl describe nodes
```

`--retain` keeps only nodes that finished starting. A node that fails while it's starting up (for example, while pulling the node image or booting) is still removed. The cluster's stored configuration is always kept, even if no nodes were retained, so `container cluster list` shows the cluster until you run `container cluster delete`.

If the create fails because another container already uses the cluster's name, no nodes are started and `--retain` has no effect. `container cluster delete` refuses to remove a container that isn't a cluster, so remove that container first, then run `container cluster delete` to clear the cluster's stored configuration.

You can combine `--retain` with `--rm`. The retained nodes keep running until you're done inspecting them, and are removed when they stop:

```bash
container cluster create --name my-cluster --retain --rm
container exec my-cluster journalctl -u kubelet
container stop my-cluster
```

As with any `--rm` cluster, the cluster's stored configuration remains after its nodes are removed, so run `container cluster delete --name my-cluster` to clear it.

When you finish, remove the retained nodes and the cluster's stored configuration:

```bash
container cluster delete --name my-cluster
```

## Common workflows

### Test a deployment locally before production

```bash
# Create a test cluster
container cluster create --name test

# Build your image locally; the cluster pulls it by name
container build -t my-service:v1.0 .

# Deploy to the test cluster
kubectl --context test apply -f deployment.yaml

# Verify everything works
kubectl --context test logs deployment/my-service

# Clean up when done
container cluster delete --name test
```

### One cluster per feature branch

```bash
# Create isolated clusters for concurrent development
container cluster create --name feature-auth
container cluster create --name feature-payments

# Work on each feature in isolation, test against its own cluster
```

## See also

- [Command reference](./command-reference.md#container-cluster-management) — full details of all `container cluster` subcommands
- [Container machines](./container-machine.md) — persistent Linux environments for general-purpose development
