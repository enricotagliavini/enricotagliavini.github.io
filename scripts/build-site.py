#!/usr/bin/env python3
"""Generate the deployed DNF repository's HTML listings and .repo file.

Invoked from .github/workflows/deploy.yml's Build step:

    python3 scripts/build-site.py <repositories-dir>

<repositories-dir> holds the three DNF repos (ai-custom-infra,
ai-custom-infra-source, ai-custom-infra-debuginfo), each laid out as
<repo>/$releasever/$basearch/. For each repo this writes a package listing
(index.html); for the binaries repo it also writes the combined .repo file.

Each baseurl keeps the literal DNF variables `$releasever`/`$basearch`
(<https://enricotagliavini.github.io/repositories/<repo>/$releasever/$basearch/),
which dnf substitutes at runtime from the client's OS/arch — that is what makes
the client config resolvable and release-agnostic. The served tree
(`<repo>/$releasever/$basearch/repodata/`) is where the expanded baseurl lands;
the versioned components are never substituted here (they come from dnf).

The repos landing page (repositories/index.html) is static content in web/,
copied verbatim by the workflow, and is intentionally NOT generated here.
"""

import html
import sys
from pathlib import Path
from string import Template

# Canonical repo set: also the paths served from /repositories/<repo>/
# (see AGENTS.md constraint 3). The combined .repo file lists all three.
REPOS = (
    "ai-custom-infra",
    "ai-custom-infra-source",
    "ai-custom-infra-debuginfo",
)

# Per-repo metadata for the combined .repo file (display name + enabled flag).
# Binaries are enabled by default; source and debuginfo are opt-in.
REPO_SECTION = {
    "ai-custom-infra": ("AI Custom Infra", "1"),
    "ai-custom-infra-source": ("AI Custom Infra - Source", "0"),
    "ai-custom-infra-debuginfo": ("AI Custom Infra - Debuginfo", "0"),
}

BASE_URL = "https://enricotagliavini.github.io/repositories"

# <style> shared by the three per-repo listings (kept in one place so they
# never drift apart).
PER_REPO_STYLE = (
    ":root{color-scheme:light dark}"
    "body{font-family:system-ui,sans-serif;max-width:46rem;margin:3rem auto;"
    "padding:0 1rem;line-height:1.5}"
    "code{font-family:ui-monospace,monospace;font-size:.92em}"
    "table{border-collapse:collapse;width:100%}"
    "td,th{padding:.3rem .75rem .3rem 0;text-align:left}"
    "tr{border-bottom:1px solid rgba(127,127,127,.25)}"
    "a{color:#0645ad}"
)

REPO_PAGE = Template(
    "<!doctype html>\n"
    '<html lang="en"><head><meta charset="utf-8">\n'
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    "<title>$title</title>\n"
    "<style>$style</style>\n"
    "</head><body>\n"
    "<h1>$name</h1>\n"
    '<p><a href="../..">&larr; home</a> &middot; '
    '<a href="$repodata">repodata</a></p>\n'
    '<p>Download <a href="../ai-custom-infra/ai-custom-infra.repo">'
    "<code>ai-custom-infra.repo</code></a> and drop it into "
    "<code>/etc/yum.repos.d/</code>, then run "
    "<code>sudo dnf makecache</code>.</p>\n"
    "<h2>Packages</h2>\n"
    '<table><tr><th>package</th><th>size</th></tr>\n'
    "$rows"
    "</table>\n"
    "</body></html>\n"
)


def human_size(nbytes: int) -> str:
    """Format a byte count like `numfmt --to=iec` (base-1024, one decimal)."""
    if nbytes < 1024:
        return str(nbytes)
    value = float(nbytes)
    for suffix in ("K", "M", "G", "T", "P"):
        value /= 1024
        if value < 1024:
            return f"{value:.1f}{suffix}"
    return f"{value:.1f}P"


def render_repo_file() -> str:
    """The combined .repo file: all three repos, source/debuginfo disabled.

    The baseurl keeps the literal DNF variables `$releasever`/`$basearch` — dnf
    substitutes them at runtime from the client's OS/arch, so the same file
    works across releases and architectures. Nothing here is substituted: the
    concrete values come from dnf, never from this script.
    """
    sections = []
    for repo in REPOS:
        name, enabled = REPO_SECTION[repo]
        sections.append(
            f"[{repo}]\n"
            f"name={name}\n"
            f"baseurl={BASE_URL}/{repo}/$releasever/$basearch/\n"
            f"enabled={enabled}\n"
            "gpgcheck=0"
        )
    return "\n\n".join(sections) + "\n"


def render_row(repo_dir: Path, rpm: Path) -> str:
    relpath = str(rpm.relative_to(repo_dir))
    return (
        f"<tr><td><a href=\"{html.escape(relpath, quote=True)}\">"
        f"<code>{html.escape(rpm.name)}</code></a></td><td>"
        f"{human_size(rpm.stat().st_size)}</td></tr>\n"
    )


def write_repo_listing(repo_dir: Path) -> None:
    rpms = sorted(
        (p for p in repo_dir.rglob("*.rpm") if p.is_file()),
        key=lambda p: p.relative_to(repo_dir),
    )
    # repodata sits at the versioned leaf (<repo>/$releasever/$basearch/repodata/);
    # link to it by repo-relative path so the listing stays version-agnostic.
    repomd = next(repo_dir.rglob("repodata/repomd.xml"), None)
    repodata = str(repomd.relative_to(repo_dir)) if repomd else "repodata/repomd.xml"
    doc = REPO_PAGE.substitute(
        title=f"{repo_dir.name} - packages",
        style=PER_REPO_STYLE,
        name=html.escape(repo_dir.name),
        rows="".join(render_row(repo_dir, p) for p in rpms),
        repodata=repodata,
    )
    (repo_dir / "index.html").write_text(doc, encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: build-site.py <repositories-dir>", file=sys.stderr)
        return 2
    repos_dir = Path(sys.argv[1])

    # Combined .repo file lives in the binaries repo folder, where baseurl
    # points (matches the AGENTS.md client-install contract).
    (repos_dir / REPOS[0] / "ai-custom-infra.repo").write_text(
        render_repo_file(), encoding="utf-8"
    )

    # Per-repo package listing for each DNF repo present on disk.
    for repo in REPOS:
        write_repo_listing(repos_dir / repo)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
