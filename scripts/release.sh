#!/usr/bin/env bash
#
# release.sh — package a DNF repository and publish it as a GitHub release, in
# one step.
#
# Combines what used to be scripts/package-repo.sh and scripts/publish-release.sh
# into a single, single-purpose tool:
#
#   1. stage a COPY of the repo dir (the input is never modified)
#   2. reorganize the RPMs into the standard <repo>/$releasever/$basearch layout
#      (releasever + basearch parsed from each RPM name; only x86_64 is
#      published), split across three repos:
#        - ${REPO_NAME}            binaries
#        - ${REPO_NAME}-source     *.src.rpm
#        - ${REPO_NAME}-debuginfo  *-debuginfo- / *-debugsource-
#   3. regenerate repodata with createrepo_c for each repo (MUST — otherwise new
#      RPMs are invisible to dnf); repodata sits at each repo's root and
#      references the repo-relative $releasever/$basearch paths
#   4. verify each repo is a usable DNF repo (repomd.xml + >=1 .rpm)
#   5. write dist/<REPO_NAME>-<version>.tar.zst with the three repo dirs at
#      ARCHIVE ROOT (ai-custom-infra/…, ai-custom-infra-source/…, …) — the
#      archive-root layout is required because repomd.xml references
#      repo-relative paths
#   6. create the GitHub release ai-custom-infra-<version> with that tarball as
#      the asset; the release triggers .github/workflows/deploy.yml
#   7. delete the local tarball — on success OR failure (see cleanup below)
#
# Add --dry-run to stop after step 4 (repodata regenerated, layout verified)
# without writing the tarball or creating the release — no GitHub side effects,
# so you can inspect the result before publishing.
#
# The tarball is always generated (there is no "package without publishing" mode
# unless --dry-run is given), so cleanup is unconditional: an EXIT trap removes
# the tarball (and the temp staging dir) no matter how the script exits. A failed
# attempt simply re-runs from a fresh staged copy.
#
# Requirements: createrepo_c, zstd, tar (with zstd support), git, gh
# (authenticated, e.g. via `gh auth login` or GH_TOKEN).

set -euo pipefail

REPO_NAME="ai-custom-infra"
SITE_URL="https://enricotagliavini.github.io/repositories/ai-custom-infra"
# The three repos published under the archive root, in order.
REPOS=("$REPO_NAME" "${REPO_NAME}-source" "${REPO_NAME}-debuginfo")

# --- state (filled by parse_args) ---
repo_dir=""
version=""
notes=""
dry_run=0
stage_dir=""
tarball=""

# Print CLI help to stdout.
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <dnf-repo-dir> <version>

Package the DNF repository at <dnf-repo-dir>, publish it as the GitHub release
${REPO_NAME}-<version> (the tarball attached as the asset), then remove the
local tarball. This triggers .github/workflows/deploy.yml.

The RPMs are reorganized into the standard per-version layout
(\$releasever/\$basearch), split across three repos: ${REPO_NAME},
${REPO_NAME}-source (source RPMs) and ${REPO_NAME}-debuginfo (debuginfo/
debugsource). Only x86_64 is published.

Options:
  -n, --notes TEXT     release notes (default: "${REPO_NAME} DNF repository, version <version>.")
  --dry-run            stage, reorganize and index the repo, then stop without
                       writing the tarball or creating the release (no GitHub
                       side effects) — inspect the resulting layout first
  -h, --help           show this help and exit

The <dnf-repo-dir> is only staged as a copy and is never modified. The local
tarball is removed automatically after the release is created — on success or
failure.

Example:
  $(basename "$0") --dry-run f44 1.1.0
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

# Abort early if any required build tool is missing, with an install hint.
check_build_tools() {
  local dep
  for dep in createrepo_c zstd tar; do
    command -v "$dep" >/dev/null 2>&1 || die "$dep not found (dnf install $dep)"
  done
}

# gh must be authenticated; exercise the token gh will actually use
# (not `gh auth status`, which can fail on a stale unrelated credential).
check_gh() {
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
  cp -a -- "$repo_dir/." "$stage_dir/input"
}

# Classify an RPM (by basename) into one of the three published repos,
# returning the repo directory name:
#   *.src.rpm                        -> ${REPO_NAME}-source
#   *-debuginfo- / *-debugsource-    -> ${REPO_NAME}-debuginfo
#   everything else                  -> ${REPO_NAME}
classify_rpm() {
  local rpm="$1"
  if [[ $rpm == *.src.rpm ]]; then
    echo "${REPO_NAME}-source"
  elif [[ $rpm == *-debuginfo-* || $rpm == *-debugsource-* ]]; then
    echo "${REPO_NAME}-debuginfo"
  else
    echo "$REPO_NAME"
  fi
}

# Extract $releasever from an RPM basename: the release tag (e.g. fc44) with a
# leading 'fc' stripped -> 44. Works for .src.rpm and binary RPMs alike.
extract_releasever() {
  local base="${1%.rpm}"
  local tag="${base%.*}"; tag="${tag##*.}"
  echo "${tag#fc}"
}

# Extract the arch field from an RPM basename: the last dotted field (e.g.
# x86_64), or 'src' for source RPMs, which have no arch.
extract_basearch() {
  local base="${1%.rpm}"
  echo "${base##*.}"
}

# Split the flat RPM tree into the three versioned repos, each laid out as
# <repo>/$releasever/$basearch/, then regenerate repodata for each. RPMs are
# classified by name (see classify_rpm); $releasever and $basearch are parsed
# from each name. Source RPMs are arch-independent and published under x86_64
# (where dnf's $basearch resolves). Only x86_64 is published; other arches are
# skipped with a warning so nothing silently disappears into an unpublished arch
# tree. The input copy is never modified.
reorganize() {
  local root="$stage_dir/repo"
  local rpm base repo arch releasever dest
  rm -rf -- "${REPOS[@]/#/$root/}"
  while IFS= read -r -d '' rpm; do
    base=$(basename -- "$rpm")
    repo=$(classify_rpm "$base")
    releasever=$(extract_releasever "$base")
    arch=$(extract_basearch "$base")
    # Source RPMs are arch-independent; publish under x86_64 (where dnf's
    # $basearch resolves) so the source repo is reachable via baseurl.
    [[ $repo == "${REPO_NAME}-source" ]] && arch="x86_64"
    if [[ $repo != "${REPO_NAME}-source" && $arch != x86_64 ]]; then
      echo "skip $base: basearch '$arch' (only x86_64 is published)" >&2
      continue
    fi
    dest="$root/$repo/$releasever/$arch"
    mkdir -p -- "$dest"
    cp -a -- "$rpm" "$dest/"
  done < <(find "$stage_dir/input" -name '*.rpm' -type f -print0)

  # Regenerate repodata for each repo (full regenerate: deterministic, drops
  # stale references). repodata sits at each repo's root.
  local repo
  for repo in "${REPOS[@]}"; do
    regenerate_repodata "$root/$repo"
  done
}

# Full regenerate (not --update): deterministic output, no stale metadata files
# left behind, and stale package references (e.g. an RPM that was removed) are
# dropped. This project has no comps/updateinfo, so nothing is lost by
# regenerating from scratch. $1 is the repo dir to index.
regenerate_repodata() {
  local repo_dir="$1"
  rm -rf -- "$repo_dir/repodata"
  createrepo_c --general-compress-type=zstd "$repo_dir" >/dev/null
}

# Fail if any repo is not a usable DNF repo: each must have repomd.xml and
# at least one .rpm.
verify_repos() {
  local repo rpm_count
  for repo in "${REPOS[@]}"; do
    [ -f "$stage_dir/repo/$repo/repodata/repomd.xml" ] \
      || die "$repo: createrepo_c did not produce repodata/repomd.xml"
    rpm_count=$(find "$stage_dir/repo/$repo" -name '*.rpm' -type f | wc -l)
    [ "$rpm_count" -ge 1 ] \
      || die "$repo: no .rpm files — nothing classified into it (check names?)"
    echo "  $repo: $rpm_count RPMs"
  done
}

# Let the user eyeball the archive layout: the top-level entries must be the
# three repo directories (ai-custom-infra/…), not a wrapper dir.
print_top_level_entries() {
  echo "top-level archive entries:"
  zstd -dc "$tarball" | tar -t | grep -vE '^\./$' | sed 's|^\./||' | cut -d/ -f1 | sort -u | sed 's/^/  /'
}

# Write dist/<REPO_NAME>-<version>.tar.zst. The final "." is what puts the three
# repo dirs at the ARCHIVE ROOT (mandatory — see header comment).
write_tarball() {
  local root
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  tarball="$root/dist/${REPO_NAME}-${version}.tar.zst"
  mkdir -p "$(dirname -- "$tarball")"
  tar --zstd -cf "$tarball" -C "$stage_dir/repo" .
  echo "wrote $tarball ($(du -h "$tarball" | cut -f1))"
  print_top_level_entries
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
  # Push the marker first: --target resolves the SHA server-side, and an
  # unpushed commit is what caused the 422 "target_commitish is invalid". The
  # marker is a bare commit (no branch), so it can only be pushed via a ref
  # pointing at it — use the release tag, which also becomes this release's git
  # tag (matching releases 1.0.x).
  git tag "${REPO_NAME}-${version}" "$marker_sha" >/dev/null
  git push origin "${REPO_NAME}-${version}" \
    || die "could not push release marker/tag — aborting before publishing"

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
  parsed=$(getopt -o n:h --long notes:,help,dry-run -n "$script_name" -- "$@") \
    || { usage >&2; exit 2; }
  eval set -- "$parsed"
  while true; do
    case $1 in
      -n|--notes) notes=$2; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
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
  check_build_tools
  if [ "$dry_run" -ne 1 ]; then
    check_gh
    # Fail fast if the tag already exists, before staging or packaging.
    if release_exists; then
      die "release '${REPO_NAME}-${version}' already exists — use a new version"
    fi
  fi
  stage_repo
  reorganize
  verify_repos
  if [ "$dry_run" -eq 1 ]; then
    echo
    echo "dry-run: skipped tarball + release. Resulting repo layout:"
    ( cd "$stage_dir/repo" && find "${REPOS[@]}" -type f \( -name '*.rpm' -o -name repomd.xml \) | sort | sed 's/^/  /' )
    return 0
  fi
  write_tarball
  create_release
  echo
  echo "release ${REPO_NAME}-${version} created; the pipeline is deploying the site now."
  echo "verify in a few minutes:"
  echo "  curl -fsS ${SITE_URL}/repodata/repomd.xml"
}

main "$@"
