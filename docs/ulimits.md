# Resource limits (ulimits)

Set per-process resource limits for your containers.

## Overview

The `--ulimit` option of `container run` (and `container create`) sets Linux resource
limits (`rlimit`s) for the container's init process.

## Syntax

```bash
container run --ulimit <type>=<soft>[:<hard>] ...
```

If you set a single value, it applies as both soft and hard limit:

```bash
container run --ulimit nofile=65536 -it ubuntu:24.04 bash
```

Set soft and hard limits independently:

```bash
container run --ulimit nofile=65536:131072 -it ubuntu:24.04 bash
```

Set multiple limits by repeating the flag:

```bash
container run --ulimit nofile=65536:131072 --ulimit cpu=60 -it ubuntu:24.04 bash
```

Use `unlimited` for no limit:

```bash
container run --ulimit nproc=unlimited -it ubuntu:24.04 bash
```

> [!NOTE]
> `nofile=unlimited` reliably fails to start the container
> (`NSPOSIXErrorDomain Code=1 "Operation not permitted"`). This isn't a `container`
> bug — `unlimited` sets both soft and hard limits to `UINT64_MAX`, and Linux caps
> `RLIMIT_NOFILE`'s hard limit at the guest's `/proc/sys/fs/nr_open` (`1048576` here);
> anything above that ceiling fails the same way, `unlimited` included. Use an explicit
> value at or below `nr_open` instead, e.g. `nofile=1048576`.

## Supported limit types

| Type | Maps to | Description |
|---|---|---|
| `core` | `RLIMIT_CORE` | Maximum core file size, in bytes |
| `cpu` | `RLIMIT_CPU` | Maximum CPU time, in seconds |
| `data` | `RLIMIT_DATA` | Maximum data segment size, in bytes |
| `fsize` | `RLIMIT_FSIZE` | Maximum file size, in bytes |
| `locks` | `RLIMIT_LOCKS` | Maximum number of file locks |
| `memlock` | `RLIMIT_MEMLOCK` | Maximum amount of memory that may be locked into RAM |
| `msgqueue` | `RLIMIT_MSGQUEUE` | Maximum bytes in POSIX message queues |
| `nice` | `RLIMIT_NICE` | Maximum nice priority |
| `nofile` | `RLIMIT_NOFILE` | Maximum number of open file descriptors |
| `nproc` | `RLIMIT_NPROC` | Maximum number of processes |
| `rss` | `RLIMIT_RSS` | Maximum resident set size, in bytes |
| `rtprio` | `RLIMIT_RTPRIO` | Maximum real-time priority |
| `rttime` | `RLIMIT_RTTIME` | Maximum real-time CPU time, in microseconds |
| `sigpending` | `RLIMIT_SIGPENDING` | Maximum number of pending signals |
| `stack` | `RLIMIT_STACK` | Maximum stack size, in bytes |

## Inspect limits inside a container

```console
% container run -it --rm ubuntu:24.04 bash -c "ulimit -a"
open files                          (-n) 1048576
cpu time                   (seconds, -t) unlimited
...
% container run --ulimit nofile=131072 --ulimit cpu=60 -it --rm ubuntu:24.04 bash -c "ulimit -a"
open files                          (-n) 131072
cpu time                   (seconds, -t) 60
...
```
