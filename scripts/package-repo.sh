#!/usr/bin/env bash
#
# package-repo.sh — package a DNF repository as a zstd tarball for release.
#
# Usage:
#   ./scripts/package-repo.sh <dnf-repo-dir> <version>
# Example:
#   ./scripts/package-repo.sh f44 1.1.0
#
# What it does:
#   1. Stages a copy of <dnf-repo-dir> (the input dir is never modified).
#   2. Regenerates repodata with createrepo_c (MUST — otherwise RPMs added
#      since the last package are invisible to dnf).
#   3. Verifies repodata/repomd.xml and at least one .rpm exist.
#   4. Writes dist/ai-custom-infra-<version>.tar.zst with the repo contents
#      at the ARCHIVE ROOT (repodata/…, lemonade/…rpm, …) — required, because
#      repomd.xml references repo-relative paths.
#
# Requirements: createrepo_c, zstd, tar (with zstd support), git (for repo root).
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[ $# -eq 2 ] || { echo "usage: $(basename "$0") <dnf-repo-dir> <version>" >&2; exit 2; }
src=$1
version=$2

[[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die "invalid version '$version'"
command -v createrepo_c >/dev/null 2>&1 || die "createrepo_c not found (dnf install createrepo_c)"
command -v zstd >/dev/null 2>&1 || die "zstd not found (dnf install zstd)"
[ -d "$src" ] || die "repo dir '$src' not found"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$script_dir")

# 1. Stage a copy so the input dir is never modified.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -a -- "$src/." "$stage/repo"

# 2. Fresh repodata (no comps/updateinfo in this project; a full regenerate
#    is deterministic and leaves no stale metadata files behind).
rm -rf "$stage/repo/repodata"
createrepo_c --general-compress-type=zstd "$stage/repo" >/dev/null

# 3. Verify.
[ -f "$stage/repo/repodata/repomd.xml" ] || die "createrepo_c did not produce repodata/repomd.xml"
rpm_count=$(find "$stage/repo" -name '*.rpm' -type f | wc -l)
[ "$rpm_count" -ge 1 ] || die "no .rpm files found under '$src'"

# 4. Write the tarball: repo contents at the archive root.
mkdir -p "$root/dist"
out="$root/dist/ai-custom-infra-$version.tar.zst"
tar --zstd -cf "$out" -C "$stage/repo" .

echo "wrote $out ($(du -h "$out" | cut -f1), $rpm_count RPMs)"
echo "top-level archive entries:"
zstd -dc "$out" | tar -t | grep -vE '^\./$' | sed 's|^\./||' | cut -d/ -f1 | sort -u | sed 's/^/  /'
