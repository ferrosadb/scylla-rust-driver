#!/usr/bin/env bash
# ferrosa-integration.sh -- run the driver's cluster tests against one ferrosa node.
#
#   ferrosa-integration.sh <binaries-file>   start node + box, run every test binary
#   ferrosa-integration.sh --teardown        remove what a run started
#
# The runner is a shared workstation with a live ferrosa-memory cluster on it,
# so nothing here touches the host network:
#
#   * the node ($CI_NAME-node, image tag ferrosa-node:$CI_NAME) runs on
#     docker's default bridge with NO published ports, standalone, auth off,
#     local storage only (no S3);
#   * the tests run in "the box" ($CI_NAME-box), which joins the NODE'S network
#     namespace (--network container:...). Inside it 127.0.0.1:9042 is this
#     run's node and nothing else, and the scylla-proxy tests' 127.0.0.x
#     listeners live in that private namespace, not on the host.
#
# The box runs the binaries built on the host, as the runner's uid, with the
# workspace and the (symlinked) target dir mounted at the same paths.
#
# Skip lists come from the workflow: SCYLLA_ONLY_TESTS (scope) and
# FERROSA_GAP_TESTS (debt). One exact test path per line, `# reason` required.
# A listed test that no binary contains fails the run: a stale skip would
# otherwise skip nothing and say nothing.
set -euo pipefail

die() { echo "::error::ferrosa-integration: $*" >&2; exit 1; }
: "${CI_NAME:?CI_NAME is unset}"
node="$CI_NAME-node"
box="$CI_NAME-box"

teardown() {
  local c
  for c in "$box" "$node"; do
    if docker container inspect "$c" >/dev/null 2>&1; then
      docker rm -f "$c" >/dev/null || die "could not remove $c"
      echo "removed $c"
    fi
  done
  if docker image inspect "ferrosa-node:$CI_NAME" >/dev/null 2>&1; then
    docker rmi "ferrosa-node:$CI_NAME" >/dev/null || die "could not remove image ferrosa-node:$CI_NAME"
  fi
  # Prove it: nothing of this run may outlive it on a shared host.
  left="$(docker ps -a --filter "name=$CI_NAME" --format '{{.Names}}')"
  [ -z "$left" ] || die "containers left behind: $left"
}

if [ "${1:-}" = "--teardown" ]; then
  teardown
  exit 0
fi

binaries="${1:?usage: $0 <binaries-file> | --teardown}"
[ -s "$binaries" ] || die "binaries file '$binaries' is empty or missing"
: "${CI_BOX_IMAGE:?}" "${GITHUB_WORKSPACE:?}" "${RUNNER_TEMP:?}" "${CARGO_TARGET_DIR:?}"

# --- parse the skip lists -------------------------------------------------
skips=()
parse_list() {
  local label="$1" text="$2" line name reason
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    name="${line%%#*}"; name="${name%"${name##*[![:space:]]}"}"
    reason="${line#*#}"
    [ "$reason" != "$line" ] && [ -n "${reason// /}" ] || die "$label entry '$name' has no '# reason'"
    echo "skip [$label] $name --$reason"
    skips+=("$name")
  done <<< "$text"
}
parse_list scylla-only "${SCYLLA_ONLY_TESTS:-}"
parse_list ferrosa-gap "${FERROSA_GAP_TESTS:-}"

# Every skip must name a real test.
all_tests="$(mktemp)"
while read -r _ exe; do
  "$exe" --list --format terse 2>/dev/null | sed -n 's/: test$//p' >> "$all_tests"
done < "$binaries"
for s in "${skips[@]}"; do
  grep -qxF "$s" "$all_tests" || die "skip list names '$s', which no test binary contains"
done
echo "${#skips[@]} test(s) skipped by name; $(wc -l < "$all_tests") test(s) in total"

# --- start the node and the box -----------------------------------------
docker run -d --name "$node" --label scylla-ci="$CI_NAME" \
  -e FERROSA_HOST_ID=91111111-1111-1111-1111-111111111111 \
  -e FERROSA_DATA_DIR=/var/lib/ferrosa \
  -e FERROSA_AUTH_DISABLED=true \
  -e FERROSA_CQL_BIND=0.0.0.0:9042 \
  -e FERROSA_CQL_BROADCAST=127.0.0.1:9042 \
  -e FERROSA_GRAPH_ENABLED=false \
  -e FERROSA_SPARQL_ENABLED=false \
  -e FERROSA_CLUSTER_NAME=scylla-driver-ci \
  -e FERROSA_CLUSTER_MODE=standalone \
  -e FERROSA_INTERNODE_BIND=127.0.0.1:7000 \
  -e FERROSA_INTERNODE_BROADCAST=127.0.0.1:7000 \
  "ferrosa-node:$CI_NAME" >/dev/null

target_real="$(readlink -f "$CARGO_TARGET_DIR")"
mounts=(-v "$GITHUB_WORKSPACE:$GITHUB_WORKSPACE:ro" -v "$RUNNER_TEMP:$RUNNER_TEMP")
if [ "$target_real" != "$GITHUB_WORKSPACE/target" ]; then
  mounts+=(-v "$target_real:$target_real:ro")
fi
docker run -d --init --name "$box" --label scylla-ci="$CI_NAME" \
  --network "container:$node" --user "$(id -u):$(id -g)" \
  -e HOME="$RUNNER_TEMP" -e TMPDIR="$RUNNER_TEMP" \
  "${mounts[@]}" "$CI_BOX_IMAGE" sleep infinity >/dev/null

ready=0
for _ in $(seq 1 60); do
  if docker exec "$box" bash -c 'exec 3<>/dev/tcp/127.0.0.1/9042' 2>/dev/null; then ready=1; break; fi
  docker container inspect -f '{{.State.Running}}' "$node" | grep -qx true || die "the ferrosa node exited during startup"
  sleep 2
done
[ "$ready" -eq 1 ] || die "the ferrosa node did not accept CQL on 127.0.0.1:9042 within 120s"
echo "ferrosa node is accepting CQL"

# --- run every binary ---------------------------------------------------
skip_args=()
for s in "${skips[@]}"; do skip_args+=(--skip "$s"); done
failed=()
while read -r name exe; do
  pkg_dir="$GITHUB_WORKSPACE/scylla"
  [ "$name" = "scylla_proxy" ] && pkg_dir="$GITHUB_WORKSPACE/scylla-proxy"
  echo "::group::$name"
  # CDC=disabled: the CDC parts of upstream's tests are Scylla-only; upstream's
  # Cassandra run sets the same.
  if docker exec -w "$pkg_dir" \
       -e SCYLLA_URI=127.0.0.1:9042 -e SCYLLA_URI2=127.0.0.1:9042 -e SCYLLA_URI3=127.0.0.1:9042 \
       -e CDC=disabled -e RUST_BACKTRACE=1 \
       "$box" "$exe" --test-threads=4 --exact "${skip_args[@]}"; then
    echo "::endgroup::"
  else
    echo "::endgroup::"
    echo "::error::$name: test failures (see the group above)"
    failed+=("$name")
  fi
done < "$binaries"

[ "${#failed[@]}" -eq 0 ] || die "failing test binaries: ${failed[*]}"
echo "all test binaries passed"
