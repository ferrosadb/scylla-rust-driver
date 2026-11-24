#!/usr/bin/env bash
# Contract tests for check-no-hosted-runners.sh. Each case writes one workflow
# into a fresh directory and asserts the guard's exit code.
set -euo pipefail

guard="$(cd "$(dirname "$0")" && pwd)/check-no-hosted-runners.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
cases=0

expect() {
  local want="$1" name="$2" body="$3"
  local d="$work/$cases"
  cases=$((cases + 1))
  mkdir -p "$d"
  printf '%s\n' "$body" > "$d/wf.yml"
  local got=0
  bash "$guard" "$d" > "$d/out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    failures=$((failures + 1))
    echo "FAIL: $name: exit $got, want $want"
    sed 's/^/    /' "$d/out"
  else
    echo "ok:   $name"
  fi
}

expect 0 "self-hosted flow list" '    runs-on: [self-hosted, Linux, X64]'
expect 0 "self-hosted list naming ubuntu-24.04" '    runs-on: [self-hosted, ubuntu-24.04]'
expect 1 "ubuntu-latest" '    runs-on: ubuntu-latest'
expect 1 "ubuntu-24.04" '    runs-on: ubuntu-24.04'
expect 1 "arm suffix" '    runs-on: ubuntu-24.04-arm'
expect 1 "macos version" '    runs-on: macos-14'
expect 1 "macos xlarge" '    runs-on: macos-15-xlarge'
expect 1 "windows" '    runs-on: windows-2022'
expect 1 "matrix entry" '          - runner: ubuntu-latest'
expect 1 "matrix flow list" '        os: [ubuntu-latest, macos-14]'
expect 1 "expression default" "    runs-on: \${{ inputs.runner || 'ubuntu-latest' }}"
expect 0 "comment line" '    # this job used to run on ubuntu-latest'
expect 0 "trailing comment" '    runs-on: [self-hosted, Linux, X64] # was ubuntu-latest'
expect 0 "allowlisted" '    runs-on: ubuntu-latest # github-hosted-ok: needs an arm64 Linux host we do not have'
expect 1 "marker with no reason" '    runs-on: ubuntu-latest # github-hosted-ok:'
expect 0 "hyphen-prefixed name is not a label" '        run: curl -O https://example.com/tool-ubuntu-22.04.tar.gz'
expect 0 "docker image tag" '    container: ubuntu:24.04'
expect 1 "pull_request_target" '  pull_request_target:'
expect 0 "pull_request" '  pull_request:'
expect 1 "later line still scanned" "$(printf 'jobs:\n  a:\n    runs-on: [self-hosted, Linux, X64]\n  b:\n    runs-on: ubuntu-latest')"

empty="$work/empty"
mkdir -p "$empty"
got=0
bash "$guard" "$empty" > /dev/null 2>&1 || got=$?
cases=$((cases + 1))
if [ "$got" -ne 2 ]; then
  failures=$((failures + 1))
  echo "FAIL: empty directory: exit $got, want 2"
else
  echo "ok:   empty directory is misuse, not a pass"
fi

echo "$cases cases, $failures failure(s)"
[ "$failures" -eq 0 ]
