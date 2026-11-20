#!/usr/bin/env bash
# Installs apt packages on a GitHub-hosted Ubuntu runner and survives a slow
# mirror.
#
# Why: on 2026-11-20 the release's Linux job spent 29 minutes in a plain
# `apt-get install` (206 MB at 122 kB/s from azure.archive.ubuntu.com, the same
# step takes about a minute on a normal runner) and the release never finished.
#
# What it does:
#   1. Downloads the packages first (`--download-only`) under a time limit.
#      Killing apt there is safe: nothing is installed yet and the partial
#      files are kept, so the next attempt resumes.
#   2. On a slow attempt it retries, then switches to another mirror.
#   3. Installs from the downloaded files (a few seconds, no time limit: it is
#      never interrupted mid-install).
#
# Usage: scripts/ci-apt-install.sh package...
# Tuning (environment): APT_ATTEMPT_SECONDS (default 240), APT_SUDO (default
# "sudo"), APT_GET (default "apt-get"), APT_SOURCES (the file naming the
# mirror, default /etc/apt/sources.list.d/ubuntu.sources).
set -euo pipefail

sudo_cmd="${APT_SUDO-sudo}"
apt="${APT_GET:-apt-get}"
limit="${APT_ATTEMPT_SECONDS:-240}"
sources="${APT_SOURCES:-/etc/apt/sources.list.d/ubuntu.sources}"
# Mirrors tried after the runner's default one (attempts 3 and 4).
fallbacks=("http://archive.ubuntu.com/ubuntu/" "https://mirrors.edge.kernel.org/ubuntu/")

if [ "$#" -eq 0 ]; then
  echo "usage: $0 package..." >&2
  exit 2
fi

run() { ${sudo_cmd:+$sudo_cmd} "$@"; }
opts=(-o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

use_mirror() {
  local uri="$1"
  if [ -f "$sources" ] && grep -qE '^URIs:' "$sources"; then
    echo "apt: switching to $uri"
    run sed -i -E "s#^URIs:.*#URIs: $uri#" "$sources"
    run "$apt" "${opts[@]}" update
  else
    echo "apt: no $sources to switch mirrors in; trying the same one again"
  fi
}

run "$apt" "${opts[@]}" update

attempt=1
max=4
until run timeout "$limit" "$apt" "${opts[@]}" install -y --download-only "$@"; do
  status=$?
  if [ "$attempt" -ge "$max" ]; then
    echo "apt: the download failed $max times (last status $status); giving up" >&2
    exit 1
  fi
  echo "apt: attempt $attempt did not finish in ${limit}s (status $status)"
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 3 ]; then
    use_mirror "${fallbacks[$((attempt - 3))]}"
  fi
done

run "$apt" "${opts[@]}" install -y "$@"
