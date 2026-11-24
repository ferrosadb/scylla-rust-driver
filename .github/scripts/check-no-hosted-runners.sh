#!/usr/bin/env bash
# check-no-hosted-runners.sh -- fail when a workflow names a GitHub-hosted runner.
#
# The ferrosadb org's private repos run on Ferrosa's own runners (runner group
# ferrosa-private-builders). A job left on GitHub's pool does not merely cost
# money: once the org's Actions budget is spent, it fails instantly with "The
# job was not started because an Actions budget is preventing further use",
# and nothing in the workflow file says why. This guard keeps a hosted label
# from coming back in a copy-pasted job, a new workflow or a matrix entry.
#
# What it rejects, on any non-comment line of .github/workflows/*.yml|yaml:
#
#   * a GitHub-hosted image label -- ubuntu-*, macos-*, windows-* followed by
#     `latest` or a version, with any size/arch suffix (ubuntu-24.04-arm,
#     macos-15-xlarge) -- on a line that does not also say `self-hosted`.
#     Scanning every line, not just `runs-on:`, is what catches
#     `runs-on: ${{ matrix.runner }}` with `runner: ubuntu-latest` below it.
#     `ubuntu-24.04` is ALSO a label on the self-hosted Linux runners, which is
#     why a line carrying `self-hosted` passes.
#   * a `pull_request_target` trigger. It runs with the base repo's secrets on
#     code a pull request supplies, and on a persistent self-hosted runner that
#     code also gets the machine. (Fork PR workflows are disabled org-wide for
#     private repos; this keeps a workflow from opting back in.)
#
# The allowlist is explicit and inline: a line that must stay as it is carries
#
#   # github-hosted-ok: <reason>
#
# with a non-empty reason, and the guard prints every allowlisted line so the
# exceptions are visible in each run's log rather than silently skipped.
#
# Limitation, stated: a runs-on written as a multi-line block list with
# `self-hosted` and `ubuntu-24.04` on separate lines reads as hosted. Write
# runner lists in flow form, `[self-hosted, Linux, X64]`, as every workflow in
# these repos already does.
#
# Usage: check-no-hosted-runners.sh [workflow-dir]   (default .github/workflows)
# Exit 0 clean, 1 on a violation, 2 on misuse.
set -euo pipefail

dir="${1:-.github/workflows}"
if [ ! -d "$dir" ]; then
  echo "check-no-hosted-runners: no workflow directory at '$dir'" >&2
  exit 2
fi

hosted_re='(^|[^A-Za-z0-9_.-])(ubuntu|macos|windows)-(latest|[0-9]+(\.[0-9]+)?)(-[A-Za-z0-9-]+)?([^A-Za-z0-9_.-]|$)'
marker_re='#[[:space:]]*github-hosted-ok:[[:space:]]*[^[:space:]]'

violations=0
allowed=0
files=0

shopt -s nullglob
for file in "$dir"/*.yml "$dir"/*.yaml; do
  files=$((files + 1))
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in '#'*|'') continue ;; esac
    # Code is everything before the first ` #`: YAML comments need a space
    # before the hash, and `${{ }}` expressions never contain ` #`.
    code="${line%% \#*}"
    comment="${line#"$code"}"

    problem=""
    if [[ "$code" =~ $hosted_re ]] && [[ "$code" != *self-hosted* ]]; then
      problem="names a GitHub-hosted runner label"
    elif [[ "$code" =~ (^|[^A-Za-z_])pull_request_target([^A-Za-z_]|$) ]]; then
      problem="uses pull_request_target, which runs PR-supplied code with the base repo's secrets"
    fi
    [ -n "$problem" ] || continue

    if [[ "$comment" =~ $marker_re ]]; then
      allowed=$((allowed + 1))
      echo "allowlisted: $file:$lineno: ${trimmed}"
      continue
    fi
    violations=$((violations + 1))
    echo "::error file=$file,line=$lineno::$problem: ${trimmed}"
  done < "$file"
done

if [ "$files" -eq 0 ]; then
  echo "check-no-hosted-runners: no workflow files in '$dir'" >&2
  exit 2
fi

if [ "$violations" -gt 0 ]; then
  echo "check-no-hosted-runners: $violations violation(s) in $files workflow file(s)."
  echo "Run the job on [self-hosted, Linux, X64] or [self-hosted, macOS, ARM64]; if it truly"
  echo "must stay on GitHub's pool, end the line with '# github-hosted-ok: <reason>'."
  exit 1
fi
echo "check-no-hosted-runners: $files workflow file(s) clean, $allowed allowlisted line(s)."
