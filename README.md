# enricotagliavini.github.io

GitHub Pages site hosting self-produced RPMs as a DNF repository:

**https://enricotagliavini.github.io/repositories/ai-custom-infra/** (Fedora 44)

## How it works

GitHub Pages serves the generated `gh-pages` branch. The DNF repository is **not**
committed here: RPMs exceed GitHub's 100 MB per-file limit, so each release ships
the whole repository as a single `tar` + zstd **release asset**. The Actions
pipeline downloads the asset, extracts it under `repositories/ai-custom-infra/`,
and publishes `web/` + the extracted repo to `gh-pages`.

```
local DNF repo (e.g. f44/)
   │ scripts/package-repo.sh  → dist/ai-custom-infra-<ver>.tar.zst
   │ scripts/publish-release.sh → gh release ai-custom-infra-<ver> (asset attached)
   ▼
.github/workflows/deploy.yml  →  gh-pages branch  →  GitHub Pages
```

## Updating the repository

From a machine with `gh` authenticated and the DNF repo directory ready
(RPMs in place):

```sh
./scripts/package-repo.sh f44 1.1.0      # stages a copy, regenerates repodata, writes dist/ai-custom-infra-1.1.0.tar.zst
./scripts/publish-release.sh 1.1.0       # creates release ai-custom-infra-1.1.0 with the tarball
```

Creating the release triggers the pipeline automatically; the site is live a few
minutes later. To publish a new version, always use a new version string
(existing tags are rejected).

Requirements: `gh`, `zstd`, `createrepo_c`, `git`.

## Installing on a client

```ini
[ai-custom-infra]
name=AI Custom Infra
baseurl=https://enricotagliavini.github.io/repositories/ai-custom-infra/
enabled=1
gpgcheck=0
```

Save as `/etc/yum.repos.d/ai-custom-infra.repo`, then `sudo dnf makecache`.

## Layout

| Path | Purpose |
|---|---|
| `web/` | Static site content, copied verbatim to the site root |
| `scripts/` | Packaging and release scripts (run locally, not in CI) |
| `.github/workflows/deploy.yml` | Deploys `web/` + latest release asset to `gh-pages` |
| `f44/`, `dist/` | Local-only (gitignored): DNF repo input and tarball output |

## Notes

- The `gh-pages` branch is fully generated — never edit or push to it.
- The URL path `/repositories/ai-custom-infra/` is stable across releases; the
  version lives only in the release tag, so client `.repo` files never need
  updating.
- Packages are unsigned (hence `gpgcheck=0`). If GPG signing is added later,
  update the snippet above and the workflow's `web/` copy.
- See `AGENTS.md` for the invariants an agent (or a tired future you) must not break.
