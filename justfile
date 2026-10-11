# Local Docker Compose. api-server is published on localhost:8000.
export PATH := "/opt/homebrew/bin:/usr/local/bin:" + env_var("PATH")

default:
    @just --list

alias run := up

# Build the api-server image, then start or restart Compose.
up: _images
    docker compose -f infra/compose.yaml up -d --force-recreate --wait

# Stop Compose.
down:
    docker compose -f infra/compose.yaml down

# Public tunnel to localhost:8000 via Pinggy. Fails when PINGGY_API_KEY is missing.
port-forward:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "${PINGGY_API_KEY:-}" ]]; then
      echo "PINGGY_API_KEY not found" >&2
      exit 1
    fi
    exec ssh \
      -p 443 \
      -R0:localhost:8000 \
      -o StrictHostKeyChecking=no \
      -o ServerAliveInterval=30 \
      "${PINGGY_API_KEY}@free.pinggy.io"

# GET /healthz on the Compose api-server.
healthz:
    curl -fsS http://localhost:8000/healthz

[private]
_images:
    bash infra/build_images.sh
