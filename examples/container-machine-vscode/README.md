# Example: Develop Linux applications in a container machine with Visual Studio Code

This example shows you how to use a container machine to develop for Linux on your Mac using Visual Studio Code and its SSH remote development extension.

## Prerequisites

Install and start before running the demo:

- Apple `container`
- Microsoft Visual Studio Code, including the **Visual Studio Code Remote - SSH** extension

## Container machine overview

The `container machine` subcommand allows you to run fast, persistent Linux environments that integrate tightly with your macOS host.

To create a container machine, all you need to do is provide a machine name, and a machine image reference:

```console
% container machine create --name mymachine --set-default alpine:3.22
mymachine
```

Display a list of container machines with:

```console
% container machine ls
NAME       CREATED              IP             CPUS  MEMORY  DISK  STATE    DEFAULT
mymachine  2026-06-03 15:56:14  192.168.71.15  8     64G     75M   running  *
```

Run individual Linux commands with `container machine run` and the command:

```console
% container machine run uname -a
Linux mymachine-dce75a 6.18.15-cz-325d33a88139 #1 SMP Mon Apr 20 22:39:49 UTC 2026 aarch64 Linux
```

Display your macOS working directory and username, start a shell session in the container machine, and compare the working directory and username in the container machine:

```console
% pwd
/Users/max-mustermann/projects/container/examples/container-machine-vscode
% whoami
john
% container machine run
$ pwd
/Users/max-mustermann/projects/container/examples/container-machine-vscode
$ whoami
john
$ exit
%
```

Typically, you'll keep container machines for longer than a typical container. When you're ready to delete a container machine and its persistent filesystem, run:

```console
% container machine stop mymachine
mymachine
% container machine rm mymachine
mymachine
Deleted default container 'mymachine'. Set a new default with 'container machine set-default <id>'.
```

## Develop in a container machine

### SSH and DNS setup

On your Mac, add an SSH configuration entry for the container machine, so that it will appear as an option when you connect to the container machine with Visual Studio Code later:

```bash
cat >> ~/.ssh/config <<EOT

Host ubuntu.machine
   HostName ubuntu.machine
   ForwardAgent yes
   UserKnownHostsFile /dev/null
EOT
```

Add a locally scoped domain named `machine` to your macOS DNS configuration:

```bash
sudo container system dns create machine
```

### Build the machine image

On your Mac:

```bash
container build -t ubuntu-machine:latest -f Dockerfile .
```

### Container machine setup

On your Mac, create a container machine named `ubuntu` using the image you built:

```bash
container machine create --set-default --name ubuntu ubuntu-machine:latest
```

Set up a password for SSH login to the container machine:

```bash
container machine run -it sudo passwd $(whoami)
```

You can ping the container machine to see that DNS is working:

```bash
ping -c 1 ubuntu.machine
```

You can also start a shell in the machine to run ad-hoc commands:

```bash
container machine run
```

### Set up the project

On your Mac, clone the `swift-server-todos-tutorial` project:

```bash
cd ${HOME}
git clone git@github.com:swiftlang/swift-server-todos-tutorial.git
```

In the Visual Studio Code application, connect to the container machine and install the Swift extension:

- Press ⌘-SHIFT-P and run the **Remote-SSH: Connect to Host** command
- Select the `ubuntu.machine` entry
- In the new Visual Studio Code window that opens, enter `yes` at the ssh fingerprint verification prompt
- Enter the SSH password you configured at the authentication prompt
- In the extensions sidebar of the new Visual Studio Code window, install the Swift (`swiftlang.swift-vscode`) extension

### Build and run

In the new Visual Studio Code window, open the project folder (substituting your macOS username) at `/Users/max-mustermann/swift-server-todos-tutorial`.

Restart the LSP server in response to the toast notification that appears.

Open the LSP build terminal output window and watch its progress. This takes a couple of minutes for a totally clean project.

Open another terminal in the Visual Studio Code window to get a shell, and verify that you're running on an Ubuntu Linux system:

```bash
uname -s
cat /etc/os-release | grep PRETTY_NAME
```

Build the project:

```bash
swift build
```

While the project builds, press ⌘-SHIFT-P and run the **Open 'launch.json'** command.

Click the **Add configuration...** button and select the **Swift: Launch** option.

Replace the `<program>` placeholder in the newly added launch configuration, so that it looks like:

```json
        {
            "type": "swift",
            "request": "launch",
            "name": "Launch Swift Executable",
            "program": "${workspaceRoot}/.build/debug/SwiftServerTodos",
            "args": [],
            "env": {},
            "cwd": "${workspaceRoot}"
        },
```

Run the application by selecting the Run and Debug sidebar, selecting the **Launch Swift Executable** item, and clicking the play button.

Open the `Telemetry.swift` file and set a breakpoint on the innermost statement of the `RequestLoggerInjectionMiddleware.respond()` function.

From a terminal on your Mac, try a request to the service:

```bash
curl http://ubuntu.machine:8080/todos
```

Observe that the application hits the breakpoint and that you can inspect the request, and then remove the breakpoint and continue execution.

On the terminal, you should see output similar to:

```console
[{"id":"BDAD25BA-8F52-4A7A-B98D-319AD86179B7","contents":"example todo"}]
```

### Clean up

When you're ready to dispose of your container machine, run on your Mac:

```bash
container machine stop ubuntu
container machine rm ubuntu
container image rm ubuntu-machine:latest
```

Then remove the test project:

```bash
rm -rf swift-server-todos-tutorial
```

To remove the entry from your SSH configuration file, run:

```bash
awk -v h="ubuntu.machine" '/^Host /{skip=($2==h)} !skip' ~/.ssh/config > /tmp/.sshconf && mv /tmp/.sshconf ~/.ssh/config
```

To clean up the local DNS entry, run:

```bash
sudo container system dns delete machine
```
