#!/usr/bin/env bash
# Per-boot startup for fintech-fun: bring up dockerd and the Neo4j + Qdrant
# containers on the localhost ports the apps already default to
# (bolt://localhost:7687, http://localhost:6333), then ingest the tracker
# fixture once so /fold, /search, and /v1/graph have data.
# Must be idempotent and tolerate restarts.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

neo4j_image="neo4j:5.26.0-community"
qdrant_image="qdrant/qdrant:v1.15.5"
neo4j_password="fintechfun"
tracker_fixture="$repo_root/agents/skills/ingest/robinhood/corporate_actions/testdata/tracker_sept_2026.txt"

log() { printf '[.cursor/start.sh] %s\n' "$*"; }

log "workspace: $repo_root"

log "Docker daemon"
if ! sudo docker info >/dev/null 2>&1; then
	sudo bash -c 'nohup dockerd >/var/log/dockerd.log 2>&1 &'
	for _ in $(seq 1 60); do
		sudo docker info >/dev/null 2>&1 && break
		sleep 1
	done
fi
sudo docker info >/dev/null 2>&1 || {
	echo "docker daemon failed to start" >&2
	exit 1
}

# ensure_container <name> <image> <run-args...>
ensure_container() {
	local name="$1" image="$2"
	shift 2
	if sudo docker ps --format '{{.Names}}' | grep -qx "$name"; then
		return 0
	fi
	if sudo docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
		sudo docker start "$name" >/dev/null
	else
		sudo docker run -d --name "$name" "$@" "$image" >/dev/null
	fi
}

log "Neo4j 5.26 (7474 browser / 7687 bolt)"
ensure_container neo4j "$neo4j_image" \
	-p 7474:7474 -p 7687:7687 -e "NEO4J_AUTH=neo4j/${neo4j_password}"

log "Qdrant v1.15.5 (6333 http / 6334 grpc)"
ensure_container qdrant "$qdrant_image" \
	-p 6333:6333 -p 6334:6334

log "Wait for services"
for _ in $(seq 1 60); do
	# Read logs into a var first; piping to grep -q under pipefail can
	# SIGPIPE docker logs and mask the match.
	logs="$(sudo docker logs neo4j 2>&1 || true)"
	case "$logs" in *"Bolt enabled on"*) break ;; esac
	sleep 1
done
for _ in $(seq 1 60); do
	curl -fsS http://localhost:6333/readyz >/dev/null 2>&1 && break
	sleep 1
done

log "Ingest tracker fixture once (guarded: only when Neo4j is empty)"
# The seed CLI subcommand from the earlier env draft is gone on main; fixture
# ingest is the current write path (no --dry-run).
node_count="$(sudo docker exec neo4j cypher-shell -u neo4j -p "$neo4j_password" \
	--format plain "MATCH (n) RETURN count(n);" 2>/dev/null | tail -1 | tr -dc '0-9')"
node_count="${node_count:-0}"
if [ "$node_count" = "0" ]; then
	# Clear any partial Qdrant collection so ingest's create step does not 409.
	curl -fsS -X DELETE http://localhost:6333/collections/corporate_actions >/dev/null 2>&1 || true
	bazel run //ingest_jobs/corporate_actions -- --file "$tracker_fixture" || \
		log "fixture ingest skipped (non-fatal)"
else
	log "Neo4j already has ${node_count} nodes; skipping ingest"
fi

log "start.sh complete"
