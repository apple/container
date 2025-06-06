# Technical Overview

A brief description and technical overview of `container`.

## What are containers?

Containers are a way to package an application and its dependencies into a single unit.  At runtime, containers provide isolation from the host machine as well as other colocated containers, allowing applications to run securely and efficiently in a wide variety of environments.

Containerization is an important server-side technology that is used throughout the software lifecycle:

- Backend developers use containers on their personal systems to create predictable execution environments for applications, and to develop and test their applications under conditions that better approximate how it runs in the datacenter.
- Continuous integration and deployment (CI/CD) systems use containerization to perform reproducible builds of applications, package the results as deployable images, and deploy them to the datacenter.
- Datacenters run container orchestration platforms that use the images to run containerized applications in a reliable, highly available computing cluster.

None of this workflow would be practical without ensuring interoperability between different container implementations. The Open Container Initiative (OCI) creates and maintains these standards for container images and runtimes.

## How does `container` run my container?

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

![diagram showing application functional organization](/docs/assets/functional-model-light.svg)

## What limitations does `container` have today?

With the initial release of `container`, you get basic facilities for building and running containers, but many common containerization features remain to be implemented. Consider [contributing](/CONTRIBUTING.md) new features and bug fixes to `container` and the Containerization projects!

### Container to host networking

In the initial release, there is no way to route traffic directly from a client in a container to an host-based application listening on the loopback loopback interface at 127.0.0.1. If you were to configure the application in your container to connect to 127.0.0.1 or `localhost`, requests will simply go to the loopback interface in the container, and not to your host-based service.

You can work around this limitation configuring the host-based application to listen on the wildcard address 0.0.0.0, but this practice is insecure and not recommended because, without firewall rules, this opens up the application to external clients.

A more secure approach is to use `socat` to redirect traffic from the container network gateway to the host-based service. For example, to forward traffic for port 8000, configure your containerized application to connect to `192.68.64.1:8000` instead of `127.0.0.1:8000`, and then run the following command in a terminal on your Mac to forward the port traffic from the gateway to the host:

```bash
socat TCP-LISTEN:8000,fork,bind=192.168.64.1 TCP:127.0.0.1:8000
```

### Releasing container memory to macOS

The macOS Virtualization framework implements only partial support for memory ballooning, which is a technology that allows virtual machines to dynamically receive and relinquish memory from the host. When you create a container, the underlying virtual machine only uses the amount of memory that the containerized application needs. So you might start a container using the option `--memory 16g`, but see that the application is only using 2 gigabytes of system memory.

The current limitation, however, is that memory pages freed by the application to Linux in the container cannot be relinquished to the host. If you run many memory-intensive containers, you may need to occasionally restart them to reduce memory utilization.

### macOS Sequoia limitations

`container` relies on the new features and enhancements present in the macOS 16 Developer Preview. You can run `container` on macOS Sequoia, but you will need to be aware of some user experience quirks and functional limitations. There is no plan to address issues found on Sequoia that cannot be reproduced in the Developer Preview.

#### Network isolation

The vmnet framework in Sequoia can only provide networks where the attached containers are isolated from one another. Container-to-container communication over the virtual network is not possible.

#### Container IP addresses

In Sequoia, limitations in the vmnet framework mean that the container network can only be created when the first container starts. Since the network XPC helper provides IP addresses to containers, and the helper has to start before the first container, it is possible for the network helper and vmnet to disagree on the subnet address, resulting in containers that are completely cut off from the network.

Normally, vmnet creates the container network using the CIDR address 192.168.64.1/24, and on Sequoia, `container` defaults to using this CIDR address in the network helper. To diagnose and resolve issues where due to disagreement between vmnet and the network helper:

- Before creating the first container, scan the output of the command `ifconfig` for all bridge interface named similarly to `bridge100`.
- After creating the first container, run `ifconfig` again, and locate the new bridge interface to determine container the subnet address.
- Run `container ls` to check the IP address given to the container by the network helper. If the address corresponds to a different network:
  - Run `container system stop` to terminate the services for `container`.
  - Using the macOS `defaults` command, update the default subnet value used by the network helper process. For example, if the bridge address shown by `ifconfig` is 192.168.66.1, run:
    ```bash
    defaults write com.apple.container.defaults default.subnet 192.168.66.1/24
    ```
  - Run `container system start` to launch services again.
  - Try running the container again and verify that its IP address matches the current bridge interface value.