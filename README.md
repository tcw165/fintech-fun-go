# fintech-fun

Bazel/Go monorepo for a retail-investor graph.

Robinhood corporate-action headlines become `Company` / `Stock` / `Event` in Neo4j, with headline vectors in Qdrant. `api_server` folds an account (`/fold`), searches headlines (`/search`), and serves the graph (`/v1/graph`). `ingest_jobs` parse, classify, and refresh the tracker.

Dev rules (naming, modules): [`AGENTS.md`](AGENTS.md).

## Prerequisites

- Bazel 8.2 (Bazelisk is fine) and Go 1.24
- `just`
- For the local cluster: Docker (Desktop on Mac), `minikube`, `kubectl`
- Optional: `k9s`

`just deps` checks that Docker is installed and running.

## Usage

Unit tests (no cluster):

```bash
just update-build-files   # sync BUILD.bazel from Go imports, if you changed imports
bazel test //graph/... //api_server/... //ingest_jobs/... //infra/activation/...
```

Local minikube (profile `fintech-fun`):

```bash
just up              # start cluster, load images, apply overlay
just healthz         # GET /healthz
just fold square 10  # GET /fold?q=square&qty=10
just search "LivePerson stock merger"
just run             # api-server on localhost:8000
just port-forward    # tunnel localhost:8000 via Pinggy (fails if PINGGY_API_KEY is missing)
just down            # stop the VM
```

Offline ingest dry-run (fixture file, no writes to Neo4j/Qdrant):

```bash
bazel run //ingest_jobs/corporate_actions -- --dry-run --file \
  "$PWD/agents/skills/ingest/robinhood/corporate_actions/testdata/tracker_sept_2026.txt"
```

`just` lists every recipe. The corporate-actions CronJob starts suspended; use `just refresh` (live ingest) after Robinhood is reachable.
