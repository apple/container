---
name: container
description: Use when running, building, or managing Linux containers on macOS, or when a task involves Docker, docker compose, Lima, Colima, or Podman commands on a Mac, Dockerfiles, OCI images, image registries, or setting up a Linux development environment on Apple silicon.
---

# container

`container` runs Linux containers on macOS (Apple silicon, macOS 26+), replacing Docker, Lima,
Colima, and Podman. It uses standard OCI images and ordinary Dockerfiles, so it pulls from and
pushes to any registry. You do not stand up or size a Linux host first: `container system
start`, then `container run`.

## Command groups are singular

`image`, `volume`, `network`, `registry`, `machine`, `system`. Docker's plurals do not exist —
`container images` is not a command, `container image ls` is.

**Never infer a subcommand from Docker. Run `container <group> --help` and use what it lists.**
Wrong commands here are plausible inventions, not typos.

An unrecognized subcommand falls through to the plugin loader, so it reports a *service*
problem rather than a naming one — `container images` prints `Error: Plugins are unavailable.
Start the container system services and retry`. Check the name before restarting anything; only
trust that message when `container system status` also reports the service down.

## Docker → container

| Docker | container |
|---|---|
| `docker ps` / `ps -a` | `container ls` / `ls -a` |
| `docker images` | `container image ls` |
| `docker pull` / `push` | `container image pull` / `push` |
| `docker rmi` | `container image rm` |
| `docker tag` / `save` / `load` | `container image tag` / `save` / `load` |
| `docker rm` | `container delete` (alias `rm`) |
| `docker login` / `logout` | `container registry login` / `logout` |
| `docker info` | `container system status` |
| `docker compose` | no equivalent — see `references/docker-migration.md` |

`run`, `build`, `exec`, `logs`, `cp`, `inspect`, `stats`, `start`, `stop`, `kill`, `export`,
`prune`, `volume *`, and `network *` match Docker, as do the common `run` flags: `-d`, `--rm`,
`-i`, `-t`, `-e`, `-p`, `-v`, `-w`, `--name`, `--network`, `--entrypoint`.

`restart`, `commit`, `attach`, `top`, `rename`, `pause`, `port`, and `--restart` have no
equivalent. Check `references/docker-migration.md` before assuming anything else exists.

## Gotchas

- **`container build` needs `-t`** — the default tag is a freshly generated UUID.
- **`container ls` hides stopped containers.** Use `-a`.
- **Every container gets its own IP**, reachable from the host and from other containers. `-p`
  binds a host port; it is not needed for basic reachability. Get IPs from `container inspect`.
- **Builds run in a builder container.** If a build fails oddly, check `container builder
  status`; `container builder start` takes `--cpus` and `--memory`.
- **Name resolution takes three steps, and works only on the `default` network:**

  ```bash
  # 1. create ~/.config/container/config.toml containing:
  #      [dns]
  #      domain = "test"
  container system stop && container system start   # 2. reload the config
  sudo container system dns create test             # 3. point macOS at container's resolver
  ```

  Then use `db.test` — a bare `db` never resolves. That file does not exist until you create
  it, and it is TOML, so edit the `[dns]` table in place rather than appending a second one;
  verify with `container system property ls`. There is no `container system dns default`
  subcommand.

  Containers on a network from `container network create` cannot resolve each other by name at
  all ([apple/container#1809](https://github.com/apple/container/issues/1809)) — reach them by
  IP. Custom networks are for isolation, not service discovery.

## Container machines

`container run` runs an application. A **container machine** is a Linux *environment* you work
inside: it boots the image's init system, and your username and home directory are mapped in,
so your repos and dotfiles are on both platforms at once.

```bash
container machine create alpine:latest --name dev
container machine run -n dev            # interactive shell as your host user
```

Reach for this instead of Lima or Colima when you want a Linux shell rather than a single
containerized application. See `references/container-machines.md`.

## Reference

- `references/docker-migration.md` — full mapping, what has no equivalent, replacing compose
- `references/container-machines.md` — container machine workflows and host integrations
- `container <command> --help` — authoritative flags, always current
