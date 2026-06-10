#!/bin/bash
set -euo pipefail
#####################################################################
# Author    : Erik Dubois
# Website   : https://kiroproject.be
#####################################################################
#
#   DO NOT JUST RUN THIS. EXAMINE AND JUDGE. RUN AT YOUR OWN RISK.
#
#   Purpose:
#   Build the Arch package described by the PKGBUILD in THIS directory
#   and ship it to the local kiro_repo, then publish kiro_repo.
#     1. git pull           - if this dir is itself a git repo
#     2. bump_version       - date-versioned pkgs (YY.MM) get a pkgrel
#                             bump; upstream-versioned pkgs (calamares)
#                             build their current pkgrel as-is
#     3. build              - makepkg -s in /tmp/tempbuild (clean tree)
#     4. copy               - the built .pkg.tar.zst into kiro_repo/x86_64
#     5. publish            - run kiro_repo/up.sh to push the repo remote
#
#   Why: one self-contained command per package dir. The flow-calamares /
#   flow-calamares-next wrappers add the "new numbered dir + pkgrel+1"
#   step on top of this — they do NOT publish, this script does.
#
#   Build method: makepkg (USE_CHROOT="no"). A clean chroot build failed
#   for calamares because makechrootpkg's chroot lacks the custom repos
#   (chaotic-aur / cachyos / kiro_repo) that the package's deps need.
#   Set USE_CHROOT="yes" only after adding those repos to the chroot's
#   pacman.conf — makepkg works because it uses the host's repos.
#####################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

#####################################################################
# Config
#####################################################################
USE_CHROOT="no"                                 # "yes" = makechrootpkg, "no" = makepkg
DESTINY="${HOME}/KIRO/kiro_repo/x86_64"         # local pacman repo package dir
REPO_UP="${HOME}/KIRO/kiro_repo/up.sh"          # publishes kiro_repo to its remote
CHROOT="${HOME}/Documents/chroot-archlinux"     # only used when USE_CHROOT="yes"

#####################################################################
# Colors
#####################################################################
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    CYAN="$(tput setaf 6)"
    RESET="$(tput sgr0)"
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" RESET=""
fi

#####################################################################
# Logging
#####################################################################
log_section() {
    echo
    echo "${GREEN}############################################################################${RESET}"
    echo "$1"
    echo "${GREEN}############################################################################${RESET}"
    echo
}

log_info() {
    echo
    echo "${BLUE}############################################################################${RESET}"
    echo "$1"
    echo "${BLUE}############################################################################${RESET}"
    echo
}

log_warn() {
    echo
    echo "${YELLOW}############################################################################${RESET}"
    echo "$1"
    echo "${YELLOW}############################################################################${RESET}"
    echo
}

log_error() {
    echo
    echo "${RED}############################################################################${RESET}"
    echo "$1"
    echo "${RED}############################################################################${RESET}"
    echo
}

log_success() {
    echo
    echo "${GREEN}############################################################################${RESET}"
    echo "$1"
    echo "${GREEN}############################################################################${RESET}"
    echo
}

#####################################################################
# Error handling
#####################################################################
on_error() {
    local lineno="$1"
    local cmd="$2"
    echo
    echo "${RED}ERROR on line ${lineno}: ${cmd}${RESET}"
    echo
    sleep 10
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

#####################################################################
# Functions
#####################################################################
git_pull_if_repo() {
    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
        log_section "Updating with git pull"
        git -C "${SCRIPT_DIR}" pull
    fi
}

bump_version() {
    local pkgbuild="${SCRIPT_DIR}/PKGBUILD"
    [[ ! -f "${pkgbuild}" ]] && { log_error "No PKGBUILD found in ${SCRIPT_DIR}"; exit 1; }

    local pkgname old_pkgver old_pkgrel new_pkgver new_pkgrel
    pkgname=$(grep -E '^pkgname=' "${pkgbuild}" | cut -d= -f2)
    old_pkgver=$(grep -E '^pkgver=' "${pkgbuild}" | cut -d= -f2)
    old_pkgrel=$(grep -E '^pkgrel=' "${pkgbuild}" | cut -d= -f2)

    # Upstream-versioned packages (e.g. calamares, pkgver=3.4.2.r4.g...) are
    # not date-bumped here — the flow-* wrappers bump pkgrel by creating the
    # next numbered build dir. Build the current pkgrel as-is.
    if [[ ! "${old_pkgver}" =~ ^[0-9]{2}\.[0-9]{2}$ ]]; then
        log_info "Upstream-versioned package (pkgver=${old_pkgver}) — building pkgrel=${old_pkgrel} as-is"
        return 0
    fi

    # A source URL that embeds the version cannot be auto-bumped safely.
    local source_line
    source_line=$(grep -E '^\s*source=' "${pkgbuild}" || true)
    if echo "${source_line}" | grep -qE '\$\{?pkgver\}?|\$\{?pkgrel\}?'; then
        log_warn "Source URL embeds pkgver/pkgrel — skipping auto-bump for '${pkgname}'. Set version manually when a new upstream release is published."
        return 0
    fi

    new_pkgver=$(date +%y.%m)
    if [[ "${new_pkgver}" != "${old_pkgver}" ]]; then
        new_pkgrel="01"                          # new month resets pkgrel
    else
        new_pkgrel=$(printf '%02d' $((10#${old_pkgrel} + 1)))
    fi

    sed -i "s/^pkgver=.*/pkgver=${new_pkgver}/" "${pkgbuild}"
    sed -i "s/^pkgrel=.*/pkgrel=${new_pkgrel}/" "${pkgbuild}"
    log_info "Updated '${pkgname}':
  pkgver: ${old_pkgver} → ${new_pkgver}
  pkgrel: ${old_pkgrel} → ${new_pkgrel}"
}

update_checksums() {
    # Regenerate sha256sums so an edited local source file (e.g. cal-kiro.desktop)
    # can't fail makepkg's validity check. The git source stays SKIP.
    if ! command -v updpkgsums >/dev/null 2>&1; then
        log_warn "updpkgsums not found (install pacman-contrib) — skipping checksum refresh"
        return 0
    fi
    log_section "Refreshing source checksums with updpkgsums"
    ( cd "${SCRIPT_DIR}" && updpkgsums )
    # updpkgsums clones the git source into this dir to hash it — don't keep that
    # ~91MB mirror (makepkg re-clones into /tmp/tempbuild at build time, and it
    # must never be committed/pushed to GitHub).
    rm -rf "${SCRIPT_DIR}/calamares"
}

publish_repo() {
    if [[ -x "${REPO_UP}" ]]; then
        log_section "Publishing kiro_repo"
        bash "${REPO_UP}" || log_warn "kiro_repo up.sh failed — push manually"
    else
        log_warn "kiro_repo up.sh not found at ${REPO_UP} — skipping publish"
    fi
}

build_package() {
    local search
    search="$(basename "${SCRIPT_DIR}")"

    [[ -d /tmp/tempbuild ]] && rm -rf /tmp/tempbuild
    mkdir /tmp/tempbuild
    cp -r "${SCRIPT_DIR}/"* /tmp/tempbuild/

    if [[ "${USE_CHROOT}" == "yes" ]]; then
        log_section "Building ${search} in CHROOT ${CHROOT}"
        arch-nspawn "${CHROOT}/root" pacman -Syu --noconfirm
        ( cd /tmp/tempbuild && makechrootpkg -c -r "${CHROOT}" )
    else
        log_section "Building ${search} with makepkg"
        ( cd /tmp/tempbuild && makepkg -s --noconfirm )
    fi

    log_section "Copying package to ${DESTINY}"
    mkdir -p "${DESTINY}"
    # Copy whatever makepkg actually produced — its filename embeds the dynamic
    # pkgver() output, which need not match this folder's name. Skip debug pkgs.
    local built
    mapfile -t built < <(find /tmp/tempbuild -maxdepth 1 -name '*.pkg.tar.zst' ! -name '*-debug-*')
    if [[ ${#built[@]} -eq 0 ]]; then
        log_error "No package produced in /tmp/tempbuild"
        exit 1
    fi
    cp -v "${built[@]}" "${DESTINY}/"

    publish_repo

    # Built in /tmp/tempbuild (wiped at the next run's start), so the source
    # dir never collects artifacts — nothing to clean up here.
    log_success "Build done for ${search}"
}

#####################################################################
# Main
#####################################################################
main() {
    git_pull_if_repo
    bump_version
    update_checksums
    build_package

    log_success "$(basename "$0") done"
}

main "$@"
