#!/bin/bash
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# Puts a gateway in front of a local Kubernetes cluster, and routes to the app by host name.
#
#   browser -> gateway container -> NodePort on the worker nodes -> Traefik -> Ingress -> Service
#
# The gateway is an nginx container on the cluster's container network. Its network alias
# ".gateway" makes every name below gateway.test resolve to it, so notepad.gateway.test and
# api.gateway.test both go to the gateway, and Traefik picks the Service from the Host header.
#
# Works for clusters made with "container cluster create". Run it after deploy.sh.
#
# Usage: deploy-gateway.sh [--context <kube-context>]  (default context: cluster-dev)
#
# Environment:
#   GATEWAY_NETWORK        container network of the cluster nodes (default: found from a worker node)
#   TRAEFIK_CHART_VERSION  Traefik chart version to install (default: the latest)
set -e

EXAMPLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTEXT="cluster-dev"
GATEWAY="gateway"
# The gateway's names are below this host. It assumes the default DNS domain is "test".
GATEWAY_HOST="gateway.test"
INGRESS_HTTP_PORT=31080
INGRESS_HTTPS_PORT=31443

while [[ $# -gt 0 ]]; do
  case $1 in
    --context) CONTEXT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

run() {
  echo "==> RUN: $*"
  "$@"
}

KUBECTL=(kubectl --context "$CONTEXT")

# Worker nodes, or all nodes if the cluster has no dedicated workers.
node_ips() {
  "${KUBECTL[@]}" get nodes "$@" \
    --output 'jsonpath={range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
}
WORKER_SELECTOR='!node-role.kubernetes.io/control-plane'
NODE_IPS="$(node_ips --selector "$WORKER_SELECTOR")"
if [[ -z "$NODE_IPS" ]]; then
  NODE_IPS="$(node_ips)"
fi
echo "==> Gateway upstream nodes: $(echo $NODE_IPS)"

# The gateway has to be on the container network that the nodes are on. Find the network by the
# address of a node, which does not depend on how the cluster tool names its nodes.
if [[ -z "$GATEWAY_NETWORK" ]]; then
  FIRST_NODE_IP="$(echo "$NODE_IPS" | head -n 1)"
  GATEWAY_NETWORK="$(container inspect $(container list --quiet) |
    jq -r --arg ip "$FIRST_NODE_IP" '[.[].status.networks[]? | select(.ipv4Address | startswith($ip + "/")) | .network][0] // empty')"
  if [[ -z "$GATEWAY_NETWORK" ]]; then
    echo "Could not find the container network of the node at $FIRST_NODE_IP. Set GATEWAY_NETWORK."
    exit 1
  fi
fi
echo "==> Gateway network: $GATEWAY_NETWORK"

# Install Traefik as the ingress controller, reachable on a NodePort of every node.
TRAEFIK_VERSION=()
if [[ -n "$TRAEFIK_CHART_VERSION" ]]; then
  TRAEFIK_VERSION=(--version "$TRAEFIK_CHART_VERSION")
fi
run helm upgrade --install traefik traefik \
  --repo https://traefik.github.io/charts "${TRAEFIK_VERSION[@]}" \
  --kube-context "$CONTEXT" --namespace traefik --create-namespace \
  --set service.type=NodePort \
  --set ports.web.nodePort="$INGRESS_HTTP_PORT" \
  --set ports.websecure.nodePort="$INGRESS_HTTPS_PORT" \
  --set deployment.replicas=2 \
  --wait

# Route notepad.<gateway> and api.<gateway> to the app's Services.
run "${KUBECTL[@]}" apply -f "$EXAMPLE_ROOT/ingress/ingress.yaml"

# Generate the gateway's nginx configuration. It balances across the nodes' ingress NodePort.
CONF_DIR="$EXAMPLE_ROOT/.gateway/$GATEWAY"
mkdir -p "$CONF_DIR"
{
  echo "upstream cluster_ingress {"
  for ip in $NODE_IPS; do
    echo "    server ${ip}:${INGRESS_HTTP_PORT};"
  done
  cat <<'CONF'
}

server {
    listen 80 default_server;

    location / {
        proxy_pass http://cluster_ingress;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
CONF
} >"$CONF_DIR/default.conf"

# The alias has a leading dot, so every name below the gateway's name resolves to it,
# and it gets the default domain, so .gateway means .gateway.test.
run container stop "$GATEWAY" 2>/dev/null || true
run container delete "$GATEWAY" 2>/dev/null || true
run container run -d --name "$GATEWAY" \
  --network "${GATEWAY_NETWORK},alias=.${GATEWAY}" \
  --mount "type=bind,source=${CONF_DIR},target=/etc/nginx/conf.d,readonly" \
  nginx:alpine

GATEWAY_IP="$(container inspect "$GATEWAY" | jq -r '.[0].status.networks[0].ipv4Address' | cut -d/ -f1)"

# Traefik can take a few seconds to pick up the Ingress rules, and until it does it answers 404.
ATTEMPTS=30
echo "==> Waiting for http://notepad.${GATEWAY_HOST} through the gateway at ${GATEWAY_IP}"
for attempt in $(seq 1 "$ATTEMPTS"); do
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
    -H "Host: notepad.${GATEWAY_HOST}" "http://${GATEWAY_IP}/" || true)"
  if [[ "$status" == 2* ]]; then
    echo
    echo "Run these commands from your terminal to access the web application and message API:"
    echo
    echo "  open http://notepad.${GATEWAY_HOST}"
    echo "  curl -s http://api.${GATEWAY_HOST}/api/notes | jq"
    exit 0
  fi
  if [[ "$status" == "000" ]]; then
    status="no answer"
  fi
  echo "    not ready yet (${status}), attempt ${attempt} of ${ATTEMPTS}"
  sleep 2
done
echo "The app did not answer through the gateway (last result: ${status})."
echo "Check 'kubectl --context ${CONTEXT} get pods -A' and 'kubectl --context ${CONTEXT} get ingress'."
exit 1
