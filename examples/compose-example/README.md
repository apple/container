# Example: Run multi-container applications with container-compose

This example shows you how to use `container-compose` to bring up a multi-service application defined in a standard `docker-compose.yml` file using Apple's `container` CLI.

## Prerequisites

Install and start before running the demo:

- Apple `container`, with the system service running (`container system start`)
- Python 3.11 or later
- PyYAML: `pip3 install pyyaml --break-system-packages`

## Install container-compose

Copy the script to a directory on your `PATH`:

```bash
cp container-compose /usr/local/bin/container-compose
chmod +x /usr/local/bin/container-compose
```

Verify the installation:

```console
% container-compose --help
usage: container-compose [-h] [-f FILE] [-p NAME] {up,down,ps,logs,exec,build,pull,stop,start,restart,rm,run,config} ...
```

## The example application

The `docker-compose.yml` in this directory describes three services:

- **redis** — a Redis cache with a named volume and resource limits
- **api** — a Node.js application that depends on `redis`, built from a local `Dockerfile`
- **web** — an nginx front-end that depends on both `redis` and `api`

```
web ──depends_on──► api ──depends_on──► redis
```

## Start the application

From this directory, start all services in dependency order:

```console
% container-compose up
+ container network create compose-example_frontend
+ container network create compose-example_backend
+ container volume create compose-example_redis-data
+ container run --name compose-example-redis-1 -d ... redis:alpine
+ container run --name compose-example-api-1 -d ... myapp/api:latest
+ container run --name compose-example-web-1 -d ... nginx:latest
```

`up` runs detached by default. To stream output to the terminal instead, use `--no-detach`.

## Check service status

```console
% container-compose ps
NAME                                     SERVICE              STATUS
compose-example-redis-1                  redis                running
compose-example-api-1                    api                  running
compose-example-web-1                    web                  running
```

## View logs

Print recent output from all services:

```bash
container-compose logs
```

Follow log output from a specific service:

```bash
container-compose logs -f web
```

Show only the last 20 lines:

```bash
container-compose logs --tail 20
```

## Run a command inside a service

Open a shell in the running `redis` container:

```bash
container-compose exec redis sh
```

Run a one-off command without affecting the running container:

```bash
container-compose run --rm api node --version
```

## Rebuild and restart a service

If you change the `api` source code:

```bash
container-compose build api
container-compose restart api
```

Or rebuild everything before starting:

```bash
container-compose up --build
```

## Stop and remove

Stop all services without removing them:

```bash
container-compose stop
```

Remove all containers and the project networks:

```bash
container-compose down
```

Also remove the named `redis-data` volume:

```bash
container-compose down -v
```

## Run with a custom project name

By default the project name is the current directory name (`compose-example`). Override it to run multiple isolated instances side by side:

```bash
container-compose -p staging up
container-compose -p production up
```

## See also

- [`docs/container-compose.md`](../../docs/container-compose.md) — full reference for supported keys and known limitations
- [`container-compose`](./container-compose) — the script itself
