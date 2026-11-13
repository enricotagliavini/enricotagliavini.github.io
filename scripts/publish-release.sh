#!/usr/bin/env bash
#
# publish-release.sh — create a GitHub release with the packaged repo tarball.
#
# Creates release ai-custom-infra-<version> with the tarball attached as the
# asset. Creating the release triggers .github/workflows/deploy.yml, which
# deploys the site (live a few minutes later).
#
# An existing tag is a hard error — use a new version for each update.
#
# Requirements: gh (authenticated, e.g. via `gh auth login` or GH_TOKEN).

set -euo pipefail

REPO_NAME="ai-custom-infra"
SITE_URL="https://enricotagliavini.github.io/repositories/ai-custom-infra"

# --- state (filled by parse_args) ---
version=""
tarball=""
notes=""

# Print CLI help to stdout.
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <version> [tarball]

Create GitHub release ${REPO_NAME}-<version> with the tarball attached.
This triggers the deploy pipeline for ${SITE_URL}/

Options:
  -n, --notes TEXT     release notes (default: "${REPO_NAME} DNF repository, version <version>.")
  -h, --help           show this help and exit

If [tarball] is omitted, <repo root>/dist/${REPO_NAME}-<version>.tar.zst is used.

Example:
  $(basename "$0") 1.1.0
EOF
}

# Print an error to stderr and exit 1.
die() {
  echo "error: $*" >&2
  exit 1
}

# Abort early if gh is missing or unauthenticated. Both `gh auth login`
# (credential store) and an exported GH_TOKEN satisfy this check.
check_deps() {
  command -v gh >/dev/null 2>&1 || die "gh not found (install the GitHub CLI)"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login, or export GH_TOKEN)"
}

# The version becomes part of the release tag, so keep it to characters that
# are safe in git refs and file names.
validate_version() {
  [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] \
    || die "invalid version '$version' (allowed: letters, digits, . _ + -)"
}

# Fill in the default tarball location and fail early if it does not exist
# (i.e. package-repo.sh was not run for this version).
resolve_tarball() {
  local root
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  [ -n "$tarball" ] || tarball="$root/dist/${REPO_NAME}-${version}.tar.zst"
  [ -f "$tarball" ] || die "tarball not found: $tarball (run: scripts/package-repo.sh <dir> $version)"
}

# True if a release with this tag already exists. Release tags are unique,
# so an update always requires a new version (this is the hard error in
# main()).
release_exists() {
  gh release view "${REPO_NAME}-${version}" >/dev/null 2>&1
}

# Create the release with the tarball as the only asset. The `release:
# created` event this generates is what triggers the deploy workflow.
create_release() {
  gh release create "${REPO_NAME}-${version}" \
    --title "${REPO_NAME} ${version}" \
    --target main \
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
    case "$1" in
      -n|--notes) notes=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      *) die "internal error: unhandled option '$1'" ;;
    esac
  done
  [ $# -ge 1 ] && [ $# -le 2 ] || { usage >&2; exit 2; }
  version=$1
  if [ $# -eq 2 ]; then
    tarball=$2
  fi
}

main() {
  parse_args "$@"
  validate_version
  check_deps
  resolve_tarball
  if release_exists; then
    die "release '${REPO_NAME}-${version}' already exists — use a new version"
  fi
  create_release
  echo
  echo "release ${REPO_NAME}-${version} created; the pipeline is deploying the site now."
  echo "verify in a few minutes:"
  echo "  curl -fsS ${SITE_URL}/repodata/repomd.xml"
}

main "$@"
