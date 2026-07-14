# Volumes

Share data from your host with containers, and create named volumes with better
performance and lifecycle guarantees than bind mounts.

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

> [!NOTE]
> Unlike Docker, anonymous volumes created implicitly by a container do not
> auto-cleanup when the container is removed with `--rm`. Delete them explicitly with
> `container volume delete`.

Mount a named volume the same way you bind-mount a host directory, using the volume
name as the source:

```bash
container run -it --rm --volume foo:/mnt/foo alpine sh
```

Or with `--mount`:

```bash
container run -it --rm --mount type=volume,source=foo,target=/mnt/foo alpine sh
```

## Named volume mount options

| Option | Values | Description |
|---|---|---|
| `readonly` | no value, key only | Mount the volume read-only |
| `size` | e.g. `10g`, `512m` | Volume size at creation time (via `container volume create --opt size=<value>`, not a mount-time option) |
| `journal` | `ordered`, `writeback`, `journal` | Filesystem journal mode at creation time (via `container volume create --opt journal=<mode>`) |
