#!/usr/bin/env bash
# require-free-disk.sh -- fail loud before a job fills a persistent runner's disk.
#
# A GitHub-hosted VM is thrown away after each job, so a full disk ends one
# run. Ferrosa's runners are persistent machines: a full disk there fails every
# job that lands on the host afterwards, in whatever repo, with a symptom that
# names something else -- a linker SIGBUS, `No space left on device` from an
# archive extractor, or an image build that stops mid-layer (t_b0dd0312, the
# arm64 image runner). Checking before the job starts turns that into one line
# that names the filesystem and the free space.
#
# Usage: require-free-disk.sh <min-free-GiB> <path>...
#
# Each path is resolved to the filesystem that holds it (paths that do not
# exist are skipped with a note, so a job can pass every candidate location).
# Filesystems are de-duplicated, so a single disk is reported once.
# Exit 0 when every filesystem has at least <min-free-GiB>, 1 when one does not,
# 2 on misuse.
set -euo pipefail

if [ "$#" -lt 2 ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <min-free-GiB> <path>..." >&2
  exit 2
fi
min_gib="$1"
shift

seen=" "
low=0
checked=0
for path in "$@"; do
  if [ -z "$path" ] || [ ! -e "$path" ]; then
    echo "require-free-disk: skipping '${path}' (does not exist)"
    continue
  fi
  # POSIX df output: filesystem, 1K-blocks, used, available, capacity, mount.
  row="$(df -Pk "$path" | tail -1)"
  mount="$(echo "$row" | awk '{print $NF}')"
  case "$seen" in *" $mount "*) continue ;; esac
  seen="$seen$mount "
  avail_kib="$(echo "$row" | awk '{print $4}')"
  if ! [[ "$avail_kib" =~ ^[0-9]+$ ]]; then
    echo "::error::require-free-disk: could not read free space for '$path' from: $row"
    exit 1
  fi
  checked=$((checked + 1))
  avail_gib=$((avail_kib / 1024 / 1024))
  if [ "$avail_gib" -lt "$min_gib" ]; then
    low=$((low + 1))
    echo "::error::$(uname -n): only ${avail_gib} GiB free on $mount (holds $path); this job needs ${min_gib} GiB. Free space on the runner host before re-running -- the next job to land here fails the same way."
  else
    echo "require-free-disk: ${avail_gib} GiB free on $mount (holds $path), need ${min_gib}"
  fi
done

if [ "$checked" -eq 0 ]; then
  echo "::error::require-free-disk: none of the given paths exist, so nothing was checked"
  exit 1
fi
[ "$low" -eq 0 ]
