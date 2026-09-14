# Multiplatform images

Build, run, and publish container images that support both Apple silicon and x86-64.

## Build and run a multiplatform image

Using the [project from the tutorial example](./tutorials/start-here.md#set-up-a-simple-project), you can create an image to use both on Apple silicon Macs and on x86-64 servers.

When building the image, just add `--arch` options that direct the builder to create an image supporting both the `arm64` and `amd64` architectures:

```bash
container build --arch arm64 --arch amd64 --tag registry.example.com/fido/web-test:latest --file Dockerfile .
```

Try running the command `uname -a` with the `arm64` variant of the image to see the system information that the virtual machine reports:

<pre>
% container run --arch arm64 --rm registry.example.com/fido/web-test:latest uname -a
Linux 7932ce5f-ec10-4fbe-a2dc-f29129a86b64 6.1.68 #1 SMP Mon Mar 31 18:27:51 UTC 2025 aarch64 GNU/Linux
%
</pre>

When you run the command with the `amd64` architecture, the x86-64 version of `uname` runs under Rosetta translation, so that you will see information for an x86-64 system:

<pre>
% container run --arch amd64 --rm registry.example.com/fido/web-test:latest uname -a
Linux c0376e0a-0bfd-4eea-9e9e-9f9a2c327051 6.1.68 #1 SMP Mon Mar 31 18:27:51 UTC 2025 x86_64 GNU/Linux
%
</pre>

The command to push your multiplatform image to a registry is no different than that for a single-platform image:

```bash
container image push registry.example.com/fido/web-test:latest
```
