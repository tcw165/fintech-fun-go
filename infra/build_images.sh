#!/usr/bin/env bash
# Bazel-build the Linux api-server binary and tag it for Compose.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if ! command -v docker >/dev/null; then
  echo "docker is required. On Mac: install Docker Desktop and ensure docker is on PATH." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "docker daemon is not running. On Mac, start Docker Desktop, then retry." >&2
  exit 1
fi

case "$(uname -m)" in
  arm64|aarch64) platform="@rules_go//go/toolchain:linux_arm64" ;;
  x86_64|amd64) platform="@rules_go//go/toolchain:linux_amd64" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

bazel_flags=(--platforms="$platform" --@rules_go//go/config:pure)
bazel build "${bazel_flags[@]}" //api_server/cmd:api_server

image_dir="/tmp/fintech-fun-images"
rm -rf "$image_dir"
mkdir -p "$image_dir/api-server"
cp "$(bazel cquery --noshow_progress --ui_event_filters=-info "${bazel_flags[@]}" --output=files //api_server/cmd:api_server)" \
  "$image_dir/api-server/api_server"
file "$image_dir/api-server/api_server"
docker build --no-cache -f api_server/Dockerfile -t fintech-fun/api-server:local "$image_dir/api-server"
