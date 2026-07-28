# Mounts and volumes

Share data from your host with containers, create named volumes with better
performance and lifecycle guarantees than bind mounts, and mount temporary,
memory-backed storage with tmpfs.

## Share host data

With the `--volume` option of `container run`, you can share data between the host system and one or more containers, and you can persist data across multiple container runs. The volume option allows you to mount a folder on your host to a filesystem path in the container.

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

Remove every volume that isn't attached to a container:

```bash
container volume prune
```

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

Using `-v /path` or `--mount type=volume,target=/path` without specifying a source
auto-creates a named volume for you — an anonymous volume. It's named with a bare UUID
(no prefix) and tagged with the `com.apple.container.resource.anonymous` label:

```bash
# Creates an anonymous volume
container run -v /data alpine
```

Find it by its label (the bare UUID name has no "anon" marker to `grep` for):

```bash
VOL=$(container volume list --format json | jq -r '.[] | select(.configuration.labels["com.apple.container.resource.anonymous"] != null) | .id')
container run -v $VOL:/data alpine
```

> [!NOTE]
> Unlike Docker, anonymous volumes do **not** auto-cleanup when the container is removed
> with `--rm`. Delete them explicitly:
>
> ```bash
> container volume rm $VOL
> ```

## Tmpfs mounts

A `tmpfs` mount is temporary storage that lives only in the guest VM's memory. When the
container stops, the mount and everything written to it are gone. You can't share a
`tmpfs` mount between containers, unlike a bind mount or a named volume.

Use a `tmpfs` mount when you need high-performance storage and don't need the data to
survive the container stopping.

Use `--tmpfs` for a plain mount with no options, or `--mount` for a mount with `size`
and `mode` options.

Mount a `tmpfs` filesystem at `/tmpfsmount1` with `--tmpfs`:

```bash
container run --rm --tmpfs /tmpfsmount1 alpine mount -t tmpfs
```

```console
tmpfs on /tmpfsmount1 type tmpfs (rw,relatime)
```

Mount the same filesystem with a 512 MiB size limit using `--mount`:

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

> [!NOTE]
> `df -h /tmpfsmount1` won't show this mount, and it's also absent from a plain `df -h`
> with no path argument. A `tmpfs` mount created via `--mount type=tmpfs` (unlike the
> plain `--tmpfs` flag) gets an empty source field in the guest's mount table, which
> `df` can't resolve; `mount`'s own listing garbles the same entry for the same reason.
> This doesn't affect the mount itself — it's still correctly sized and fully
> writable — only `df`'s and `mount`'s ability to display it. Use `stat -f` (as above)
> to check.

Set the mount's permission bits with `mode` (octal, same as `chmod`):

```bash
container run --rm --mount type=tmpfs,target=/tmpfsmount1,size=512M,mode=1777 alpine stat -c '%a' /tmpfsmount1
```

```console
1777
```

## Mount options

| Option | Values | Applies to | Description |
|---|---|---|---|
| `readonly` | no value, key only | bind mounts, named volumes | Mount read-only. With `--mount`, spell it `readonly`; with `--volume`, use `ro` instead (e.g. `--volume foo:/mnt/foo:ro`) — `--volume`'s colon-separated options are passed straight through to the mount syscall, which only recognizes `ro`, not `readonly`. |
| `size` | e.g. `10g`, `512m` | named volumes (create-time), tmpfs (mount-time) | For named volumes: volume size, set at creation time via `container volume create --opt size=<value>`, not a mount-time option. For tmpfs: a size *limit* on the memory-backed mount, set at mount time via `--mount type=tmpfs,size=<value>`. The same option name means something different depending on the mount type. |
| `journal` | `ordered`, `writeback`, `journal` | named volumes | Filesystem journal mode at creation time (via `container volume create --opt journal=<mode>`). |
| `mode` | octal, e.g. `1777` | tmpfs | Permission bits for the tmpfs mount point, set at mount time (via `--mount type=tmpfs,mode=<octal>`). |
