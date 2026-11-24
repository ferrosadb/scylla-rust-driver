#!/usr/bin/env bash
# persistent-target.sh -- keep a job's cargo target/ across runs on a
# persistent self-hosted runner, bounded in size.
#
# actions/checkout starts every run with `git clean -ffdx`, which deletes
# target/ in the workspace, and rust-cache saves nothing on a self-hosted
# runner (save-if is github-hosted only). Without this every self-hosted job
# compiles the whole dependency graph from nothing.
#
# So the workspace's target/ becomes a SYMLINK to a directory in the runner
# instance's tool cache, recreated after every checkout. git clean removes the
# link, not what it points at. Every `target/...` path in the workflows keeps
# working, and CARGO_TARGET_DIR still names the workspace path, so an ancestor
# .cargo/config.toml still cannot move the output (see action.yml).
#
# One persistent dir per runner INSTANCE per repository: RUNNER_TOOL_CACHE is
# per instance and an instance runs one job at a time, so no two builds ever
# contend for its lock. That contention is why this is not one shared
# target-dir for the whole host.
#
# Bounded: when the persistent dir is over <max-gib>, it is deleted and
# recreated, with a ::warning:: naming the measured size and the path. That is
# the whole eviction policy -- coarse, and loud every time it fires.
#
# Usage:
#   persistent-target.sh persist <workspace-target> <persistent-dir> <max-gib>
#   persistent-target.sh local   <workspace-target>
#
# `local` is the opt-out: a real directory in the workspace, as before, for a
# job whose target/ must be visible where the persistent dir is not (a
# container that mounts only the checkout).
set -euo pipefail

die() {
  echo "::error::persistent-target: $*"
  exit 1
}

mode="${1:-}"
link="${2:-}"
case "$link" in
  /*/*) ;;
  *) die "workspace target path must be absolute and not a top-level directory, got '$link'" ;;
esac

# A symlink left by an earlier run: `git clean` normally removes it, but a
# workspace that was not cleaned would otherwise keep writing through it.
drop_link() {
  if [ -L "$link" ]; then
    echo "persistent-target: removing symlink $link -> $(readlink "$link")"
    rm -f "$link"
  fi
}

if [ "$mode" = local ]; then
  drop_link
  mkdir -p "$link"
  echo "persistent-target: $link is a local directory (not persisted)"
  exit 0
fi

[ "$mode" = persist ] || die "mode must be 'persist' or 'local', got '$mode'"
persist="${3:-}"
max_gib="${4:-}"
[[ "$max_gib" =~ ^[1-9][0-9]*$ ]] || die "max-gib must be a positive integer, got '$max_gib'"
# This path is rm -rf'd when over the cap. Refuse anything that is not
# recognisably ours.
case "$persist" in
  /*/ferrosa-ci/*/target*) ;;
  *) die "persistent dir must be <tool cache>/ferrosa-ci/<repo>/target*, got '$persist'" ;;
esac

mkdir -p "$persist"
used_kib="$(du -sk "$persist" | cut -f1)"
cap_kib=$((max_gib * 1024 * 1024))
if [ "$used_kib" -gt "$cap_kib" ]; then
  used_gib="$(awk -v k="$used_kib" 'BEGIN { printf "%.1f", k / 1048576 }')"
  echo "::warning::persistent target $persist is ${used_gib} GiB, over the ${max_gib} GiB cap; deleting it, so this job builds from scratch"
  rm -rf "$persist"
  mkdir -p "$persist"
  used_kib=0
fi

if [ -L "$link" ]; then
  if [ "$(readlink "$link")" != "$persist" ]; then
    drop_link
  fi
elif [ -e "$link" ]; then
  echo "persistent-target: replacing the real directory $link ($(du -sk "$link" | cut -f1) KiB) with a link to $persist"
  rm -rf "$link"
fi

mkdir -p "$(dirname "$link")"
ln -sfn "$persist" "$link"
[ "$(readlink "$link")" = "$persist" ] || die "$link does not point at $persist after linking"
echo "persistent-target: $link -> $persist (${used_kib} KiB, cap ${max_gib} GiB)"
