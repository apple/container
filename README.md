# `container`

![introductory movie showing some basic commands](./docs/assets/landing-movie.gif)

`container` is an application that you can use to create and run Linux containers as lightweight virtual machines on your Mac. It's written in Swift, and optimized for Apple Silicon. 

The application consumes and produces OCI-compliant container images, so you can pull and run images from any standard container registry. You can push images that you build to those registries as well, and run the images in any other OCI-compliant application.

`container` uses the [Containerization](https://github.com/apple/containerization) Swift package for low level container, image and process management.

## Get started

Install the `container` application on your Mac.

### Requirements

You need an Apple Silicon Mac to build and run `container`.

To build the Containerization package, your system needs either:

- macOS 15 or newer and Xcode 17 beta.
- macOS 16 Developer Preview.

`container` is designed to take advantage of the features of the macOS 16 Developer Preview. You can run the application on macOS Sequoia, but the `container` maintainers typically will not address Sequoia issues that cannot be reproduced on the macOS 16 Developer Beta.

There are [significant networking limitations](https://github.com/apple/container#macos-sequoia-limitations) that impact the usability `container` on macOS Sequoia.

### Install or upgrade

If you're upgrading, first uninstall your existing `container` while preserving your user data:

```bash
uninstall-container.sh -k
```

Download the latest application installer package from the [Github release page](https://github.com/apple/container/releases).

To install the application, double click the package file and follow the instructions. Enter your administrator password when prompted to give the installer permission to place the application under `/usr/local`.

### Uninstall

Use the `uninstall-container.sh` script to remove the application from your system. To remove your user data along with the application, run:

```bash
uninstall-container.sh -d
```

To retain your user data so that it is available should you reinstall later, run:

```bash
uninstall-container.sh -k
```

## Tutorial

Take a guided tour of `container` by building, running, and publishing a simple web server image.

### Try out the `container` CLI

Start the application, and try out some basic commands to familiarize yourself with the command line interface (CLI) tool.

#### Start the container service

Start the services that `container` uses:

```bash
container system start
```

If you have not installed a Linux kernel yet, the command will prompt you to install one:

```shellsession
% container system start
Verifying apiserver is running...
Done
Missing required runtime dependencies:
 1. Initial Filesystem
 2. Kernel
Would like to install them now? [Y/n]: Y
Installing default kernel from [https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz]...
Installing initial filesystem from [ghcr.io/apple/containerization/vminit:0.1.34]...
%
```

Then, verify that the application is working by running a command to list all containers:

```bash
container list --all
```

If you haven't created any containers yet, the command outputs an empty list:

```shellsession
% container list --all
ID  IMAGE  OS  ARCH  STATE  ADDR
%
```

#### Get CLI help

You can get help for any `container` CLI command by appending the `--help` option:

```shellsession
% container --help
OVERVIEW: A container platform for macOS

USAGE: container [--debug] <subcommand>

OPTIONS:
  --debug                 Enable debug output [environment: CONTAINER_DEBUG]
  --version               Show the version.
  -h, --help              Show help information.

CONTAINER SUBCOMMANDS:
  create                  Create a new container
  delete, rm              Delete one or more containers
  exec                    Run a new command in a running container
  inspect                 Display information about one or more containers
  kill                    Kill one or more running containers
  list, ls                List containers
  logs                    Fetch container stdio or boot logs
  run                     Run a container
  start                   Start a container
  stop                    Stop one or more running containers

IMAGE SUBCOMMANDS:
  build                   Build an image from a Dockerfile
  images, image, i        Manage images
  registry, r             Manage registry configurations

SYSTEM SUBCOMMANDS:
  builder                 Manage an image builder instance
  system, s               Manage system components

%
```

#### Abbreviations

You can save keystrokes by abbreviating commands and options. For example, abbreviate the `container list` command to `container ls`, and the `--all` option to `-a`:

```shellsession
% container ls -a
ID  IMAGE  OS  ARCH  STATE  ADDR
%
```

Use the `--help` flag to see which abbreviations exist.

#### Set up a local DNS domain (optional)

`container` includes an embedded DNS service that simplifies access to your containerized applications. If you want to configure a local DNS domain named `test` for this tutorial, run:

```bash
sudo container system dns create test
```

Enter your administrator password when prompted. The command requires administrator privileges to create a file containing the domain configuration under the `/etc/resolver` directory, and to tell the macOS DNS resolver to reload its configuration files.

### Build an image

Set up a `Dockerfile` for a basic Python web server, and use it to build a container image named `web-test`.

#### Set up a simple project

Start a terminal, create a directory named `web-test` for the files needed to create the container image:

```bash
mkdir web-test
cd web-test
```

Download an image file for your web server can use:

```bash
curl -L -o logo.jpg https://github.com/apple/container/tree/main/docs/assets/logo.jpg
```

In the `web-test` directory, create a file named `Dockerfile` with this content:

```docker
FROM docker.io/python:slim
WORKDIR /content
COPY logo.jpg ./
RUN echo '<!DOCTYPE html><html><head><title>Hello</title></head><body><p><img src="logo.jpg" style="width: 2rem; height: 2rem;">Hello, world!</p></body></html>' > index.html
CMD ["python3", "-m", "http.server", "80", "--bind", "0.0.0.0"]
```

The `FROM` line instructs the `container` builder to start with a base image containing the latest production version of Python 3.

The `WORKDIR` line creates a directory `/content` in the image, and makes it the current directory.

The `COPY` command copies the image file `logo.jpg` from your build context to the image. See the following section for a description of the build context.

The `RUN` line creates a simple HTML landing page named `/content/index.html`.

The `CMD` line configures the container to run a simple web server in Python on port 80. Since the working directory is `/content`, the web server runs in that directory and delivers the content of the file `/content/index.html` when a user requests the index page URL.

The server binds to the wildcard address `0.0.0.0` to allow connections from the host and other containers. To ensure security, the virtual network used by the containers is not accessible by external systems.

#### Build the web server image

Run the `container build` command to create an image with the name `web-test` from your `Dockerfile`:

```bash
container build --tag web-test --file Dockerfile .
```

The last argument `.` tells the builder to use the current directory (`web-test`) as the root of the build context. You can copy files within the build context into your image using the `COPY` command in your Dockerfile.

After the build completes, list the images. You should see both the base image and the image that you built in the results:

```shellsession
% container images list
NAME                      TAG     DIGEST
docker.io/library/python  slim    56a11364ffe0fee3bd60af6d...
web-test                  latest  bf91dc9d42f0110d3aac41dd...
%
```

### Run containers

Using your container image, run a web server and try out different ways of interacting with it.

#### Start the webserver

Use `container run` to start a container named `my-web-server` that runs your webserver:

```bash
container run --name my-web-server --dns-domain test --detach --rm web-test
```

The `--detach` flag runs the container in the background, so that you can continue running commands in the same terminal. The `--rm` flag causes the container to be removed automatically after it stops.

When you list containers now, `my-web-server` is present, along with the container that `container` started to build your image. Note that its IP address, shown in the `ADDR` column, is `192.168.64.3`:

```shellsession
% container ls
ID             IMAGE                                                   OS     ARCH   STATE    ADDR
buildkit       ghcr.io/apple/container-builder-shim/builder:2.1.1  linux  arm64  running  192.168.64.2
my-web-server  web-test:latest                                         linux  arm64  running  192.168.64.3
%
```

Open the website, using the container's IP address in the URL:

```bash
open http://192.168.64.3
```

If you configured the local domain `test` earlier in the tutorial, you can also open the page the full hostname for the container:

```bash
open http://my-web-server.test
```

#### Run other commands in the container

You can run other commands in `my-web-server` by using the `container exec` command. To list the files under the content directory, run an `ls` command:

```shellsession
% container exec my-web-server ls /content
index.html
logo.jpg
%
```

If you want to poke around in the container, run a shell and issue one or more commands:

```shellsession
% container exec --tty --interactive my-web-server bash
root@my-web-server:/content# ls
index.html  logo.jpg
root@my-web-server:/content# uname -a
Linux my-web-server 6.1.68 #1 SMP Mon Mar 31 18:27:51 UTC 2025 aarch64 GNU/Linux
root@my-web-server:/content# exit
exit%
```

The `--tty` and `--interactive` flag allow you to interact with the shell from your host terminal. The `--tty` flag tells the shell in the container that its input is a terminal device, and the `--interacive` flag connects what you input in your host terminal to the input of the shell in the container.

You will often see these two options abbreviated and specified together as `-ti` or `-it`.

#### Access the web server from another container

Your web server is accessible from other containers as well as from your host. Launch a second container using your `web-test` image, and this time, specify a `curl` command to retrieve the `index.html` content from the first container.

```shellsession
% container run -it --rm web-test curl http://192.168.64.3
<!DOCTYPE html><html><head><title>Hello</title></head><body><p><img src="logo.jpg" style="width: 2rem; height: 2rem;">Hello, world!</p></body></html>
%
```

If you set up the `test` domain earlier, you can achieve the same result with:

```bash
container run -it --rm web-test curl http://my-web-server.test
```

### Run a published image

Push your image to a container registry, publishing it so that you and others can use it. 

#### Publish the web server image

To publish your image, you need push images to a registry service that stores the image for future use. Typically, you need to authenticate with a registry to push an image. This example assumes that you have an account at a hypothetical registry named `registry.example.com` with username `fido` and a password or token `my-secret`, and that your personal repository name is the same as your username.

To sign into a secure registry with your login credentials, enter your username and password at the prompts after running:

```bash
container registry login registry.example.com
```

Create another name for your image that includes the registry name, your repository name, and the image name, with the tag `latest`:

```bash
container images tag web-test registry.example.com/fido/web-test:latest
```

Then, push the image:

```bash
container images push registry.example.com/fido/web-test:latest
```

#### Pull and run your image

To validate your published image, remove your existing web server image, and then run using the remote image:

```bash
container images delete web-test registry.example.com/fido/web-test:latest
container run --name my-web-server --dns-domain test --detach --rm registry.example.com/fido/web-test:latest
```

### Clean up

Stop your container and shut down the application.

#### Shut down the web server

Stop your web server container with:

```bash
container stop my-web-server
```

If you list all running and stopped containers, you will see that the `--rm` flag you supplied with the `container run` command caused the container to be removed:

```bash
% container ls --all
ID        IMAGE                                                   OS     ARCH   STATE    ADDR
buildkit  ghcr.io/apple/container-builder-shim/builder:2.1.1  linux  arm64  running  192.168.64.2
%
```

To shut down and remove all containers, run:

```bash
container rm --all --force
```

#### Stop the container service

When you want to stop `container` completely, run:

```bash
container system stop
```

## How-to

How to use the features of `container`.

### Configure memory and CPUs for your containers

Since the containers created by `container` are lightweight virtual machines, you need to consider the needs of your containerized application when you `container run` a container.  The `--memory` and `--cpus` options allow you to override the default memory and CPU limits for the virtual machine. The default values are 1 gigabyte of RAM and 4 CPUs. You can use abbreviations for memory units; for example, to run a container for image `big` with 8 CPUs and 32 gigabytes of memory, use:

```bash
container run --rm --cpus 8 --memory 32g big
```

### Configure memory and CPUs for large builds

When you first run `container build`, `container` starts a *builder*, which is a utility container that performs image build. As with anything you run with `container run`, the builder runs in a lightweight virtual machine, so for resource-intensive builds, you may need to increase the memory and CPU limits for the builder VM.

By default, the builder VM receives 2 gigabytes of RAM and 2 CPUs. You can change these limits by starting the builder container before running `container build`:

```bash
container builder start --cpus 8 --memory 32g
```

If your builder is already running and you need to modify the limits, just stop, delete, and restart the builder:

```bash
container builder stop
container builder delete
container builder start --cpus 8 --memory 32g
```

### Share host files with your container

With the `--volume` option of `container run`, you can share data between the host system and one or more containers, and you can persist data across multiple container runs. The volume option allows you to mount a folder on your host to a filesystem path in the container.

This example mounts a folder named `assets` on your Desktop to the directory `/content/assets` in a container:

```shellsession
% ls -l ~/Desktop/assets
total 8
-rw-r--r--@ 1 fido  staff  2410 May 13 18:36 link.svg
% container run --volume ${HOME}/Desktop/assets:/content/assets docker.io/python:slim ls -l /content/assets
total 4
-rw-r--r-- 1 root root 2410 May 14 01:36 link.svg
%
```

The argument to `--volume` in the example consists of the full pathname for the host folder and the full pathname for the mount point in the container, separated by a colon.

The `--mount` option uses a comma separated `key=value` syntax to achieve the same result:

```shellsession
% container run --mount source=${HOME}/Desktop/assets,target=/content/assets docker.io/python:slim ls -l /content/assets
total 4
-rw-r--r-- 1 root root 2410 May 14 01:36 link.svg
%
```

### Build and run a multiplatform image

Using the [project from the tutorial example](/documentation/tutorial/#set-up-a-simple-project), you can create an image to use both on Apple Silicon Macs and on AMD64 servers.

When building the image, just add `--arch` options that directs the builder to create an image supporting both the `arm64` and `amd64` architectures:

```bash
container build --arch arm64 --arch amd64 --tag registry.example.com/fido/web-test:latest --file Dockerfile .
```

Try running the command `uname -a` with the `arm64` variant of the image to see the system information that the virtual machine reports:

```shellsession
% container run --arch arm64 --rm registry.example.com/fido/web-test:latest uname -a
Linux 7932ce5f-ec10-4fbe-a2dc-f29129a86b64 6.1.68 #1 SMP Mon Mar 31 18:27:51 UTC 2025 aarch64 GNU/Linux
%
```

When you run the command with the `amd64` architecture, the AMD64 version of `uname` of Python using Rosetta translation, so that you will see information for an AMD64 system:

```shellsession
container run --arch amd64 --rm registry.example.com/fido/web-test:latest uname -a
Linux c0376e0a-0bfd-4eea-9e9e-9f9a2c327051 6.1.68 #1 SMP Mon Mar 31 18:27:51 UTC 2025 x86_64 GNU/Linux
```

The command to push your multiplatform image to a registry is no different than that for a single-platform image:

```bash
container images push registry.example.com/fido/web-test:latest
```

### Get container or image details

`container images list` and `container list` provide basic information for all of your images and containers. You can also use `list` and `inspect` commands to print detailed JSON output for one or more resources.

Use the `inspect` command and send the result to the `jq` command to get pretty-printed JSON for the images or containers that you specify:

```shellsession
% container images inspect web-test | jq       
[
  {
    "name": "web-test:latest",
    "variants": [
      {
        "platform": {
          "os": "linux",
          "architecture": "arm64"
        },
        "config": {
          "created": "2025-05-08T22:27:23Z",
          "architecture": "arm64",
...
% container inspect my-web-server | jq
[
  {
    "status": "running",
    "networks": [
      {
        "address": "192.168.64.3/24",
        "gateway": "192.168.64.1",
        "hostname": "my-web-server.test.",
        "network": "default"
      }
    ],
    "configuration": {
      "mounts": [],
      "hostname": "my-web-server",
      "id": "my-web-server",
      "resources": {
        "cpus": 4,
        "memoryInBytes": 1073741824,
      },
...
```

Use the `list` command with the `--format` option to display information for all images or containers. In this example, the `--all` option shows stopped as well as running containers, and `jq` selects the IP address for each running container:

```shellsession
% container ls --format json --all | jq '.[] | select ( .status == "running" ) | [ .configuration.id, .networks[0].address ]'
[
  "my-web-server",
  "192.168.64.3/24"
]
[
  "buildkit",
  "192.168.64.2/24"
]
```

### View container logs

The `container logs` command displays the output from your containerized application:

```shellsession
% container run -d --dns-domain test --name my-web-server --rm registry.example.com/fido/web-test:latest
my-web-server
% curl http://my-web-server.test                                                                                   
<!DOCTYPE html><html><head><title>Hello</title></head><body><p><img src="logo.jpg" style="width: 2rem; height: 2rem;">Hello, world!</p></body></html>
% container logs my-web-server                                                                            
192.168.64.1 - - [15/May/2025 03:00:03] "GET / HTTP/1.1" 200 -
%
```

Use the `--boot` option to see the logs for the virtual machine boot and init process:

```shellsession
% container logs --boot my-web-server
[    0.098284] cacheinfo: Unable to detect cache hierarchy for CPU 0
[    0.098466] random: crng init done
[    0.099657] brd: module loaded
[    0.100707] loop: module loaded
[    0.100838] virtio_blk virtio2: 1/0/0 default/read/poll queues
[    0.101051] virtio_blk virtio2: [vda] 1073741824 512-byte logical blocks (550 GB/512 GiB)
...
[    0.127467] EXT4-fs (vda): mounted filesystem without journal. Quota mode: disabled.
[    0.127525] VFS: Mounted root (ext4 filesystem) readonly on device 254:0.
[    0.127635] devtmpfs: mounted
[    0.127773] Freeing unused kernel memory: 2816K
[    0.143252] Run /sbin/vminitd as init process
2025-05-15T02:24:08+0000 info vminitd : [vminitd] vminitd booting...
2025-05-15T02:24:08+0000 info vminitd : [vminitd] serve vminitd api
2025-05-15T02:24:08+0000 debug vminitd : [vminitd] starting process supervisor
2025-05-15T02:24:08+0000 debug vminitd : port=1024 [vminitd] booting grpc server on vsock
...
2025-05-15T02:24:08+0000 debug vminitd : exits=[362: 0] pid=363 [vminitd] checking for exit of managed process
2025-05-15T02:24:08+0000 debug vminitd : [vminitd] waiting on process my-web-server
[    1.122742] IPv6: ADDRCONF(NETDEV_CHANGE): eth0: link becomes ready
2025-05-15T02:24:39+0000 debug vminitd : sec=1747275879 usec=478412 [vminitd] setTime
%
```

### View system logs

The `container system logs` command allows you to look at the log messages that `container` writes:

```shellsession
% container system logs | tail -8
2025-06-02 16:46:11.560780-0700 0xf6dc5    Info        0x0                  61684  0    container-apiserver: [com.apple.container:APIServer] Registering plugin [id=com.apple.container.container-runtime-linux.my-web-server]
2025-06-02 16:46:11.699095-0700 0xf6ea8    Info        0x0                  61733  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] starting container-runtime-linux [uuid=my-web-server]
2025-06-02 16:46:11.699125-0700 0xf6ea8    Info        0x0                  61733  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] configuring XPC server [uuid=my-web-server]
2025-06-02 16:46:11.700908-0700 0xf6ea8    Info        0x0                  61733  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] starting XPC server [uuid=my-web-server]
2025-06-02 16:46:11.703028-0700 0xf6ea8    Info        0x0                  61733  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] `bootstrap` xpc handler [uuid=my-web-server]
2025-06-02 16:46:11.720836-0700 0xf6dc3    Info        0x0                  61689  0    container-network-vmnet: [com.apple.container:NetworkVmnetHelper] allocated attachment [hostname=my-web-server.test.] [address=192.168.64.2/24] [gateway=192.168.64.1] [id=default]
2025-06-02 16:46:12.293193-0700 0xf6eaa    Info        0x0                  61733  0    container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] `start` xpc handler [uuid=my-web-server]
2025-06-02 16:46:12.368723-0700 0xf6e93    Info        0x0                  61684  0    container-apiserver: [com.apple.container:APIServer] Handling container my-web-server Start.
%
```

## Technical Overview

A brief description and technical overview of `container`.

### What are containers?

Containers are a way to package an application and its dependencies into a single unit.  At runtime, containers provide isolation from the host machine as well as other colocated containers, allowing applications to run securely and efficiently in a wide variety of environments.

Containerization is an important server-side technology that is used throughout the software lifecycle:

- Backend developers use containers on their personal systems to create predictable execution environments for applications, and to develop and test their applications under conditions that better approximate how it runs in the datacenter.
- Continuous integration and deployment (CI/CD) systems use containerization to perform reproducible builds of applications, package the results as deployable images, and deploy them to the datacenter.
- Datacenters run container orchestration platforms that use the images to run containerized applications in a reliable, highly available computing cluster.

None of this workflow would be practical without ensuring interoperability between different container implementations. The Open Container Initiative (OCI) creates and maintains these standards for container images and runtimes.

### How does `container` run my container?

Many operating systems support containers, but the most commonly encountered containers are those that run on the Linux operating system. On macOS, the typical way to run Linux containers is to launch a Linux virtual machine (VM) that hosts all of your containers.

`container` runs containers differently. Using the open source Containerization library, it runs a lightweight VM for each container that you create. This approach has the following properties:

- Security: Each container has the isolation properties of a full VM, using a minimal set of core utilities and dynamic libraries to reduce resource utilization and attack surface.
- Privacy: When sharing host data using `container`, you mount only necessary data into each VM. With a shared VM, you need to mount all data that you may ever want to use into the VM, so that it can be mounted selectively into containers.
- Performance: Containers created using `container` require less memory than full VMs, with boot times that are comparable to containers running in a shared VM.

Since `container` consumes and produces standard OCI images, you can easily build with and run images produced by other container applications, and the images that you build will run everywhere.

`container` and the underlying Containerization library integrate with many of the key technologies and frameworks of macOS:

- The Virtualization framework for managing Linux virtual machines and their attached devices.
- The vmnet framework for managing the virtual network to which the containers attach.
- XPC for interprocess communication.
- Launchd for service management.
- Keychain services for access to registry credentials.

You use the `container` command line interface (CLI) to start and manage your containers, build container images, and transfer images from and to OCI container registries. The CLI uses a client library that communicates with `container-apiserver` and its helpers.

The process `container-apiserver` is a launch agent that launches when you run the `container system start` command, and terminates when you run `container system stop`. It provides the client APIs for managing container, and network resources.

When `container-apiserver` starts, it launches an XPC helper `container-core-images` that exposes an API for image management and manages the local content store, and another XPC helper `container-network-vmnet` for the virtual network. For each container that you create, `container-apiserver` launches a container runtime helper `container-runtime-linux` that exposes the management API for that specific container.

![diagram showing application functional organization](./docs/assets/functional-model-light.svg)

### What limitations does `container` have today?

With the initial release of `container`, you get basic facilities for building and running containers, but many common containerization features remain to be implemented. Consider [contributing](/community) new features and bug fixes to `container` and the Containerization projects!

#### Container to host networking

In the initial release, there is no way to route traffic directly from a client in a container to an host-based application listening on the loopback loopback interface at 127.0.0.1. If you were to configure the application in your container to connect to 127.0.0.1 or `localhost`, requests will simply go to the loopback interface in the container, and not to your host-based service.

You can work around this limitation configuring the host-based application to listen on the wildcard address 0.0.0.0, but this practice is insecure and not recommended because, without firewall rules, this opens up the application to external clients.

A more secure approach is to use `socat` to redirect traffic from the container network gateway to the host-based service. For example, to forward traffic for port 8000, configure your containerized application to connect to `192.68.64.1:8000` instead of `127.0.0.1:8000`, and then run the following command in a terminal on your Mac to forward the port traffic from the gateway to the host:

```bash
socat TCP-LISTEN:8000,fork,bind=192.168.64.1 TCP:127.0.0.1:8000
```

#### Releasing container memory to macOS

The macOS Virtualization framework implements only partial support for memory ballooning, which is a technology that allows virtual machines to dynamically receive and relinquish memory from the host. When you create a container, the underlying virtual machine only uses the amount of memory that the containerized application needs. So you might start a container using the option `--memory 16g`, but see that the application is only using 2 gigabytes of system memory.

The current limitation, however, is that memory pages freed by the application to Linux in the container cannot be relinquished to the host. If you run many memory-intensive containers, you may need to occasionally restart them to reduce memory utilization.

#### macOS Sequoia limitations

`container` relies on the new features and enhancements present in the macOS 16 Developer Preview. You can run `container` on macOS Sequoia, but you will need to be aware of some user experience quirks and functional limitations. There is no plan to address issues found on Sequoia that cannot be reproduced in the Developer Preview.

##### Network isolation

The vmnet framework in Sequoia can only provide networks where the attached containers are isolated from one another. Container-to-container communication over the virtual network is not possible.

##### Container IP addresses

In Sequoia, limitations in the vmnet framework mean that the container network can only be created when the first container starts. Since the network XPC helper provides IP addresses to containers, and the helper has to start before the first container, it is possible for the network helper and vmnet to disagree on the subnet address, resulting in containers that are completely cut off from the network.

Normally, vmnet creates the container network using the CIDR address 192.168.64.1/24, and on Sequoia, `container` defaults to using this CIDR address in the network helper. To diagnose and resolve issues where due to disagreement between vmnet and the network helper:

- Before creating the first container, scan the output of the command `ifconfig` for all bridge interface named similarly to `bridge100`.
- After creating the first container, run `ifconfig` again, and locate the new bridge interface to determine container the subnet address.
- Run `container ls` to check the IP address given to the container by the network helper. If the address corresponds to a different network:
  - Run `container system stop` to terminate the services for `container`.
  - Using the macOS `defaults` command, update the default subnet value used by the network helper process. For example, if the bridge address shown by `ifconfig` is 192.168.66.1, run:
    ```bash
    defaults write com.apple.container.defaults default.subnet 192.168.66.1
    ```
  - Run `container system start` to launch services again.
  - Try running the container again and verify that its IP address matches the current bridge interface value.

## Build the application from source

Build `container` and the background services from sources and run basic and integration tests:

```bash
make all test integration
```

Copy the binaries to `/usr/local/bin` and `/usr/local/libexec` (requires entering the administrator's password):

```bash
make install
```

### Protobufs

`container` depends on specific versions of `grpc-swift` and `swift-protobuf`. You can install them and re-generate RPC interfaces with:

```bash
make protos
```

## Contributing 

See [docs](./docs) for information on development and contribution to the container project. 
