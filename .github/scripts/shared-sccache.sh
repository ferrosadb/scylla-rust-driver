#!/usr/bin/env bash
# shared-sccache.sh -- turn on the sccache store the Linux runners share, or
# say in one line why this job does not use it.
#
# The store is a WebDAV server on the LAN. Each self-hosted Linux runner's
# HOST puts these in the job environment (they are not GitHub secrets):
#
#   SCCACHE_WEBDAV_ENDPOINT / _USERNAME / _PASSWORD   the store
#   FERROSA_CI_SHARED_HOME  one absolute path, identical on every Linux runner
#   SCCACHE_SERVER_PORT     a distinct port per runner -- which this script
#                           UNSETS; see below
#
# The job's sccache server listens on a unix socket in RUNNER_TEMP, not on a
# TCP port. ferrosa-dbaas runs its tests inside `bwrap --unshare-net`
# (run-isolated-net.sh), a network namespace with its own loopback, and there
# every compile through a TCP server failed with "Network unreachable (os
# error 101)" -- reproduced with this sccache. The socket is a file, and bwrap
# binds the filesystem, so a client inside the namespace reaches the server
# outside it, which is the one that talks to the store. RUNNER_TEMP is per
# runner instance and per job, so it also does what the per-runner port was
# for: two jobs sharing a host never share a server (and its basedir). The
# port is cleared for the server and for every later step, so nothing can
# fall back to TCP. (sccache 0.18 prefers the socket anyway; verified.)
#
# Measured before this was written (ops/ci-cache/test-share.sh in
# ferrosa-suite): a second runner, and a second host, got 15/16 hits -- but
# only with the SAME CARGO_HOME path. sccache hashes CARGO_MANIFEST_DIR, which
# for every registry crate is under CARGO_HOME, so per-repository or
# per-instance cargo homes gave 0 hits even with SCCACHE_BASEDIRS. That is why
# this replaces persistent-host's per-repository CARGO_HOME with
# $FERROSA_CI_SHARED_HOME/cargo-home. (Its reason for being per repository was
# rust-cache pruning the registry, and rust-cache does not run on self-hosted.)
#
# Only registry/ and git/ need to be shared -- they are what put
# CARGO_MANIFEST_DIR in the key. TOOLS must not be: with one $CARGO_HOME/bin
# for every repository and runner, a binary another job put there (by another
# repository, or by taiki-e/install-action, which keeps no .crates.toml
# record) made `cargo install` refuse with "binary `cargo-deny` already exists
# in destination" (ferrosa-memory-private run 35930769487). So `cargo install`
# gets CARGO_INSTALL_ROOT, per runner instance and per repository as tools
# were before, and its bin/ goes on PATH AHEAD of the shared $CARGO_HOME/bin.
# (The runner puts a later GITHUB_PATH line in front of an earlier one.)
# taiki-e/install-action has no input for its install directory and writes to
# $CARGO_HOME/bin whenever `cargo` resolves there; the workflows therefore give
# its steps CARGO_HOME=$CARGO_INSTALL_ROOT, which sends it to its per-job
# directory under $HOME instead.
#
# On, when ALL of these hold; otherwise one "shared sccache: off (...)" line:
#   the shared-cache input is "true"   release jobs pass "false": a poisoned
#                                      cache entry must never reach a shipped
#                                      binary
#   the runner is self-hosted          GitHub's VMs cannot reach the LAN store
#   the runner is Linux                the Macs get none of the host variables
#   isolate-home is "true"             otherwise CARGO_HOME is the account's own
#   the machine is x86_64              the only binary pinned below
#   the store variables are set        a self-hosted Linux runner without
#                                      FERROSA_CI_SHARED_HOME or the endpoint
#                                      is misconfigured, so that one warns
#
# sccache 0.18.0 is installed once per host into the shared home, verified
# against the sha256 pinned here AND the release's own .sha256, and renamed
# into place so concurrent jobs racing to install it cannot see half a file.
# The binary MUST be named `sccache`: under any other name it takes itself for
# a compiler, finds itself on the way, and recurses on `-vV` until the job
# times out.
#
# The server must answer within SCCACHE_START_TIMEOUT seconds (default 30) or
# the job fails. The WebDAV password is never printed: it is masked for the
# runner, and any sccache output this script shows has it replaced by ***.
#
# Usage: shared-sccache.sh setup
#
# Reads SHARED_CACHE_INPUT, ISOLATE_HOME_INPUT, RUNNER_KIND
# (runner.environment), RUNNER_OS_NAME (runner.os) and the runner's
# GITHUB_ENV, GITHUB_PATH, GITHUB_WORKSPACE, GITHUB_REPOSITORY, RUNNER_TEMP and
# RUNNER_TOOL_CACHE. Exit 0 when on or off, 1 when it should be on and could
# not be turned on, 2 on misuse.
set -euo pipefail

SCCACHE_VERSION=0.18.0
SCCACHE_TRIPLE=x86_64-unknown-linux-musl
SCCACHE_SHA256=45f1447fbe231e3037bde351ef70677dd212216c8d62ae7ca409fecc4d6acc89
SCCACHE_DOWNLOAD_BASE="${SCCACHE_DOWNLOAD_BASE:-https://github.com/mozilla/sccache/releases/download}"
start_timeout="${SCCACHE_START_TIMEOUT:-30}"

if [ "$#" -ne 1 ] || [ "$1" != setup ]; then
  echo "usage: $0 setup" >&2
  exit 2
fi
if ! [[ "$start_timeout" =~ ^[0-9]+$ ]] || [ "$start_timeout" -lt 1 ]; then
  echo "shared-sccache: SCCACHE_START_TIMEOUT '$start_timeout' is not a positive number of seconds" >&2
  exit 2
fi

off() { echo "shared sccache: off ($1)"; exit 0; }

# Any text from sccache or curl goes through here before it is shown.
redact() {
  local text="$1"
  if [ -n "${SCCACHE_WEBDAV_PASSWORD:-}" ]; then
    text="${text//"$SCCACHE_WEBDAV_PASSWORD"/***}"
  fi
  printf '%s\n' "$text"
}

decide() {
  [ "${SHARED_CACHE_INPUT:-}" = true ] ||
    off "shared-cache input is '${SHARED_CACHE_INPUT:-}', not 'true'; release and publishing jobs build without it"
  [ "${RUNNER_KIND:-}" = self-hosted ] ||
    off "runner environment is '${RUNNER_KIND:-unset}'; only the self-hosted Linux runners can reach the store"
  [ "${RUNNER_OS_NAME:-}" = Linux ] ||
    off "runner OS is '${RUNNER_OS_NAME:-unset}'; only the Linux runners are given the store"
  [ "${ISOLATE_HOME_INPUT:-}" = true ] ||
    off "isolate-home is '${ISOLATE_HOME_INPUT:-}', so CARGO_HOME stays the runner account's own"
  # SHARED_SCCACHE_MACHINE stands in for `uname -m` in the tests.
  local arch="${SHARED_SCCACHE_MACHINE:-$(uname -m)}"
  [ "$arch" = x86_64 ] ||
    off "machine is $arch; only the $SCCACHE_TRIPLE build of sccache is pinned"

  local name missing=""
  for name in FERROSA_CI_SHARED_HOME SCCACHE_WEBDAV_ENDPOINT; do
    [ -n "${!name:-}" ] || missing="$missing $name"
  done
  if [ -n "$missing" ]; then
    echo "::warning::shared sccache: off (this self-hosted Linux runner's host does not set:$missing)"
    exit 0
  fi
}

# install <dest>: put a verified sccache at <dest> unless one is already there.
install_tmp=""
# Keep the exit status. A trap whose last command succeeds replaces it: a
# fatal error such as an unset ${VAR:?} then exited 0, and the job that should
# have failed passed silently.
cleanup() {
  local status=$?
  if [ -n "$install_tmp" ]; then rm -rf "$install_tmp"; fi
  exit "$status"
}
trap cleanup EXIT
install_sccache() {
  local dest="$1" dir tmp tarball stem url
  dir="$(dirname "$dest")"
  if [ -x "$dest" ]; then
    return 0
  fi
  mkdir -p "$dir"
  # Beside the destination, so the final mv is a rename on one filesystem.
  tmp="$(mktemp -d "$dir/.install.XXXXXX")"
  install_tmp="$tmp"
  stem="sccache-v${SCCACHE_VERSION}-${SCCACHE_TRIPLE}"
  tarball="$tmp/$stem.tar.gz"
  url="$SCCACHE_DOWNLOAD_BASE/v${SCCACHE_VERSION}/$stem.tar.gz"
  if ! curl -fsSL --retry 3 -o "$tarball" "$url" ||
    ! curl -fsSL --retry 3 -o "$tarball.sha256" "$url.sha256"; then
    echo "::error::shared-sccache: could not download $url or its .sha256"
    return 1
  fi

  local published actual
  published="$(awk '{print $1; exit}' "$tarball.sha256")"
  actual="$(sha256_of "$tarball")"
  if [ "$actual" != "$SCCACHE_SHA256" ] || [ "$published" != "$SCCACHE_SHA256" ]; then
    echo "::error::shared-sccache: $url has sha256 $actual, release file says $published, pinned $SCCACHE_SHA256; not installing it"
    return 1
  fi
  tar -xzf "$tarball" -C "$tmp" "$stem/sccache"
  chmod 0755 "$tmp/$stem/sccache"
  # A rename within one directory is atomic: a racing job sees no file or the
  # whole file, and whichever rename lands last replaces an identical binary.
  mv -f "$tmp/$stem/sccache" "$dest"
  echo "shared-sccache: installed sccache $SCCACHE_VERSION at $dest"
}

sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# start_server <sccache>: start it, and prove it answers, within the timeout.
start_server() {
  local bin="$1" log pid rc=0 ticks=0 limit=$((start_timeout * 10))
  log="$(mktemp)"
  "$bin" --start-server > "$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2> /dev/null && [ "$ticks" -lt "$limit" ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if kill -0 "$pid" 2> /dev/null; then
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
    echo "::error::shared-sccache: sccache --start-server did not return within ${start_timeout}s"
    redact "$(cat "$log")"
    rm -f "$log"
    return 1
  fi
  wait "$pid" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "::error::shared-sccache: sccache --start-server exited $rc"
    redact "$(cat "$log")"
    rm -f "$log"
    return 1
  fi
  if ! "$bin" --show-stats > "$log" 2>&1; then
    echo "::error::shared-sccache: the sccache server started but does not answer --show-stats"
    redact "$(cat "$log")"
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
}

# An explicit exit, not ${VAR:?}: under bash 3.2 with an EXIT trap set, a
# ${VAR:?} failure exits 0 -- a guard that fails open.
require() {
  if [ -z "${!1:-}" ]; then
    echo "::error::shared-sccache: $1 is unset; $2"
    exit 1
  fi
}

decide

require GITHUB_ENV "the runner always sets it"
require GITHUB_PATH "the runner always sets it"
require GITHUB_WORKSPACE "it is the sccache basedir"
require RUNNER_TEMP "it holds the socket of the sccache server"
require RUNNER_TOOL_CACHE "it holds the per-repository cargo install root"
require GITHUB_REPOSITORY "it names the cargo install root"
case "$FERROSA_CI_SHARED_HOME" in /*) ;; *)
  echo "::error::shared-sccache: FERROSA_CI_SHARED_HOME '$FERROSA_CI_SHARED_HOME' is not absolute"
  exit 1 ;;
esac

if [ -n "${SCCACHE_WEBDAV_PASSWORD:-}" ]; then
  # The runner consumes this line; it never reaches the job log.
  echo "::add-mask::$SCCACHE_WEBDAV_PASSWORD"
fi

cargo_home="$FERROSA_CI_SHARED_HOME/cargo-home"
sccache="$FERROSA_CI_SHARED_HOME/tools/sccache-$SCCACHE_VERSION/sccache"
install_root="$RUNNER_TOOL_CACHE/ferrosa-ci/${GITHUB_REPOSITORY#*/}/cargo-install"
mkdir -p "$cargo_home/bin" "$install_root/bin"
install_sccache "$sccache"

version="$("$sccache" --version 2>&1 || true)"
if [ "$version" != "sccache $SCCACHE_VERSION" ]; then
  echo "::error::shared-sccache: $sccache reports '$(redact "$version")', expected 'sccache $SCCACHE_VERSION'"
  exit 1
fi

export CARGO_HOME="$cargo_home"
export CARGO_INSTALL_ROOT="$install_root"
export RUSTC_WRAPPER="$sccache"
export SCCACHE_BASEDIRS="$GITHUB_WORKSPACE"
export CARGO_INCREMENTAL=0
export SCCACHE_IDLE_TIMEOUT=0
export SCCACHE_SERVER_UDS="$RUNNER_TEMP/sccache.sock"
unset SCCACHE_SERVER_PORT
# sun_path holds 108 bytes; a longer path fails at bind with a vaguer error.
if [ "${#SCCACHE_SERVER_UDS}" -gt 100 ]; then
  echo "::error::shared-sccache: socket path $SCCACHE_SERVER_UDS is longer than a unix socket allows"
  exit 1
fi
start_server "$sccache"

{
  echo "CARGO_HOME=$CARGO_HOME"
  echo "CARGO_INSTALL_ROOT=$CARGO_INSTALL_ROOT"
  echo "RUSTC_WRAPPER=$RUSTC_WRAPPER"
  echo "SCCACHE_BASEDIRS=$SCCACHE_BASEDIRS"
  echo "CARGO_INCREMENTAL=$CARGO_INCREMENTAL"
  echo "SCCACHE_IDLE_TIMEOUT=$SCCACHE_IDLE_TIMEOUT"
  echo "SCCACHE_SERVER_UDS=$SCCACHE_SERVER_UDS"
  # GITHUB_ENV cannot unset what the host provides; empty is ignored by sccache.
  echo "SCCACHE_SERVER_PORT="
} >> "$GITHUB_ENV"
# Order matters: the runner puts the LATER line first, so the per-repository
# tools shadow anything of the same name in the shared bin.
{
  echo "$cargo_home/bin"
  echo "$install_root/bin"
} >> "$GITHUB_PATH"

echo "shared sccache: on, endpoint $(redact "$SCCACHE_WEBDAV_ENDPOINT"), CARGO_HOME $cargo_home, tools $install_root, server $SCCACHE_SERVER_UDS"
