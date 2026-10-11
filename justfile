# Local minikube cluster. Profile, kube context, and namespace are all `fintech-fun`.
# Homebrew first: a leftover /usr/local/bin/minikube on Mac is often a Linux binary
# (`exec format error`), which breaks `just down` / `just up` / `just healthz`.
export PATH := "/opt/homebrew/bin:/usr/local/bin:" + env_var("PATH")

profile := "fintech-fun"
ns := "fintech-fun"
image_dir := "/tmp/fintech-fun-images"

default:
    @just --list

# Rewrite BUILD.bazel deps from Go imports (Gazelle).
update-build-files:
    bazel run //:gazelle

# Host tools for the Docker-driver minikube. On Mac this means Docker Desktop is running.
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v docker >/dev/null; then
      echo "docker is required. On Mac: install Docker Desktop and ensure docker is on PATH." >&2
      exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
      echo "docker daemon is not running. On Mac, start Docker Desktop, then retry." >&2
      exit 1
    fi

# Start minikube (Docker driver). Safe to re-run if the profile already exists.
cluster-start: deps
    minikube start --profile={{profile}} --driver=docker

# Bazel-build Linux binaries, docker-build images, load them into the minikube profile.
cluster-images: deps
    #!/usr/bin/env bash
    set -euo pipefail
    profile="{{profile}}"
    image_dir="{{image_dir}}"
    minikube_bin="$(command -v minikube)"
    arch=""
    if "$minikube_bin" status -p "$profile" >/dev/null 2>&1; then
      arch="$("$minikube_bin" -p "$profile" ssh -- uname -m | tr -d '\r\n')"
    fi
    if [[ -z "$arch" ]]; then
      case "$(uname -m)" in
        arm64|aarch64) arch=aarch64 ;;
        x86_64|amd64) arch=x86_64 ;;
      esac
    fi
    case "$arch" in
      aarch64|arm64) platform="@rules_go//go/toolchain:linux_arm64" ;;
      x86_64|amd64) platform="@rules_go//go/toolchain:linux_amd64" ;;
      *) echo "unsupported minikube arch: $arch" >&2; exit 1 ;;
    esac
    bazel_flags=(--platforms="$platform" --@rules_go//go/config:pure)
    bazel build "${bazel_flags[@]}" //api_server/cmd:api_server //ingest_jobs/corporate_actions:corporate_actions
    rm -rf "$image_dir"
    mkdir -p "$image_dir/api-server" "$image_dir/corporate-actions"
    cp "$(bazel cquery --noshow_progress --ui_event_filters=-info "${bazel_flags[@]}" --output=files //api_server/cmd:api_server)" "$image_dir/api-server/api_server"
    cp "$(bazel cquery --noshow_progress --ui_event_filters=-info "${bazel_flags[@]}" --output=files //ingest_jobs/corporate_actions:corporate_actions)" "$image_dir/corporate-actions/corporate_actions"
    file "$image_dir/api-server/api_server"
    # Build inside minikube's Docker daemon so Kubernetes picks up the new tag
    # (minikube image load does not replace an in-use :local tag).
    eval "$("$minikube_bin" docker-env -p "$profile")"
    docker build --no-cache -f api_server/Dockerfile -t fintech-fun/api-server:local "$image_dir/api-server"
    docker build --no-cache -f ingest_jobs/corporate_actions/Dockerfile -t fintech-fun/corporate-actions:local "$image_dir/corporate-actions"

# Apply the local overlay (Neo4j, Qdrant, api-server, suspended CronJob).
cluster-apply:
    kubectl --context {{profile}} apply -k infra/k8s/overlays/local

# Block until Neo4j, Qdrant, and api-server are Available (Neo4j readiness is slow).
wait:
    kubectl --context {{profile}} -n {{ns}} wait --for=condition=available --timeout=300s deploy/neo4j deploy/qdrant deploy/api-server

# Start cluster, load images, apply manifests, then wait for Ready.
up: cluster-start cluster-images cluster-apply wait

# Stop the VM. Data in emptyDir is gone next start. Needs Docker Desktop on Mac.
down: deps
    #!/usr/bin/env bash
    set -euo pipefail
    if ! minikube version >/dev/null 2>&1; then
      echo "minikube is not runnable (wrong arch or missing). Prefer Homebrew: /opt/homebrew/bin/minikube" >&2
      exit 1
    fi
    minikube stop -p "{{profile}}"

# Delete the profile entirely.
cluster-delete: deps
    minikube delete -p {{profile}}

# Hit api-server /healthz through minikube. Retries while Neo4j is still coming up.
healthz:
    #!/usr/bin/env bash
    set -euo pipefail
    url="$(minikube service -p "{{profile}}" -n "{{ns}}" api-server --url)"
    for _ in $(seq 1 30); do
      if out="$(curl -fsS "$url/healthz")"; then
        printf '%s\n' "$out"
        exit 0
      fi
      sleep 2
    done
    echo "healthz failed after retries: $url" >&2
    exit 1

# Account-screen fold through minikube. Example: just fold square 10
fold q qty:
    curl -sS "$(minikube service -p {{profile}} -n {{ns}} api-server --url)/fold?q={{q}}&qty={{qty}}"
    @echo

# Headline search through minikube. Example: just search "LivePerson stock merger"
search q:
    curl -sS -G --data-urlencode "q={{q}}" "$(minikube service -p {{profile}} -n {{ns}} api-server --url)/search"
    @echo

# Company/stock/event series. Example: just graph square
graph q:
    curl -sS -G --data-urlencode "q={{q}}" "$(minikube service -p {{profile}} -n {{ns}} api-server --url)/v1/graph"
    @echo

# Ingest watermark (page SHA-256).
source:
    curl -sS "$(minikube service -p {{profile}} -n {{ns}} api-server --url)/v1/graph/source"
    @echo

# Smoke /healthz /fold /search /v1/graph through NodePort.
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    url="$(minikube service -p "{{profile}}" -n "{{ns}}" api-server --url)"
    bazel run //infra/activation/cmd -- smoke "$url"

# Confirm nflx…ftel fold rows match the Notion gold tables over HTTP.
gold:
    #!/usr/bin/env bash
    set -euo pipefail
    url="$(minikube service -p "{{profile}}" -n "{{ns}}" api-server --url)"
    bazel run //infra/activation/cmd -- gold "$url"

# Host/job path for Robinhood (same URL just refresh fetches). CronJob stays suspended until this works in-cluster.
tracker_url := "https://robinhood.com/us/en/support/articles/corporate-actions-tracker/"

egress:
    #!/usr/bin/env bash
    set -euo pipefail
    code="$(curl -fsSI -o /dev/null -w "%{http_code}" "{{tracker_url}}" || true)"
    if [[ "$code" =~ ^2 ]]; then
      echo "robinhood reachable from host ($code). Manual path: just refresh"
      exit 0
    fi
    echo "robinhood not reachable from host (http $code). Leave CronJob suspended; use just refresh when egress works." >&2
    exit 1

# Unsuspend only after egress works. Default overlay keeps spec.suspend=true.
unsuspend:
    kubectl --context {{profile}} -n {{ns}} patch cronjob corporate-actions --type merge -p '{"spec":{"suspend":false}}'

suspend:
    kubectl --context {{profile}} -n {{ns}} patch cronjob corporate-actions --type merge -p '{"spec":{"suspend":true}}'

# Gap A capstone: stack up, smoke HTTP, confirm fold tables.
# CronJob stays suspended unless just egress && just unsuspend.
# Ping/seed/verify are unit tests in //ingest_jobs/corporate_actions/tools:tools_test.
gap-a: wait healthz smoke gold
    @echo "Gap A HTTP proof passed. CronJob still suspended; just egress && just unsuspend when Robinhood is reachable."

# Open k9s on this cluster in the fintech-fun namespace.
k9s:
    k9s --context {{profile}} --namespace {{ns}}

# Cluster api-server (8080) on localhost:8000, for `just port-forward`.
run:
    kubectl --context {{profile}} -n {{ns}} port-forward svc/api-server 8000:8080

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

# Re-fetch the tracker, prefix-dedup the full history, MERGE only the new suffix.
# waiting rows stay; a later cashed_out/now_different_stock is a new Event.
refresh:
    just live

# Dry-run ingest against a tracker file. Example: just dry-run path/to/tracker.txt
dry-run file:
    bazel run //ingest_jobs/corporate_actions -- --dry-run --file {{file}}

# Host → NodePort Bolt/Qdrant. Example: just live --file path/to/tracker.txt
live *args:
    #!/usr/bin/env bash
    set -euo pipefail
    host="$(minikube ip -p "{{profile}}")"
    export NEO4J_URI="bolt://${host}:30687"
    export NEO4J_USER=neo4j
    export NEO4J_PASSWORD=fintechfun
    export QDRANT_URL="http://${host}:30333"
    bazel run //ingest_jobs/corporate_actions -- {{args}}

# Ingest a tracker file or fetch live. Example: just ingest --file path/to/tracker.txt
ingest *args:
    just live {{args}}
