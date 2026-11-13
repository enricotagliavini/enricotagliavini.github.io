#!/usr/bin/env bash
#
# package-repo.sh — package a DNF repository as a zstd tarball for release.
#
# Stages a copy of the repo dir (the input is never modified), regenerates
# repodata with createrepo_c (MUST — otherwise RPMs added since the last
# package are invisible to dnf), verifies the result, and writes a tarball
# with the repo contents at the ARCHIVE ROOT (repodata/…, lemonade/…rpm, …).
# The archive-root layout is required because repomd.xml references
# repo-relative paths.
#
# Requirements: createrepo_c, zstd, tar (with zstd support).

set -euo pipefail

REPO_NAME="ai-custom-infra"

# --- state (filled by parse_args) ---
repo_dir=""
version=""
output_dir=""
stage_dir=""
tarball=""

# Print CLI help to stdout.
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <dnf-repo-dir> <version>

Package a DNF repository as ${REPO_NAME}-<version>.tar.zst.

Options:
  -o, --output-dir DIR   directory for the tarball (default: <repo root>/dist)
  -h, --help             show this help and exit

Example:
  $(basename "$0") f44 1.1.0
EOF
}

# Print an error to stderr and exit 1.
die() {
  echo "error: $*" >&2
  exit 1
}

# Remove the temporary staging dir (registered as an EXIT trap by stage_repo).
# `|| return 0` keeps the script's real exit status: under `set -e` a failing
# `[ -n ]` in an `&&` list would otherwise become the final exit code.
cleanup() {
  [ -n "$stage_dir" ] || return 0
  rm -rf -- "$stage_dir"
}

# Abort early if any required tool is missing, with an install hint.
check_deps() {
  local dep
  for dep in createrepo_c zstd tar; do
    command -v "$dep" >/dev/null 2>&1 || die "$dep not found (dnf install $dep)"
  done
}

# The version becomes part of the release tag and asset name, so keep it to
# characters that are safe in git refs and file names.
validate_version() {
  [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] \
    || die "invalid version '$version' (allowed: letters, digits, . _ + -)"
}

# Copy the input repo into a fresh temp dir. Everything below operates on
# the copy, so the caller's repo dir is never modified.
stage_repo() {
  [ -d "$repo_dir" ] || die "repo dir '$repo_dir' not found"
  stage_dir=$(mktemp -d)
  trap cleanup EXIT
  cp -a -- "$repo_dir/." "$stage_dir/repo"
}

# Full regenerate (not --update): deterministic output, no stale metadata
# files left behind, and stale package references (e.g. an RPM that was
# removed) are dropped. This project has no comps/updateinfo, so nothing is
# lost by regenerating from scratch.
regenerate_repodata() {
  rm -rf "$stage_dir/repo/repodata"
  createrepo_c --general-compress-type=zstd "$stage_dir/repo" >/dev/null
}

# Fail if the staged repo is not a usable DNF repo: repomd.xml must exist
# and at least one .rpm must be present.
verify_repo() {
  local rpm_count
  [ -f "$stage_dir/repo/repodata/repomd.xml" ] \
    || die "createrepo_c did not produce repodata/repomd.xml"
  rpm_count=$(find "$stage_dir/repo" -name '*.rpm' -type f | wc -l)
  [ "$rpm_count" -ge 1 ] || die "no .rpm files found under '$repo_dir'"
  echo "found $rpm_count RPMs"
}

# Let the user eyeball the archive layout: the top-level entries must be the
# repo's own directories (repodata, …), not a wrapper dir.
print_top_level_entries() {
  local tarball=$1
  echo "top-level archive entries:"
  zstd -dc "$tarball" | tar -t | grep -vE '^\./$' | sed 's|^\./||' | cut -d/ -f1 | sort -u | sed 's/^/  /'
}

# Write dist/<REPO_NAME>-<version>.tar.zst. The final "." is what puts the
# repo contents at the ARCHIVE ROOT (mandatory — see header comment).
write_tarball() {
  mkdir -p "$output_dir"
  tarball="$output_dir/${REPO_NAME}-${version}.tar.zst"
  tar --zstd -cf "$tarball" -C "$stage_dir/repo" .
  echo "wrote $tarball ($(du -h "$tarball" | cut -f1))"
  print_top_level_entries "$tarball"
}

# Parse CLI arguments. `eval set -- "$parsed"` is the standard getopt idiom:
# it replaces the positional parameters with getopt's normalized output
# (options first, then "--", then the remaining positional arguments).
parse_args() {
  local script_name parsed
  script_name=$(basename "$0")
  parsed=$(getopt -o o:h --long output-dir:,help -n "$script_name" -- "$@") \
    || { usage >&2; exit 2; }
  eval set -- "$parsed"
  while true; do
    case "$1" in
      -o|--output-dir) output_dir=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      *) die "internal error: unhandled option '$1'" ;;
    esac
  done
  [ $# -eq 2 ] || { usage >&2; exit 2; }
  repo_dir=$1
  version=$2
  local root
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  [ -n "$output_dir" ] || output_dir="$root/dist"
}

main() {
  parse_args "$@"
  validate_version
  check_deps
  stage_repo
  regenerate_repodata
  verify_repo
  write_tarball
}

main "$@"
