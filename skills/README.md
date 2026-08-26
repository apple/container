# Skills

Agent skills for working with `container`. A skill teaches a coding agent this tool's command
surface — how it maps to `docker`, `lima`, `colima`, and `podman`, and where it differs.

## container

Covers the full command surface, the Docker command mapping, and the differences that
commonly trip people up (singular command groups, `-t` on builds, the three-step DNS setup,
container machines).

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

The skill loads on demand — it activates when a task involves containers, Dockerfiles, or
images on macOS, and stays out of the way otherwise.

## Editing

`skills/container/SKILL.md` is the always-loaded surface, so keep it short and put detail in
`skills/container/references/`.

Document command *names* and behavior that surprises people. Do not paste exhaustive flag
lists — they drift. `container <command> --help` is authoritative, and the skill tells the
agent to use it.
