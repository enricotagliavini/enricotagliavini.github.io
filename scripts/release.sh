#!/usr/bin/env bash
#
# release.sh — package a DNF repository and publish it as a GitHub release, in
# one step.
#
# Combines what used to be scripts/package-repo.sh and scripts/publish-release.sh
# into a single, single-purpose tool:
#
#   1. stage a COPY of the repo dir (the input is never modified)
#   2. regenerate repodata with createrepo_c (MUST — otherwise new RPMs are
#      invisible to dnf)
#   3. verify the staged repo is a usable DNF repo (repomd.xml + >=1 .rpm)
#   4. write dist/<REPO_NAME>-<version>.tar.zst with the repo at ARCHIVE ROOT
#      (repodata/…, lemonade/…rpm, …) — the archive-root layout is required
#      because repomd.xml references repo-relative paths
#   5. create the GitHub release ai-custom-infra-<version> with that tarball as
#      the asset; the release triggers .github/workflows/deploy.yml
#   6. delete the local tarball — on success OR failure (see cleanup below)
#
# The tarball is always generated (there is no "package without publishing"
# mode), so cleanup is unconditional: an EXIT trap removes the tarball (and the
# temp staging dir) no matter how the script exits. A failed attempt simply
# re-runs from a fresh staged copy.
#
# Requirements: createrepo_c, zstd, tar (with zstd support), git, gh
# (authenticated, e.g. via `gh auth login` or GH_TOKEN).

set -euo pipefail

REPO_NAME="ai-custom-infra"
SITE_URL="https://enricotagliavini.github.io/repositories/ai-custom-infra"

# --- state (filled by parse_args) ---
repo_dir=""
version=""
notes=""
stage_dir=""
tarball=""

# Print CLI help to stdout.
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <dnf-repo-dir> <version>

Package the DNF repository at <dnf-repo-dir>, publish it as the GitHub release
${REPO_NAME}-<version> (the tarball attached as the asset), then remove the
local tarball. This triggers .github/workflows/deploy.yml.

Options:
  -n, --notes TEXT     release notes (default: "${REPO_NAME} DNF repository, version <version>.")
  -h, --help           show this help and exit

The <dnf-repo-dir> is only staged as a copy and is never modified. The local
tarball is removed automatically after the release is created — on success or
failure.

Example:
  $(basename "$0") f44 1.1.0
EOF
}

# Print an error to stderr and exit 1.
die() {
  echo "error: $*" >&2
  exit 1
}

# Remove the temp staging dir and the local tarball. Registered as an EXIT trap
# by stage_repo; `|| return 0` keeps the script's real exit status: under
# `set -e` a failing `[ -n ]` in an `&&` list would otherwise become the final
# exit code. Both paths are optional, so a missing stage_dir or tarball is fine.
cleanup() {
  [ -n "$stage_dir" ] && rm -rf -- "$stage_dir" || return 0
  [ -n "$tarball" ] && rm -f -- "$tarball" || return 0
  return 0
}

# Abort early if any required tool is missing, with an install hint.
check_deps() {
  local dep
  for dep in createrepo_c zstd tar git gh; do
    command -v "$dep" >/dev/null 2>&1 || die "$dep not found (dnf install $dep)"
  done
  # gh must be authenticated; exercise the token gh will actually use
  # (not `gh auth status`, which can fail on a stale unrelated credential).
  gh api rate_limit >/dev/null 2>&1 \
    || die "gh is not authenticated (run: gh auth login, or export GH_TOKEN)"
}

# The version becomes part of the release tag and asset name, so keep it to
# characters that are safe in git refs and file names.
validate_version() {
  [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] \
    || die "invalid version '$version' (allowed: letters, digits, . _ + -)"
}

# Copy the input repo into a fresh temp dir. Everything below operates on the
# copy, so the caller's repo dir is never modified.
stage_repo() {
  [ -d "$repo_dir" ] || die "repo dir '$repo_dir' not found"
  stage_dir=$(mktemp -d)
  trap cleanup EXIT
  cp -a -- "$repo_dir/." "$stage_dir/repo"
}

# Full regenerate (not --update): deterministic output, no stale metadata files
# left behind, and stale package references (e.g. an RPM that was removed) are
# dropped. This project has no comps/updateinfo, so nothing is lost by
# regenerating from scratch.
regenerate_repodata() {
  rm -rf "$stage_dir/repo/repodata"
  createrepo_c --general-compress-type=zstd "$stage_dir/repo" >/dev/null
}

# Fail if the staged repo is not a usable DNF repo: repomd.xml must exist and
# at least one .rpm must be present.
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
  echo "top-level archive entries:"
  zstd -dc "$tarball" | tar -t | grep -vE '^\./$' | sed 's|^\./||' | cut -d/ -f1 | sort -u | sed 's/^/  /'
}

# Write dist/<REPO_NAME>-<version>.tar.zst. The final "." is what puts the repo
# contents at the ARCHIVE ROOT (mandatory — see header comment).
write_tarball() {
  local root
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  tarball="$root/dist/${REPO_NAME}-${version}.tar.zst"
  mkdir -p "$(dirname -- "$tarball")"
  tar --zstd -cf "$tarball" -C "$stage_dir/repo" .
  echo "wrote $tarball ($(du -h "$tarball" | cut -f1))"
  print_top_level_entries "$tarball"
}

# True if a release with this tag already exists. Release tags are unique, so an
# update always requires a new version (this is the hard error in main(), hit
# before packaging so an already-published version never produces a tarball).
release_exists() {
  gh release view "${REPO_NAME}-${version}" >/dev/null 2>&1
}

# Create the release with the tarball as the only asset, tagged at a fresh
# marker commit (see note below) so the deploy lands on a never-used SHA.
#
# Why a marker commit: GitHub Pages caches a deployment per commit SHA and
# skips a redeploy for a SHA it already served. A release that targets main's
# HEAD re-deploys that already-served SHA, so Pages no-ops and the new RPMs
# never go live. `git commit-tree` builds a new commit object with the exact
# same tree as the current HEAD (identical site content) but a unique SHA;
# tagging the release at it forces Pages to rebuild. The marker is a bare
# commit (no branch), so main's history stays clean — git pushes it alongside
# the tag, keeping it reachable for the workflow's checkout.
create_release() {
  local marker_sha
  marker_sha=$(git commit-tree HEAD^{tree} -m "release marker: ${REPO_NAME}-${version}")
  gh release create "${REPO_NAME}-${version}" \
    --title "${REPO_NAME} ${version}" \
    --target "$marker_sha" \
    --notes "${notes:-${REPO_NAME} DNF repository, version ${version}.}" \
    "$tarball"
}

# Parse CLI arguments. `eval set -- "$parsed"` is the standard getopt idiom:
# it replaces the positional parameters with getopt's normalized output
# (options first, then "--", then the remaining positional arguments).
parse_args() {
  local script_name parsed
  script_name=$(basename "$0")
  parsed=$(getopt -o n:h --long notes:,help -n "$script_name" -- "$@") \
    || { usage >&2; exit 2; }
  eval set -- "$parsed"
  while true; do
    case $1 in
      -n|--notes) notes=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      *) die "internal error: unhandled option '$1'" ;;
    esac
  done
  [ $# -eq 2 ] || { usage >&2; exit 2; }
  repo_dir=$1
  version=$2
}

main() {
  parse_args "$@"
  validate_version
  check_deps
  # Fail fast if the tag already exists, before staging or packaging.
  if release_exists; then
    die "release '${REPO_NAME}-${version}' already exists — use a new version"
  fi
  stage_repo
  regenerate_repodata
  verify_repo
  write_tarball
  create_release
  echo
  echo "release ${REPO_NAME}-${version} created; the pipeline is deploying the site now."
  echo "verify in a few minutes:"
  echo "  curl -fsS ${SITE_URL}/repodata/repomd.xml"
}

main "$@"
