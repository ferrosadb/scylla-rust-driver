#!/usr/bin/env bash
# require-host-tools.sh -- fail loud when a self-hosted runner lacks something.
#
# A GitHub-hosted job could `sudo apt-get install` whatever it needed, because
# the VM was destroyed afterwards. Ferrosa's Linux runners are a shared
# workstation: the runner account has no passwordless sudo, and a job that
# mutated the host's packages would change them for everything else running
# there. So jobs do not install packages. They check, and when something is
# missing they name the apt package to install ONCE on the host, rather than
# failing later inside a build script with an error that names neither.
#
# Usage:
#   require-host-tools.sh <command>=<apt package> ...
#   require-host-tools.sh <command>=<pkg> --pkg-config <module>=<apt package> ...
#
# Arguments after --pkg-config are pkg-config modules; --command switches back.
# Every argument is checked before exiting, so one run reports the whole list.
#
# Exit 0 when everything is present, 1 when something is missing, 2 on misuse.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command>=<apt package> ... [--pkg-config <module>=<apt package> ...]" >&2
  exit 2
fi

mode=command
checked=0
missing=()
packages=()

for arg in "$@"; do
  case "$arg" in
    --pkg-config) mode=pkg-config; continue ;;
    --command) mode=command; continue ;;
  esac
  name="${arg%%=*}"
  pkg="${arg#*=}"
  if [ "$name" = "$arg" ] || [ -z "$name" ] || [ -z "$pkg" ]; then
    echo "require-host-tools: malformed argument '$arg' (want name=package)" >&2
    exit 2
  fi
  checked=$((checked + 1))
  case "$mode" in
    command)
      if ! command -v "$name" >/dev/null 2>&1; then
        missing+=("$pkg  (provides the command '$name')")
        packages+=("$pkg")
      fi
      ;;
    pkg-config)
      if ! command -v pkg-config >/dev/null 2>&1; then
        echo "::error::pkg-config is not installed, so pkg-config module '$name' cannot be checked. Install: pkg-config" >&2
        exit 1
      fi
      if ! pkg-config --exists "$name"; then
        missing+=("$pkg  (provides the pkg-config module '$name')")
        packages+=("$pkg")
      fi
      ;;
  esac
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "::error::$(uname -n) is missing ${#missing[@]} host prerequisite(s). Jobs do not install packages on a shared runner; install these once on the host."
  printf '  %s\n' "${missing[@]}"
  unique="$(printf '%s\n' "${packages[@]}" | sort -u | tr '\n' ' ')"
  echo "::error::On the runner host: sudo apt-get install -y ${unique% }"
  exit 1
fi

echo "require-host-tools: all $checked checks present on $(uname -n)"
