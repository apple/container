# Tutorial

Take a guided tour of `container` by building, running, and publishing a simple web server image.

## Try out the `container` CLI

Start the application, and try out some basic commands to familiarize yourself with the command line interface (CLI) tool.

### Start the container service

Start the services that `container` uses:

```bash
container system start
```

If you have not installed a Linux kernel yet, the command will prompt you to install one:

<pre>
% container system start

Verifying apiserver is running...
Installing base container filesystem...
No default kernel configured.
Install the recommended default kernel from [https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz]? [Y/n]: y
Installing kernel...
%
</pre>

Then, verify that the application is working by running a command to list all containers:

```bash
container list --all
```

If you haven't created any containers yet, the command outputs an empty list:

<pre>
% container list --all
ID  IMAGE  OS  ARCH  STATE  ADDR
%
</pre>

### Get CLI help

You can get help for any `container` CLI command by appending the `--help` option:

<pre>
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
</pre>

### Abbreviations

You can save keystrokes by abbreviating commands and options. For example, abbreviate the `container list` command to `container ls`, and the `--all` option to `-a`:

<pre>
% container ls -a
ID  IMAGE  OS  ARCH  STATE  ADDR
%
</pre>

Use the `--help` flag to see which abbreviations exist.

### Set up a local DNS domain (optional)

`container` includes an embedded DNS service that simplifies access to your containerized applications. If you want to configure a local DNS domain named `test` for this tutorial, run:

```bash
sudo container system dns create test
container system dns default set test
```

Enter your administrator password when prompted. The first command requires administrator privileges to create a file containing the domain configuration under the `/etc/resolver` directory, and to tell the macOS DNS resolver to reload its configuration files.

The second command makes `test` the default domain to use when running a container with an unqualified name. For example, if the default domain is `test` and you use `--name my-web-server` to start a container, queries to `my-web-server.test` will respond with that container's IP address.

## Build an image

Set up a `Dockerfile` for a basic Python web server, and use it to build a container image named `web-test`.

### Set up a simple project

Start a terminal, create a directory named `web-test` for the files needed to create the container image:

```bash
mkdir web-test
cd web-test
```

In the `web-test` directory, create a file named `Dockerfile` with this content:

```dockerfile
FROM docker.io/python:alpine
WORKDIR /content
RUN apk add curl
RUN echo '<!DOCTYPE html><html><head><title>Hello</title></head><body><h1>Hello, world!</h1></body></html>' > index.html
CMD ["python3", "-m", "http.server", "80", "--bind", "0.0.0.0"]
```

The `FROM` line instructs the `container` builder to start with a base image containing the latest production version of Python 3.

The `WORKDIR` line creates a directory `/content` in the image, and makes it the current directory.

The first `RUN` line adds the `curl` command to your image, and the second `RUN` line creates a simple HTML landing page named `/content/index.html`.

The `CMD` line configures the container to run a simple web server in Python on port 80. Since the working directory is `/content`, the web server runs in that directory and delivers the content of the file `/content/index.html` when a user requests the index page URL.

The server listens on the wildcard address `0.0.0.0` to allow connections from the host and other containers. You can safely use the listen address `0.0.0.0` inside the container, because external systems have no access to the virtual network to which the container attaches.

### Build the web server image

Run the `container build` command to create an image with the name `web-test` from your `Dockerfile`:

```bash
container build --tag web-test --file Dockerfile .
```

The last argument `.` tells the builder to use the current directory (`web-test`) as the root of the build context. You can copy files within the build context into your image using the `COPY` command in your Dockerfile.

After the build completes, list the images. You should see both the base image and the image that you built in the results:

<pre>
% container images list
NAME      TAG     DIGEST
python    alpine  b4d299311845147e7e47c970...
web-test  latest  25b99501f174803e21c58f9c...
%
</pre>

## Run containers

Using your container image, run a web server and try out different ways of interacting with it.

### Start the webserver

Use `container run` to start a container named `my-web-server` that runs your webserver:

```bash
container run --name my-web-server --detach --rm web-test
```

The `--detach` flag runs the container in the background, so that you can continue running commands in the same terminal. The `--rm` flag causes the container to be removed automatically after it stops.

When you list containers now, `my-web-server` is present, along with the container that `container` started to build your image. Note that its IP address, shown in the `ADDR` column, is `192.168.64.3`:

<pre>
% container ls
ID             IMAGE                                               OS     ARCH   STATE    ADDR
buildkit       ghcr.io/apple/container-builder-shim/builder:0.0.3  linux  arm64  running  192.168.64.2
my-web-server  web-test:latest                                     linux  arm64  running  192.168.64.3
%
</pre>

Open the website, using the container's IP address in the URL:

```bash
open http://192.168.64.3
```

If you configured the local domain `test` earlier in the tutorial, you can also open the page with the full hostname for the container:

```bash
open http://my-web-server.test
```

### Run other commands in the container

You can run other commands in `my-web-server` by using the `container exec` command. To list the files under the content directory, run an `ls` command:

<pre>
% container exec my-web-server ls /content
index.html
%
</pre>

If you want to poke around in the container, run a shell and issue one or more commands:

<pre>
% container exec --tty --interactive my-web-server sh
/content # ls
index.html
/content # uname -a
Linux my-web-server 6.12.28 #1 SMP Tue May 20 15:19:05 UTC 2025 aarch64 Linux
/content # exit
%
</pre>

The `--tty` and `--interactive` flag allow you to interact with the shell from your host terminal. The `--tty` flag tells the shell in the container that its input is a terminal device, and the `--interactive` flag connects what you input in your host terminal to the input of the shell in the container.

You will often see these two options abbreviated and specified together as `-ti` or `-it`.

### Access the web server from another container

Your web server is accessible from other containers as well as from your host. Launch a second container using your `web-test` image, and this time, specify a `curl` command to retrieve the `index.html` content from the first container.

```bash
container run -it --rm web-test curl http://192.168.64.3
```

The output should appear as:

<pre>
% container run -it --rm web-test curl http://192.168.64.3
&lt;!DOCTYPE html>&lt;html>&lt;head>&lt;title>Hello&lt;/title>&lt;/head>&lt;body>&lt;h1>Hello, world!&lt;/h1>&lt;/body>&lt;/html>
%
</pre>

If you set up the `test` domain earlier, you can achieve the same result with:

```bash
container run -it --rm web-test curl http://my-web-server.test
```

## Run a published image

Push your image to a container registry, publishing it so that you and others can use it.

### Publish the web server image

To publish your image, you need push images to a registry service that stores the image for future use. Typically, you need to authenticate with a registry to push an image. This example assumes that you have an account at a hypothetical registry named `registry.example.com` with username `fido` and a password or token `my-secret`, and that your personal repository name is the same as your username.

> [!NOTE]
> By default `container` is configured to use Docker Hub.
> You can change the default registry used by running `container registry default set <registry url>`.
> See the other sub commands under `container registry` for more options.

To sign into a secure registry with your login credentials, enter your username and password at the prompts after running:

```bash
container registry login {registry.example.com}
```

Create another name for your image that includes the registry name, your repository name, and the image name, with the tag `latest`:

```bash
container images tag web-test {registry.example.com/fido}/web-test:latest
```

Then, push the image:

```bash
container images push {registry.example.com/fido}/web-test:latest
```

### Pull and run your image

To validate your published image, stop your current web server container, remove the image that you built, and then run using the remote image:

```bash
container stop my-web-server
container images delete web-test {registry.example.com/fido}/web-test:latest
container run --name my-web-server --detach --rm {registry.example.com/fido}/web-test:latest
```

## Clean up

Stop your container and shut down the application.

### Shut down the web server

Stop your web server container with:

```bash
container stop my-web-server
```

If you list all running and stopped containers, you will see that the `--rm` flag you supplied with the `container run` command caused the container to be removed:

<pre>
% container list --all
ID        IMAGE                                               OS     ARCH   STATE    ADDR
buildkit  ghcr.io/apple/container-builder-shim/builder:0.0.3  linux  arm64  running  192.168.64.2
%
</pre>

### Stop the container service

When you want to stop `container` completely, run:

```bash
container system stop
```
