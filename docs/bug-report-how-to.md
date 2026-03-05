# How to File Effective Bug Reports

This guide helps you collect the essential information needed to file effective bug reports. Providing complete and accurate information helps maintainers reproduce and fix issues faster.

💡 **Example of a good bug report**: [Issue #1094](https://github.com/apple/container/issues/1094) demonstrates many of the best practices outlined in this guide.

## Steps to Reproduce

Clear reproduction steps are essential for maintainers to understand and fix the issue.

### What to Include
1. **Starting state**: What was your setup before the issue?
   - Fresh installation or existing project?
   - Any specific configuration files?
   - Previous commands that led to this state?

2. **Exact commands**: Copy-paste the exact commands you ran
   - Include all flags and arguments
   - Use code blocks for clarity

3. **Reproducibility**: Does it happen every time or intermittently?
   - Always reproducible
   - Happens sometimes (describe conditions)
   - Only happened once

### Writing Good Reproduction Steps
- Be specific about your setup and the commands you run
- Include any configuration changes
- Mention if steps work differently on different systems

### Example
```
1. Create new container: `container create --name test-app --image ubuntu:latest`
2. Start the container: `container run test-app`
3. Container fails during bootstrap with error:
   "failed to bootstrap container test-app"
4. Container exits with code 1
```

## Current Behavior

Describe exactly what happens in your failure scenario.

### What to Include
- Exact error messages (copy-paste, don't paraphrase)
- Exit codes or status indicators
- Performance issues (slowness, hangs, crashes)
- Unexpected outputs or results

## Expected Behavior

Describe what should happen instead when following the same reproduction steps.

### What to Include
- The correct output or result you anticipated
- Reference to documentation if available
- How it works in previous versions

### Sources for Expected Behavior
- Official documentation
- Previous working versions
- Logical expectations based on the command or action

## Environment Information

### Operating System Details
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

### Xcode Version
Get your Xcode version with:
```bash
xcodebuild -version
```

Example output:
```
Xcode 15.0
Build version 15A240d
```

### Container CLI Version
Check your Container CLI version (if you are on main, you can just put main):
```bash
container --version
```

Example output:
```
container CLI version 0.10.0.1 (build: release, commit: 1abc234)
```

## Log Information

### Finding Relevant Logs
When reporting issues, include logs that show:
- Error messages or stack traces
- Warning messages related to your issue
- Output from failed commands

### Getting Container Logs
For Container CLI issues, run commands with verbose output:
```bash
container --debug <command>
```

You can also use the `container logs` command to get logs from running containers:
```bash
container logs <container-name>
```

#### Useful Log Flags
- `--debug`: Shows detailed debugging information
  ```bash
  container logs --debug <container-name>
  ```
  
- `--follow` (or `-f`): Continuously streams new log output
  ```bash
  container logs --follow <container-name>
  ```
  
- Combine flags for maximum information:
  ```bash
  container logs --debug --follow <container-name>
  ```

### System Logs
If the issue involves system-level problems, check Console.app or use:
```bash
log show --predicate 'subsystem == "com.apple.container"' --last 1h
```

## Common Information Gaps

### Missing Context
- What were you trying to accomplish?
- What changed recently in your setup?
- Does the issue occur in a fresh installation from main?

### Incomplete Error Information
- Full error messages (not just the last line)
- Stack traces where relevant
- Related warning messages

### Environment Variations
- Does it work with a fresh container?
- Have your network settings changed?
- Have your Xcode or macOS versions chaged?
