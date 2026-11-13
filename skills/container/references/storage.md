# Storage

`container` keeps its data under `~/Library/Application Support/com.apple.container` (or
`$CONTAINER_APP_ROOT`). Each named volume, each container's writable filesystem, and each
unpacked image snapshot is its own sparse disk image that can grow to 512 GiB. Nothing caps the
total or prunes on its own
([apple/container#2319](https://github.com/apple/container/issues/2319)), and deleting files
inside a container or volume frees nothing on the Mac. Space comes back only when you delete
the volume, container, image, or builder, or run `container clean` on a running container.

The project's `docs/resource-usage.md` ("Disk usage") lists the commands. This file covers how
to use them without filling the disk or deleting someone else's data.

## Size and name what you create

```bash
container volume create -s 20g myrepo-build      # cap it; the default is 512 GiB
container build -t myrepo-dev:latest .
container run --rm -v myrepo-build:/cache myrepo-dev:latest
```

- Give each task its own volume, named for the task, with `-s` sized to the job. A volume
  shared across tasks or agents grows to hold everything any of them wrote.
- `-v /path` with no source creates an anonymous volume, and `--rm` does *not* delete it (see
  the project's `docs/volumes.md`). Prefer a named volume you will delete.

## Clean up by name

Before finishing, delete what the task created, by name, and check the totals:

```bash
container volume delete myrepo-build
container image delete myrepo-dev:latest
container system df
```

Do not run these without the user's go-ahead. They act on everything, including volumes and
images the user or another session still needs, and a deleted volume cannot be recovered:

- `container volume prune` deletes every volume that no container references, named volumes
  included. A volume used only by `--rm` runs has no container between runs, so it goes too.
- `container volume delete --all`, `container image delete --all`, `container image prune -a`.
- `container builder delete` throws away the builder's whole layer cache
  ([apple/container#932](https://github.com/apple/container/issues/932)).

## Measure

`container system df` shows totals per type only, and `container volume list` has no size
column ([apple/container#2449](https://github.com/apple/container/issues/2449)). The volume
RECLAIMABLE figure in `container system df` counts every volume `container volume prune` would
delete, including named volumes someone still needs.

FULL SIZE in `container image list --verbose` is the size of the image's compressed layers. It
leaves out the unpacked snapshot, which `container system df` includes.

To find what is large:

```bash
root="${CONTAINER_APP_ROOT:-$HOME/Library/Application Support/com.apple.container}"
du -sh "$root"/*            # by kind
du -sh "$root"/volumes/*    # by volume name
```

Use `du`. `container volume inspect` reports the size a sparse image can grow to; `du` reports
the blocks it holds. Each container's filesystem starts as an APFS clone of its image snapshot,
and `du` counts shared blocks once per clone, so the `containers/` total can include space
already counted under `snapshots/`. What a container writes after it starts is its own.
