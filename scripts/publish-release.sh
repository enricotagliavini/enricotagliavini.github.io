#!/usr/bin/env bash
#
# publish-release.sh — create a GitHub release with the packaged repo tarball.
#
# Usage:
#   ./scripts/publish-release.sh <version> [tarball] [release-notes]
# Example:
#   ./scripts/publish-release.sh 1.1.0
#
# Creates release ai-custom-infra-<version> with the tarball attached as the
# asset. Creating the release triggers .github/workflows/deploy.yml, which
# deploys the site; it is live a few minutes later.
#
# An existing tag is a hard error — use a new version for each update.
#
# Requirements: gh (authenticated, e.g. via `gh auth login` or GH_TOKEN).
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 1 ] || { echo "usage: $(basename "$0") <version> [tarball] [release-notes]" >&2; exit 2; }
version=$1

command -v gh >/dev/null 2>&1 || die "gh not found (install the GitHub CLI)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login, or export GH_TOKEN)"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$script_dir")
tarball=${2:-"$root/dist/ai-custom-infra-$version.tar.zst"}
notes=${3:-"ai-custom-infra DNF repository, version $version."}

[ -f "$tarball" ] || die "tarball not found: $tarball (run: scripts/package-repo.sh <dir> $version)"

tag="ai-custom-infra-$version"
if gh release view "$tag" >/dev/null 2>&1; then
  die "release '$tag' already exists — use a new version"
fi

gh release create "$tag" \
  --title "ai-custom-infra $version" \
  --target main \
  --notes "$notes" \
  "$tarball"

echo
echo "release $tag created; the pipeline is deploying the site now."
echo "verify in a few minutes:"
echo "  curl -fsS https://enricotagliavini.github.io/repositories/ai-custom-infra/repodata/repomd.xml"
