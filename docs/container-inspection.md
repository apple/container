# Inspecting containers and images

Get detailed, machine-readable information about your containers and images.

## Get container or image details

`container image list` and `container list` provide basic information for all of your images and containers. You can also use `list` and `inspect` commands to print detailed machine-readable output for resources.

Use the `inspect` command and send the result to the `jq` command to get pretty-printed JSON for the images or containers that you specify:

<pre>
% container image inspect web-test | jq
[
  {
    "configuration": {
      "name": "web-test:latest",
...
    },
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
    "configuration": {
      "mounts": [],
      "id": "my-web-server",
      "resources": {
        "cpus": 4,
        "memoryInBytes": 1073741824,
      },
...
    },
    "status": {
      "state": "running",
      "networks": [
        {
          "ipv4Address": "192.168.64.3/24",
          "ipv4Gateway": "192.168.64.1",
          "hostname": "my-web-server.test.",
          "network": "default"
        }
      ],
...
    }
  }
]
</pre>

Use the `list` command with the `--format` option to display information for all images or containers. In this example, the `--all` option shows stopped as well as running containers, and `jq` selects the IP address for each running container:

<pre>
% container ls --format json --all | jq '.[] | select ( .status.state == "running" ) | [ .configuration.id, .status.networks[0].ipv4Address ]'
[
  "my-web-server",
  "192.168.64.3/24"
]
[
  "buildkit",
  "192.168.64.2/24"
]
</pre>

See [Networking](./networking.md) for how to publish ports, reach the host from a
container, set a custom MAC address, and create isolated networks.
