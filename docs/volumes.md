# Mounts and volumes

Share data from your host with containers, create named volumes with better
performance and lifecycle guarantees than bind mounts, and mount temporary,
memory-backed storage with tmpfs.

## Share host data

With the `--volume` option of `container run`, you can share data between the host system and one or more containers, and you can persist data across multiple container runs. Use the volume option to mount a folder on your host to a filesystem path in the container.

This example mounts a folder named `assets` on your Desktop to the directory `/content/assets` in a container:

<pre>
% ls -l ~/Desktop/assets
total 8
-rw-r--r--@ 1 fido  staff  2410 May 13 18:36 link.svg
% container run --volume ${HOME}/Desktop/assets:/content/assets docker.io/python:alpine ls -l /content/assets
total 4
-rw-r--r-- 1 root root 2410 May 14 01:36 link.svg
%
</pre>

The argument to `--volume` in the example consists of the full pathname for the host folder and the full pathname for the mount point in the container, separated by a colon.

The `--mount` option uses a comma-separated `key=value` syntax to achieve the same result:

<pre>
% container run --mount source=${HOME}/Desktop/assets,target=/content/assets docker.io/python:alpine ls -l /content/assets
total 4
-rw-r--r-- 1 root root 2410 May 14 01:36 link.svg
%
</pre>

## Named volumes

Named volumes offer complementary features to bind mounts. Use a named volume when you
don't need to share data with the host filesystem, and you want better I/O performance
than a bind mount provides.

Create a named volume with `container volume create`:

```bash
container volume create foo
```

By default, a volume uses a journaled `ext4` filesystem. Configure the journal mode and
size at creation time with `--opt`:

```bash
# ordered journaling (default)
container volume create --opt journal=ordered myvolume

# writeback journaling with a 64 MiB journal
container volume create --opt journal=writeback:64m myvolume

# full data journaling with an explicit volume size
container volume create --opt journal=journal --opt size=10g myvolume
```

List and remove volumes:

```bash
container volume list
container volume delete foo
```

Show a volume's configuration, including its size and the path to its backing image:

```bash
container volume inspect foo
```

```console
[
  {
    "configuration" : {
      "creationDate" : "2026-08-10T21:39:10Z",
      "driver" : "local",
      "format" : "ext4",
      "labels" : {

      },
      "name" : "foo",
      "options" : {

      },
      "sizeInBytes" : 549755813888,
      "source" : "\/Users\/fido\/Library\/Application Support\/com.apple.container\/volumes\/foo\/volume.img"
    },
    "id" : "foo"
  }
]
```

A volume's image is sparse, so `sizeInBytes` reports the size the volume can grow to —
512 GiB by default — rather than the space it currently occupies on disk.

Remove every volume that has no container referencing it:

```bash
container volume prune
```

> [!WARNING]
> `container volume prune` deletes the volumes and their contents immediately, and the data
> can't be recovered.

Mount a named volume the same way you bind-mount a host directory, using the volume
name as the source:

```bash
container run -it --rm --volume foo:/mnt/foo alpine sh
```

Or with `--mount`:

```bash
container run -it --rm --mount type=volume,source=foo,target=/mnt/foo alpine sh
```

## Anonymous volumes

Using `-v /path` or `--mount type=volume,target=/path` without specifying a source creates
a named volume for you automatically — an anonymous volume. It's named with a bare UUID
(no prefix) and tagged with the `com.apple.container.resource.anonymous` label:

```bash
# Creates an anonymous volume
container run -v /data alpine
```

`container volume list` marks it `anonymous` in the `TYPE` column. For scripting, select it
by its label, since the JSON output has no type field:

```bash
VOL=$(container volume list --format json | jq -r '.[] | select(.configuration.labels["com.apple.container.resource.anonymous"] != null) | .id')
container run -v $VOL:/data alpine
```

> [!NOTE]
> Unlike Docker, anonymous volumes aren't deleted automatically when the container is
> removed with `--rm`. Delete them explicitly:
>
> ```bash
> container volume delete $VOL
> ```

## Tmpfs mounts

A `tmpfs` mount is temporary storage that lives only in the guest VM's memory. When the
container stops, the mount and everything written to it are gone. You can't share a
`tmpfs` mount between containers, unlike a bind mount or a named volume.

Use a `tmpfs` mount when you need high-performance storage and don't need the data to
persist after the container stops.

Use either `--tmpfs` or `--mount type=tmpfs`. Both accept the `size` and `mode` options;
see [Mount options](#mount-options) for the syntax each one takes.

Mount a `tmpfs` filesystem at `/tmpfsmount1` with `--tmpfs`:

```bash
container run --rm --tmpfs /tmpfsmount1 alpine mount -t tmpfs
```

```console
tmpfs on /tmpfsmount1 type tmpfs (rw,relatime)
tmpfs on /dev/shm type tmpfs (rw,nosuid,nodev,noexec,relatime,size=65536k)
tmpfs on /sys/firmware type tmpfs (ro,nosuid,nodev,noexec,relatime)
```

The last two entries are runtime defaults, present in every container. See
[Runtime configuration](./runtime-configuration.md#mask-and-protect-paths-inside-a-container)
for what mounts `/sys/firmware` read-only.

Mount a `tmpfs` filesystem with a 512 MiB size limit using `--mount`:

```bash
container run --rm --mount type=tmpfs,target=/tmpfsmount1,size=512M alpine stat -f /tmpfsmount1
```

```console
  File: "/tmpfsmount1"
    ID: 89a6eaf01fc1572c Namelen: 255     Type: tmpfs
Block size: 4096
Blocks: Total: 131072     Free: 131071     Available: 131071
Inodes: Total: 142352     Free: 142350
```

131072 blocks × 4096 bytes = 512 MiB, confirming the size limit took effect.

Set the mount's permission bits with `mode` (octal, same as `chmod`):

```bash
container run --rm --mount type=tmpfs,target=/tmpfsmount1,size=512M,mode=1777 alpine stat -c '%a' /tmpfsmount1
```

```console
1777
```

## Mount options

Mount-time options go on `container run` or `container create`, using `--mount`,
`--volume`, or `--tmpfs`. Creation-time options go on `container volume create`, using
`--opt`.

### Options for `--mount`

`--mount` takes comma-separated `key=value` pairs. An unrecognized key is an error.

| Key | Values | Applies to | Description |
|---|---|---|---|
| `type` | `bind` (alias `virtiofs`), `volume`, `tmpfs` | — | The kind of mount to create. Defaults to a bind mount. |
| `source`, `src` | host path, or volume name | bind mounts, named volumes | The host directory to share, or the name of the volume to mount. Omit it for a tmpfs mount, or to get an [anonymous volume](#anonymous-volumes). |
| `destination`, `dst`, `target` | absolute container path | all | Where the mount appears inside the container. |
| `readonly`, `ro` | key only, no value | all | Mount read-only. |
| `size` | for example `512M`, `1G` | tmpfs only | Upper bound on the guest memory the mount can consume. |
| `mode` | octal, for example `1777` | tmpfs only | Permission bits for the mount point, the same as `chmod`. |

### Options for `--volume`

`--volume` uses the colon-separated form `[source:]destination[:options]`, comma-separated
if there is more than one:

```bash
container run --rm --volume foo:/mnt/foo:ro alpine sh
```

| Key | Values | Description |
|---|---|---|
| `ro` | key only, no value | Mount read-only. |

### Options for `--tmpfs`

`--tmpfs` uses the colon-separated form `destination[:options]`, comma-separated if there
is more than one:

```bash
container run --rm --tmpfs /tmpfsmount1:size=64M,mode=1777 alpine sh
```

| Key | Values | Description |
|---|---|---|
| `size` | for example `512M`, `1G` | Upper bound on the guest memory the mount can consume. |
| `mode` | octal, for example `1777` | Permission bits for the mount point, the same as `chmod`. |

### Options for `container volume create`

| Key | Values | Description |
|---|---|---|
| `size` | for example `10g` | Size of the volume's filesystem image, fixed at creation time. |
| `journal` | `ordered` (default), `writeback`, `journal`, each optionally as `<mode>:<size>` | The `ext4` journal mode, and optionally the journal size — for example `writeback:64m`. |

