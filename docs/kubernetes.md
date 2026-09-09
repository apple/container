# Kubernetes clusters

Kubernetes is an open-source orchestration platform for automating deployment, scaling, and management of containerized workloads across clusters of machines. With `container`, you can run local Kubernetes clusters for development and testing.

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
container k8s create

# Verify the cluster is running
container k8s list

# Interact with the cluster using kubectl
kubectl cluster-info
kubectl get nodes

# Clean up when done
container k8s delete
```

The cluster is automatically added to your `~/.kube/config`, so standard Kubernetes tools just work.

## Working with clusters

### Create and list clusters

Create a cluster with `container k8s create`. By default, it creates a cluster named `k8s-dev`:

```bash
container k8s create
```

You can create multiple named clusters:

```bash
container k8s create --name staging
container k8s create --name testing
```

List all clusters and their status:

```bash
container k8s list
```

### Cluster lifecycle

Create a cluster, use it with kubectl, and delete it when finished:

```bash
# Create a cluster
container k8s create --name my-cluster

# Use the cluster with kubectl
kubectl --context my-cluster get pods

# Delete the cluster when finished
container k8s delete --name my-cluster
```

### Customize resources

Allocate CPU and memory based on your needs:

```bash
# Create a cluster with 4 CPUs and 8GB memory
container k8s create --name high-resource --cpus 4 --memory 8g
```

By default, clusters use 1/4 of your host's CPUs (minimum 2) and 1/4 of your host's memory (minimum 2GB).

### Access clusters with kubectl

Once a cluster is created, `kubectl` works normally:

```bash
# Use your created cluster
kubectl --context k8s-dev get pods
kubectl --context k8s-dev describe node

# Switch between clusters
kubectl config use-context staging
```

## Load container images into your cluster

Images built with `container build` can be loaded directly into your Kubernetes cluster, so you can test them without pushing to a registry.

### Build and load

Build an image and load it into your cluster:

```bash
# Build a local image
container build -t my-app:latest .

# Load the image into the cluster
container k8s load-image my-app:latest
```

The image is placed in the `k8s.io` namespace, making it available for pod scheduling:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-app
spec:
  containers:
  - name: app
    image: my-app:latest
    imagePullPolicy: Never
  restartPolicy: Never
```

### Load into named clusters

If you have multiple clusters, specify which one to load into:

```bash
container k8s load-image --name staging my-app:latest
container k8s load-image --name testing my-app:latest
```

### Multi-architecture images

When loading multi-architecture images, specify the architecture if needed:

```bash
# Load the amd64 variant of a multi-arch image
container k8s load-image --platform linux/amd64 my-app:latest
```

## Kubernetes node image

By default, clusters use `kindest/node:v1.35.5`, a Kubernetes-in-Docker image optimized for local development. You can use a different node image when creating a cluster:

```bash
container k8s create --node-image docker.io/kindest/node:v1.34.4
```

## Cluster cleanup

Remove a cluster and its data:

```bash
container k8s delete --name my-cluster
```

To have a cluster automatically remove itself when stopped, create it with `--rm`:

```bash
container k8s create --name temp-cluster --rm
```

## Common workflows

### Test a deployment locally before production

```bash
# Create a test cluster
container k8s create --name test

# Build your image locally
container build -t my-service:v1.0 .

# Load it into the test cluster
container k8s load-image --name test my-service:v1.0

# Deploy to the test cluster
kubectl --context test apply -f deployment.yaml

# Verify everything works
kubectl --context test logs deployment/my-service

# Clean up when done
container k8s delete --name test
```

### One cluster per feature branch

```bash
# Create isolated clusters for concurrent development
container k8s create --name feature-auth
container k8s create --name feature-payments

# Work on each feature in isolation, test against its own cluster
container k8s load-image --name feature-auth my-service:feature-auth
container k8s load-image --name feature-payments my-service:feature-payments
```

## See also

- [Command reference](./command-reference.md#kubernetes-cluster-management) — full details of all `container k8s` subcommands
- [Container machines](./container-machine.md) — persistent Linux environments for general-purpose development
