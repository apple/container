# How to file effective bug reports

This guide helps you collect the essential information needed to file effective bug reports. Providing complete and accurate information helps maintainers reproduce and fix issues faster.

💡 **Example of a good bug report**: [Issue #1094](https://github.com/apple/container/issues/1094) demonstrates many of the best practices outlined in this guide.

## Steps to reproduce

Clear reproduction steps are essential for maintainers to understand and fix the issue.

### What to include
1. **Starting state**: What was your setup before the issue?
   - Fresh installation or existing project?
   - Any specific configuration files?
   - Previous commands that led to this state?
   - Has your machine recently been restarted?

2. **Exact commands**: Copy-paste the exact commands you ran
   - Include all flags and arguments
   - Use code blocks for clarity

3. **Reproducibility**: Does it happen every time or intermittently?
   - Always reproducible
   - Happens sometimes (describe conditions)
   - Only happened once

### Example
```
1. Create new container: `container create --name test-app ubuntu:latest`
2. Start the container: `container start test-app`
3. Container fails during bootstrap with error:
   "failed to bootstrap container test-app"
4. Container exits with code 1
```

## Problem description

Provide a comprehensive description of your problem. Include what currently happens (the bug), what you expect should happen instead, and any relevant log output.

### What to include

#### Current behavior
- Exact error messages (copy-paste, don't paraphrase)
- Exit codes or status indicators
- Performance issues (slowness, hangs, crashes)
- Unexpected outputs or results

#### Expected behavior
- The correct output or result you anticipated
- Reference to documentation if available
- How it works in previous versions (if applicable)
- Logical expectations based on the command or action

#### Relevant logs
Include any log output that helps illustrate the problem:
- Error messages or stack traces
- Warning messages related to your issue
- Output from failed commands
- Use verbose/debug flags to capture detailed information (see [Log Information](#log-information) section below for how to gather logs)

## Environment information

### Operating system details
Run this command in Terminal to get your macOS version:
```bash
sw_vers
```

Example output:
```
ProductName:		macOS
ProductVersion:		26.0
BuildVersion:		12A345
```

### Xcode version
Get your Xcode version with:
```bash
xcodebuild -version
```

Example output:
```
Xcode 15.0
Build version 15A240d
```

### Container CLI version
Check your Container CLI version:
```bash
container --version
```

Example output:
```
container CLI version 0.10.0-27-g9fd15f0 (build: debug, commit: 9fd15f0)
```

## Log information

### Finding relevant logs
When reporting issues, include logs that show:
- Error messages or stack traces
- Warning messages related to your issue
- Output from failed commands

### Getting container logs
For Container CLI issues, run commands with verbose output:
```bash
container --debug <command>
```

You can also use the `container logs` command to get logs from running containers. See the [container logs](command-reference.md#container-logs) documentation for full details.
```bash
container logs <container-id>
```

### System logs
For system-level container issues, use the built-in system logs command. See the [container system logs](command-reference.md#container-system-logs) documentation for full details.
```bash
container system logs
```

## Common information gaps

### Missing context
- What were you trying to accomplish?
- What changed recently in your setup?
- Does the issue occur in a fresh installation from main?

### Incomplete error information
- Full error messages (not just the last line)
- Stack traces where relevant
- Related warning messages

### Environment variations
- Does it work with a new instance of the container?
- Does it work with a fresh install of the Container package?
- Have your network settings changed?
- Have your Xcode or macOS versions changed?
