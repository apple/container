# `cluster` CLI

`cluster` is a small companion CLI that creates a single-node Kubernetes
cluster inside Apple Containerization, using `kubeadm` and `kindnet`.

## Requirements

- Apple silicon Mac
- macOS 26
- `container` system service running:
  - `container system start --enable-kernel-install`

## Quick start

```bash
# Create a cluster named "kubernetes"
cluster create

# Use a custom kernel (recommended for certain CNI features)
cluster create --kernel /path/to/vmlinux

# Show status and endpoints
cluster status

# Stop/start the cluster
cluster stop
cluster start

# Delete the cluster
cluster delete
```

## Kubeconfig

By default, kubeconfig is written to:

```
~/.kube/cluster/<cluster-name>.config
```

You can override the path during creation:

```bash
cluster create --kubeconfig ~/.kube/config
```

You can also print a fresh kubeconfig from a running cluster:

```bash
cluster kubeconfig
```

## Flags (create)

- `--name` cluster name (default: `kubernetes`)
- `--image` node image (default: kindest/node)
- `--cpus` CPU count
- `--memory` memory (e.g. `8G`, `16G`)
- `--pod-cidr` pod network CIDR
- `--api-port` API server host port
- `--kernel` kernel binary path
- `--kubeconfig` kubeconfig output path
