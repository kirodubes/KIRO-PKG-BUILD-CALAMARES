# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

PKGBUILDs and build automation for the **Kiro** Arch-based distro. The two primary deliverables are:

- **`calamares` / `calamares-next`** — versioned build directories for the Calamares installer, built from a Codeberg fork (`erikdubois/calamares`) via chroot.
- **`kiro-calamares-config` / `kiro-calamares-config-next`** — packaging of the Calamares configuration pulled from the matching GitHub repo at build time.
- **`kiro-dummy`** — placeholder package (`kiro-dummy-git`) that clones `kiro-system-installation`.

Built packages land in `~/KIRO/kiro_repo/x86_64/` (KIRO packages) or `~/EDU/nemesis_repo/x86_64/` (EDU packages). The `build_package()` function in `build.sh` routes by checking whether the path contains "kiro".

## Build commands

Each package directory is self-contained. From inside a package directory:

```bash
bash build.sh      # bump version, compare to .previous-version, build via chroot if changed
bash setup.sh      # configure git remote (run once per clone)
bash up.sh         # git pull, optionally run chaotic.sh/repo.sh, commit and push
```

From the repo root:

```bash
bash copy-files-to-all-folders.sh   # propagate build.sh to every subdir that has a PKGBUILD
```

The root `build.sh` is the canonical template — `copy-files-to-all-folders.sh` copies it to all package subdirs, so edits to shared build logic should be made in the root `build.sh` first, then propagated.

## Version scheme

- **Date-versioned packages** (`pkgver` matches `^[0-9]{2}\.[0-9]{2}$`, e.g. `26.05`): `bump_version()` auto-increments to `YY.MM` + two-digit `pkgrel`. A new month resets `pkgrel` to `01`.
- **Upstream-versioned packages** (e.g. `calamares` with `pkgver=3.3.14.r132.g841b478`): `bump_version()` skips the auto-bump. Version comes from `pkgver()` in the PKGBUILD at `makechrootpkg` time.
- **Source URL embeds version**: also skipped with a warning — set manually.

`.current-version` and `.previous-version` files in each package dir track the last-known state; `check_version()` compares them to decide whether to skip or run the build.

## Build mechanics

`build_package()` always:
1. Copies the package dir to `/tmp/tempbuild/` (keeps the source tree clean).
2. Runs `arch-nspawn <chroot>/root pacman -Syu` then `makechrootpkg -c -r <chroot>` by default (`CHOICE=1`). Add a package name to `makepkglist` in `build.sh` to use plain `makepkg -s` instead.
3. Copies the resulting `.pkg.tar.zst` to the repo directory with `cp -n` (no overwrite).
4. Appends the package name to `/tmp/installed` if more than 2 old versions accumulate in the destination.

Chroot path: `~/Documents/chroot-archlinux`.

## calamares PKGBUILD specifics

- Source: `git+https://codeberg.org/erikdubois/calamares` (fork).
- `prepare()` copies local `modules/` into `$srcdir/calamares/src/modules/` — patched `bootloader/main.py` and `packages/main.py` live there.
- Built with Qt6 (`-DWITH_QT6=ON`), several unused modules skipped via `-DSKIP_MODULES`.
- Installs `cal-kiro.desktop` (to `/usr/share/applications/` and `/home/liveuser/Desktop/`), `calamares-wrapper`, and `calamares_polkit`.
- `calamares-next` variant: same structure, provides `calamares-next`, conflicts with `calamares`.

## Script template

All scripts follow the standard template (see global CLAUDE.md). The `#####` banner width is 76 `#` characters in root-level scripts; subdirectory `setup.sh`/`up.sh` use 60 `#` characters (`############################################################`). Match whichever width is already used in the file being edited.
