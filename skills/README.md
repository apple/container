# Skills

Agent skills for working with `container`. A skill teaches a coding agent this tool's command
surface — how it maps to `docker`, `lima`, `colima`, and `podman`, and where it differs.

## container

Covers the full command surface, the Docker command mapping, and the differences that
commonly trip people up (singular command groups, `-t` on builds, the three-step DNS setup,
container machines).

## container-troubleshooting

Localizes failures before changing system state. It covers host and service startup, XPC and
launchd errors, networking and DNS, image builds, container processes, port forwarding, mounts,
and container machines. A bundled collector gathers bounded diagnostics without restarting or
deleting anything; an opt-in smoke test verifies DNS and HTTPS from a disposable container.

## Install

Claude Code, from a local clone:

```bash
# in Claude Code, from anywhere
/plugin marketplace add /path/to/container
/plugin install container@apple-container
```

Or straight from GitHub, without a clone:

```bash
/plugin marketplace add apple/container
/plugin install container@apple-container
```

The skills load on demand. `container` handles ordinary workflows and command translation;
`container-troubleshooting` activates for failures, hangs, and diagnostic requests.

## Editing

Each `SKILL.md` is its skill's entry point. Keep it short and put branch-specific detail in that
skill's `references/` directory.

Document command *names* and behavior that surprises people. Do not paste exhaustive flag
lists — they drift. `container <command> --help` is authoritative, and the skill tells the
agent to use it.
