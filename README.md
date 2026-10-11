# fintech-fun

Bazel/Go monorepo for a retail-investor graph.

Robinhood corporate-action headlines become `Company` / `Stock` / `Event` in Neo4j, with headline vectors in Qdrant. `api_server` folds an account (`/fold`), searches headlines (`/search`), and serves the graph (`/v1/graph`). `ingest_jobs` parse, classify, and refresh the tracker.

Dev rules (naming, modules): [`AGENTS.md`](AGENTS.md).

## Prerequisites

- Bazel 8.2 (Bazelisk is fine) and Go 1.24
- `just`
- Docker (Desktop on Mac) for Compose

## Usage

```bash
just up              # build the api-server image, start or restart Compose
just run             # alias of just up
just healthz         # GET /healthz on localhost:8000
just port-forward    # tunnel localhost:8000 via Pinggy (fails if PINGGY_API_KEY is missing)
just down            # stop Compose
```

Unit tests:

```bash
bazel test //graph/... //api_server/... //ingest_jobs/... //infra/activation/...
```

Offline ingest dry-run (fixture file, no writes to Neo4j/Qdrant):

```bash
bazel run //ingest_jobs/corporate_actions -- --dry-run --file \
  "$PWD/agents/skills/ingest/robinhood/corporate_actions/testdata/tracker_sept_2026.txt"
```
