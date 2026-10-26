---
name: container-troubleshooting
description: Diagnose failures in Apple's container CLI on macOS. Use when container commands fail or hang, services do not start, or image pulls, builds, networking, DNS, ports, mounts, container processes, or container machines behave unexpectedly. Do not use for ordinary successful workflows or Docker command translation; use the container skill instead.
---

# container troubleshooting

Localize before repair. Preserve the first failure, identify the failing layer, and change only
that layer. A restart can erase the evidence that distinguishes a launchd failure from a guest,
network, or application failure.

## Gather evidence

1. Capture the exact command, complete error, exit status, expected result, and whether the
   failure is consistent. Add `--debug` when it is supported and the command line does not
   contain credentials or other secrets.
2. Run the bundled collector from this skill directory:

   ```bash
   bash scripts/diagnose.sh
   ```

   The default collector is read-only. It does not start or stop services, create containers,
   or delete data. Add `--smoke-test` only when pulling `alpine:latest` and running a disposable
   container is acceptable:

   ```bash
   bash scripts/diagnose.sh --smoke-test
   ```

3. Review output before sharing it. Container names, image references, routes, IP addresses,
   filesystem paths, and recent system logs can reveal private environment details.

## Classify the failure

| Evidence | Failing layer | Next reference |
|---|---|---|
| CLI absent, unsupported host, `system start` failure, XPC error, or unhealthy service | Host or system service | Read [system and network failures](references/system-and-network.md). |
| Image pulls, but a running container cannot reach an IP or resolve an external name | Guest networking or DNS | Read [system and network failures](references/system-and-network.md). |
| External names resolve, but container names do not | Container name resolution | Read [system and network failures](references/system-and-network.md). |
| Pull, build, process, port, mount, or container machine failure | Build or runtime | Read [build and runtime failures](references/build-and-runtime.md). |
| The command or subcommand may be inferred from Docker | Command selection | Read the sibling [`container` skill](../container/SKILL.md) and confirm with `container <command> --help`. |

Do not diagnose application output from system logs alone. Use `container logs` for the process,
`container logs --boot` for its Linux VM, and `container system logs` for macOS-side services.

## Correct and verify

- If the user asked only for diagnosis, report the cause and stop before changing state.
- Capture status and logs before a service or builder restart. Ask first if a restart can interrupt
  active containers or builds.
- Do not uninstall, prune, delete a builder, container, image, network, volume, or container
  machine unless the user explicitly authorizes that scope. A container machine and a volume can
  contain persistent data.
- Treat disabling a VPN, changing DNS, editing routes, installing a kernel, and changing security
  software as user-visible system changes. Use them only to test a supported hypothesis.
- After a correction, rerun the exact failed command. Then run one narrower probe that confirms
  the repaired layer. Do not claim the application is fixed from a generic smoke test.

If the failure remains, prepare an issue-quality summary from the captured evidence. Do not post
logs or open an issue unless the user asks. Follow the repository's
[bug-report guide](../../docs/bug-report-how-to.md) and link any known issue whose error and
conditions match; do not turn a similar issue into a confirmed cause.
