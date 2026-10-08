# Resource usage

Configure CPU, memory, and disk resources for your containers and builds, monitor
usage while they run, and reclaim disk space afterward.

## Configure memory and CPUs for your containers

Since the containers created by `container` are lightweight virtual machines, consider the needs of your containerized application when you use `container run`.  The `--memory` and `--cpus` options allow you to override the default memory and CPU limits for the virtual machine. The default values are 1 gigabyte of RAM and 4 CPUs. You can use abbreviations for memory units; for example, to run a container for image `big` with 8 CPUs and 32 GiBytes of memory, use:

```bash
container run --rm --cpus 8 --memory 32g big
```

See [Resource limits (ulimits)](./ulimits.md) for per-process resource limits like open-file and process-count limits.

## Configure memory and CPUs for large builds

When you first run `container build`, `container` starts a *builder*, which is a utility container that builds images from your `Dockerfile`s. As with anything you run with `container run`, the builder runs in a lightweight virtual machine, so for resource-intensive builds, you may need to increase the memory and CPU limits for the builder VM.

By default, the builder VM receives 2 GiBytes of RAM and 2 CPUs. You can change these limits by starting the builder container before running `container build`:

```bash
container builder start --cpus 8 --memory 32g
```

If your builder is already running and you need to modify the limits, just stop, delete, and restart the builder:

```bash
container builder stop
container builder delete
container builder start --cpus 8 --memory 32g
```

## Overcommit memory and CPUs across containers

You can run more containers than your host has physical CPUs or memory for —
`container` does not reject a `--cpus` or `--memory` request that exceeds physical
capacity, whether for a single container or in aggregate across several. For example,
on an 8-CPU, 16 GB host you could run a builder VM with 4 CPUs/8 GB and three more
containers with 4 CPUs/2 GB each: 16 CPUs and 14 GB requested against 8 CPUs and 16 GB
physical.

This works because macOS schedules host and guest VM processes together against the
same physical resources, the same way it schedules any set of contending processes.
Throughput can't exceed what the physical CPUs provide, and CPU-bound containers slow
down as more of them compete for time. For memory, once real demand exceeds physical
RAM, macOS swaps out less-used pages — applications keep running, but performance
degrades and becomes limited by disk I/O as swapping increases. Leaving some CPU and
memory headroom for macOS and your other applications is a good practice.

## Monitor container resource usage

The `container stats` command displays real-time resource usage statistics for your running containers, similar to the `top` command for processes. This is useful for:
- Monitoring CPU and memory consumption
- Tracking network and disk I/O
- Identifying resource-intensive containers
- Verifying container resource limits are appropriate

By default, `container stats` shows live statistics for all running containers in an interactive display:

```console
% container stats
Container ID    Cpu %    Memory Usage           Net Rx/Tx              Block I/O               Pids
my-web-server   2.45%    45.23 MiB / 1.00 GiB   1.23 MiB / 856.00 KiB  4.50 MiB / 2.10 MiB     3
db              125.12%  512.50 MiB / 2.00 GiB  5.67 MiB / 3.21 MiB    125.00 MiB / 89.00 MiB  12
```

To monitor specific containers, provide their names or IDs:

```console
% container stats my-web-server db
```

For a single snapshot (non-interactive), use the `--no-stream` flag:

```console
% container stats --no-stream my-web-server
Container ID    Cpu %    Memory Usage          Net Rx/Tx              Block I/O              Pids
my-web-server   30.45%    45.23 MiB / 1.00 GiB  1.23 MiB / 856.00 KiB  4.50 MiB / 2.10 MiB    3
```

You can also output statistics in JSON format for scripting:

```console
% container stats --format json --no-stream my-web-server | jq
[
  {
    "id": "my-web-server",
    "memoryUsageBytes": 47431680,
    "memoryLimitBytes": 1073741824,
    "cpuUsageUsec": 1234567,
    "networkRxBytes": 1289011,
    "networkTxBytes": 876544,
    "blockReadBytes": 4718592,
    "blockWriteBytes": 2202009,
    "numProcesses": 3
  }
]
```

**Understanding the metrics:**

- **Cpu %**: Percentage of CPU usage. ~100% = one fully utilized core. A multi-core container can show > 100%.
- **Memory Usage**: Current memory usage vs. the container's memory limit.
- **Net Rx/Tx**: Network bytes received and transmitted.
- **Block I/O**: Disk bytes read and written.
- **Pids**: Number of processes running in the container.

## Disk usage

Each container gets a macOS sparse disk image for its writable filesystem. Named
volumes get their own sparse disk image too. As your containerized application writes
data, these images grow; when a container process deletes a file, the freed blocks
aren't automatically returned to the host filesystem, so image size doesn't shrink on
its own.

Check overall usage with:

```bash
container system df
```

```console
TYPE            TOTAL   ACTIVE   SIZE      RECLAIMABLE
Images          12      4        3.2GB     1.1GB (34%)
Containers      4       2        890MB     210MB (24%)
Local Volumes   6       3        4.5GB     2.1GB (47%)
```

### Reclaim disk space

Remove stopped containers:

```bash
container prune
```

Remove images not referenced by any container (add `--all` to remove all untagged and
unused images, not just dangling ones):

```bash
container image prune
container image prune --all
```

Remove volumes with no container references:

```bash
container volume prune
```

Reclaim space used by the builder VM's layer cache by replacing the builder:

```bash
container builder stop
container builder delete
```

See [Mounts and volumes](./volumes.md) for bind mounts, named volumes, and tmpfs
mounts.
