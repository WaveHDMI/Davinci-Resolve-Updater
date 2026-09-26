#!/bin/bash
# update-resolve.sh — Automated DaVinci Resolve updater for Arch Linux
# Checks for updates, downloads via Blackmagic API, builds via makepkg
#
# Usage: ./update-resolve.sh [--force] [--check-only] [--skip-install] [--reconfigure]
#
# Dependencies: curl, jq, makepkg, pacman, git, paru/yay
#
# On first run, you'll be prompted for registration info (required by
# Blackmagic's download API). Your info is saved locally in a config
# file and reused on subsequent runs.

set -euo pipefail

# Version info
SCRIPT_VERSION="2026.09.0"
RESOLVE_TESTED="21.1-1"

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
CONFIG_FILE="${SCRIPT_DIR}/.config"
PRODUCT="davinci-resolve"  # Change to "davinci-resolve-studio" for Studio edition

# AUR repository directory (self-contained in current folder / build directory)
if [[ -f "./PKGBUILD" ]]; then
    AUR_DIR="$(pwd)"
elif [[ -f "${SCRIPT_DIR}/PKGBUILD" ]]; then
    AUR_DIR="${SCRIPT_DIR}"
else
    AUR_DIR="${BUILD_DIR}/${PRODUCT}"
fi

# Blackmagic API endpoints
API_BASE="https://www.blackmagicdesign.com/api"

# This is a generic product/page identifier for the DaVinci Resolve download page.
# It is NOT user-specific. Source: Blackmagic's website download page URL structure.
# Also used in other open-source downloaders (e.g., Kimiblock/resolve-download).
REFER_ID="77ef91f67a9e411bbbe299e595b4cfcc"

# Shared curl options
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"

# Static Google Analytics cookies to make requests look like normal browser traffic.
# These are NOT tied to any real user session — they're generic values used to avoid
# potential bot detection by Blackmagic's API.
COOKIES="_ga=GA1.2.1849503966.1518103294; _gid=GA1.2.953840595.1518103294"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[resolve-update]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

# Parse arguments
FORCE=false
CHECK_ONLY=false
SKIP_INSTALL=false
RECONFIGURE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --check-only) CHECK_ONLY=true; shift ;;
        --skip-install) SKIP_INSTALL=true; shift ;;
        --reconfigure) RECONFIGURE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--force] [--check-only] [--skip-install] [--reconfigure]"
            echo "  --force        Update even if already on latest version"
            echo "  --check-only   Just check for updates, don't download or install"
            echo "  --skip-install Download and build but don't install"
            echo "  --reconfigure  Re-enter registration info"
            exit 0
            ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

# --- Configuration Management ---

prompt_config() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  First-time Setup: Registration Info                ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  Blackmagic requires registration to download.      ║${NC}"
    echo -e "${BLUE}║  This is the same info you'd enter on their site.   ║${NC}"
    echo -e "${BLUE}║  All fields are currently required to register.     ║${NC}"
    echo -e "${BLUE}║  It's saved locally and never shared elsewhere.     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    read -rp "First name: " REG_FIRSTNAME
    read -rp "Last name: " REG_LASTNAME
    read -rp "Email: " REG_EMAIL
    read -rp "Phone (digits only): " REG_PHONE
    read -rp "Country code (e.g., us, uk, de): " REG_COUNTRY
    read -rp "State/Province: " REG_STATE
    read -rp "City: " REG_CITY
    read -rp "Street address: " REG_STREET

    # Validate required fields
    if [[ -z "$REG_FIRSTNAME" || -z "$REG_LASTNAME" || -z "$REG_EMAIL" || -z "$REG_PHONE" || -z "$REG_COUNTRY" || -z "$REG_STATE" || -z "$REG_CITY" || -z "$REG_STREET" ]]; then
        err "All fields are required"
        exit 1
    fi

    # Save config (values are stored verbatim, not as shell code)
    {
        echo "# update-resolve configuration (auto-generated)"
        echo "# Re-run with --reconfigure to change these values"
        printf 'firstname=%s\n' "$REG_FIRSTNAME"
        printf 'lastname=%s\n' "$REG_LASTNAME"
        printf 'email=%s\n' "$REG_EMAIL"
        printf 'phone=%s\n' "$REG_PHONE"
        printf 'country=%s\n' "$REG_COUNTRY"
        printf 'state=%s\n' "$REG_STATE"
        printf 'city=%s\n' "$REG_CITY"
        printf 'street=%s\n' "$REG_STREET"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    ok "Configuration saved to ${CONFIG_FILE}"
    echo ""
}

load_config() {
    if [[ "$RECONFIGURE" == "true" || ! -f "$CONFIG_FILE" ]]; then
        prompt_config
    fi

    # Read config safely — no shell evaluation, just plain key=value parsing
    _cfg() { grep "^$1=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true; }
    local cfg_firstname cfg_lastname cfg_email cfg_phone cfg_country cfg_state cfg_city cfg_street
    cfg_firstname=$(_cfg firstname)
    cfg_lastname=$(_cfg lastname)
    cfg_email=$(_cfg email)
    cfg_phone=$(_cfg phone)
    cfg_country=$(_cfg country)
    cfg_state=$(_cfg state)
    cfg_city=$(_cfg city)
    cfg_street=$(_cfg street)

    # Build the JSON registration payload (jq handles escaping)
    REG_DATA=$(jq -n \
        --arg fn "$cfg_firstname" \
        --arg ln "$cfg_lastname" \
        --arg em "$cfg_email" \
        --arg ph "$cfg_phone" \
        --arg co "$cfg_country" \
        --arg st "$cfg_state" \
        --arg ci "$cfg_city" \
        --arg sr "$cfg_street" \
        '{firstname:$fn, lastname:$ln, email:$em, phone:$ph, country:$co, state:$st, city:$ci, street:$sr, product:"DaVinci Resolve"}')
}

sync_aur_repo() {
    log "Preparing AUR package repository..."
    mkdir -p "$AUR_DIR"
    if [[ -d "${AUR_DIR}/.git" ]]; then
        log "Found existing AUR git repository at: ${AUR_DIR}"
        log "Updating AUR repository via git pull..."
        # Revert any previously patched tracked files so git pull updates cleanly
        git -C "$AUR_DIR" checkout -- PKGBUILD .SRCINFO 2>/dev/null || true
        if git -C "$AUR_DIR" pull --ff-only 2>/dev/null; then
            ok "AUR repository updated to latest commit"
        else
            warn "Fast-forward git pull was not possible; attempting standard pull"
            git -C "$AUR_DIR" pull || warn "Could not pull latest changes; continuing with local repository as-is"
        fi
    else
        log "Cloning AUR repository for ${PRODUCT} into ${AUR_DIR}..."
        git clone "https://aur.archlinux.org/${PRODUCT}.git" "$AUR_DIR"
        ok "Cloned AUR repository"
    fi

    # Ensure local git exclude ignores build artifacts and downloads so git status remains clean
    if [[ -d "${AUR_DIR}/.git" ]]; then
        local exclude_file="${AUR_DIR}/.git/info/exclude"
        mkdir -p "${AUR_DIR}/.git/info"
        touch "$exclude_file"
        for pattern in "*.zip" "*.pkg.tar.*" "src/" "pkg/" "squashfs-root/"; do
            if ! grep -qxF "$pattern" "$exclude_file" 2>/dev/null; then
                echo "$pattern" >> "$exclude_file"
            fi
        done
    fi
}

# --- Dependency Management ---

install_paru() {
    log "AUR helper not found. Installing paru..."
    sudo pacman -S --needed --noconfirm git base-devel
    local helper_dir="${BUILD_DIR}/paru-bin"
    rm -rf "$helper_dir"
    mkdir -p "$BUILD_DIR"
    if git clone "https://aur.archlinux.org/paru-bin.git" "$helper_dir" 2>/dev/null; then
        (cd "$helper_dir" && yes "" | makepkg -si --noconfirm)
    elif git clone "https://aur.archlinux.org/paru.git" "$helper_dir" 2>/dev/null; then
        (cd "$helper_dir" && yes "" | makepkg -si --noconfirm)
    fi

    if command -v paru &>/dev/null; then
        ok "paru installed successfully"
        return 0
    else
        err "Failed to install paru automatically"
        return 1
    fi
}

install_dependencies() {
    log "Checking runtime & build dependencies from AUR PKGBUILD..."

    local deps=()
    # Read depends and makedepends directly from AUR PKGBUILD / .SRCINFO
    if [[ -f "${AUR_DIR}/.SRCINFO" ]]; then
        mapfile -t deps < <(grep -E '^\s*(depends|makedepends)\s*=' "${AUR_DIR}/.SRCINFO" | awk '{print $3}' | sed 's/[<>=].*//' | sort -u)
    fi

    # Fallback to makepkg --printsrcinfo if .SRCINFO is absent or empty
    if [[ ${#deps[@]} -eq 0 && -f "${AUR_DIR}/PKGBUILD" ]]; then
        mapfile -t deps < <((cd "$AUR_DIR" && makepkg --printsrcinfo 2>/dev/null) | grep -E '^\s*(depends|makedepends)\s*=' | awk '{print $3}' | sed 's/[<>=].*//' | sort -u)
    fi

    if [[ ${#deps[@]} -eq 0 ]]; then
        warn "Could not parse dependencies from PKGBUILD; skipping automatic dependency check."
        return 0
    fi

    # Use pacman -T to identify missing dependencies (respects 'provides' like opencl-nvidia)
    local missing=()
    mapfile -t missing < <(pacman -T "${deps[@]}" 2>/dev/null || true)

    local actual_missing=()
    for p in "${missing[@]}"; do
        [[ -n "$p" ]] && actual_missing+=("$p")
    done

    if [[ ${#actual_missing[@]} -eq 0 ]]; then
        ok "All dependencies already installed and satisfied"
        return 0
    fi

    log "Missing dependencies detected: ${actual_missing[*]}"

    local missing_repo=()
    local missing_aur=()

    for pkg in "${actual_missing[@]}"; do
        # Check if available in official repos
        if pacman -Si "$pkg" &>/dev/null 2>&1; then
            missing_repo+=("$pkg")
        else
            missing_aur+=("$pkg")
        fi
    done

    # Install official repo packages
    if [[ ${#missing_repo[@]} -gt 0 ]]; then
        log "Installing missing official repo packages: ${missing_repo[*]}"
        # yes "" auto-selects the default when pacman prompts for a provider choice.
        # When pacman finishes it closes stdin, causing yes to exit 141 (SIGPIPE).
        # With pipefail that would kill the script, so we check pacman's exit code directly.
        yes "" | sudo pacman -S --needed --noconfirm "${missing_repo[@]}" || [[ ${PIPESTATUS[1]} -eq 0 ]]
        ok "Repo dependencies installed"
    fi

    # Install AUR packages
    if [[ ${#missing_aur[@]} -gt 0 ]]; then
        local aur_helper=""
        if command -v paru &>/dev/null; then
            aur_helper="paru"
        elif command -v yay &>/dev/null; then
            aur_helper="yay"
        else
            log "No AUR helper found on system. Installing paru..."
            if install_paru; then
                aur_helper="paru"
            else
                err "The following packages are only available in the AUR: ${missing_aur[*]}"
                err "Install an AUR helper first: sudo pacman -S --needed git base-devel && git clone https://aur.archlinux.org/paru-bin.git && cd paru-bin && makepkg -si"
                return 1
            fi
        fi

        log "Installing missing AUR packages via ${aur_helper}: ${missing_aur[*]}"
        yes "" | "$aur_helper" -S --needed --noconfirm "${missing_aur[@]}" || [[ ${PIPESTATUS[1]} -eq 0 ]]
        ok "AUR dependencies installed"
    fi

    ok "All dependencies satisfied"
}

# --- Core Functions ---

# Step 1: Get installed version
get_installed_version() {
    pacman -Q "${PRODUCT}" 2>/dev/null | awk '{print $2}' | cut -d- -f1 || echo "none"
}

# Step 2: Get latest version from Blackmagic API
get_latest_version() {
    local response
    response=$(curl -s "${API_BASE}/support/latest-stable-version/${PRODUCT}/linux")

    if [[ -z "$response" || "$response" == *"error"* ]]; then
        err "Failed to query Blackmagic API for latest version"
        return 1
    fi

    local major minor release download_id
    major=$(echo "$response" | jq -r '.linux.major')
    minor=$(echo "$response" | jq -r '.linux.minor')
    release=$(echo "$response" | jq -r '.linux.releaseNum')
    download_id=$(echo "$response" | jq -r '.linux.downloadId')

    if [[ "$release" == "0" ]]; then
        echo "${major}.${minor}|${download_id}"
    else
        echo "${major}.${minor}.${release}|${download_id}"
    fi
}

# Step 3: Download the zip
download_resolve() {
    local download_id="$1"
    local version="$2"
    local zip_name="DaVinci_Resolve_${version}_Linux.zip"
    mkdir -p "$AUR_DIR"
    local zip_path="${AUR_DIR}/${zip_name}"

    # If the zip is already in BUILD_DIR, link it to AUR_DIR
    if [[ ! -f "$zip_path" && -f "${BUILD_DIR}/${zip_name}" ]]; then
        log "Found existing zip in ${BUILD_DIR}, linking to ${AUR_DIR}..."
        ln -sf "${BUILD_DIR}/${zip_name}" "$zip_path"
    fi

    if [[ -f "$zip_path" && "$FORCE" != "true" ]]; then
        ok "Zip already downloaded: ${zip_name}"
        return 0
    fi

    log "Requesting download URL from Blackmagic..."
    local download_url
    download_url=$(curl -s -X POST "${API_BASE}/register/us/download/${download_id}" \
        -H "Host: www.blackmagicdesign.com" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Origin: https://www.blackmagicdesign.com" \
        -H "User-Agent: ${UA}" \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "Referer: https://www.blackmagicdesign.com/support/download/${REFER_ID}/Linux" \
        -b "${COOKIES}" \
        -d "${REG_DATA}")

    if [[ -z "$download_url" || "$download_url" == *"Error"* || "$download_url" == *"Bad Request"* ]]; then
        err "Failed to get download URL: ${download_url}"
        return 1
    fi

    log "Downloading ${zip_name} (~3GB)..."

    curl -L --progress-bar \
        -H "User-Agent: ${UA}" \
        -o "$zip_path" \
        "$download_url"

    if [[ -f "$zip_path" ]]; then
        local size
        size=$(du -h "$zip_path" | cut -f1)
        ok "Downloaded: ${zip_name} (${size})"
    else
        err "Download failed"
        return 1
    fi
}

# Step 4: Configure PKGBUILD
setup_pkgbuild() {
    local version="$1"

    log "Configuring PKGBUILD in ${AUR_DIR}..."
    pushd "$AUR_DIR" > /dev/null

    # Clean previous build scratch artifacts but keep git repo and downloaded zips
    rm -rf src pkg squashfs-root *.pkg.tar* 2>/dev/null || true

    # Verify PKGBUILD exists
    if [[ ! -f "PKGBUILD" ]]; then
        err "PKGBUILD not found in ${AUR_DIR}"
        popd > /dev/null
        return 1
    fi

    # Defensive patch: AUR's prepare() hardcodes the exact glib version suffix
    # bundled inside the Resolve installer when stripping those bundled copies
    # before symlinking to the system libs. Blackmagic changes that bundled
    # version across Resolve releases (glib 2.68 -> 2.82 going from 20.x to
    # 21.1), so the literal filename goes stale and prepare() aborts on
    # `rm: cannot remove ...: No such file or directory`. Replacing the
    # hardcoded suffixes with globs keeps the same targets, version-agnostic.
    local broken_rm_block_68='rm squashfs-root/libs/libglib-2.0.so.0{,.6800.4} \
     squashfs-root/libs/libgio-2.0.so.0{,.6800.4} \
     squashfs-root/libs/libgmodule-2.0.so.0{,.6800.4} \
     squashfs-root/libs/libgobject-2.0.so.0{,.6800.4} \
     squashfs-root/libs/libc++.so.1{,.0} \
     squashfs-root/libs/libc++abi.so.1{,.0}'

    local broken_rm_block_82='rm squashfs-root/libs/libglib-2.0.so.0{,.8200.4} \
     squashfs-root/libs/libgio-2.0.so.0{,.8200.4} \
     squashfs-root/libs/libgmodule-2.0.so.0{,.8200.4} \
     squashfs-root/libs/libgobject-2.0.so.0{,.8200.4} \
     squashfs-root/libs/libc++.so.1{,.0} \
     squashfs-root/libs/libc++abi.so.1{,.0}'

    local fixed_rm_block='rm -f squashfs-root/libs/libglib-2.0.so.0* \
     squashfs-root/libs/libgio-2.0.so.0* \
     squashfs-root/libs/libgmodule-2.0.so.0* \
     squashfs-root/libs/libgobject-2.0.so.0* \
     squashfs-root/libs/libc++.so.1* \
     squashfs-root/libs/libc++abi.so.1*'

    local pkgbuild_content
    pkgbuild_content=$(<PKGBUILD)
    if [[ "$pkgbuild_content" == *"$broken_rm_block_68"* ]]; then
        warn "Patching known-fragile AUR prepare() step (glib 2.68 bundle version)"
        pkgbuild_content="${pkgbuild_content//"$broken_rm_block_68"/"$fixed_rm_block"}"
        printf '%s\n' "$pkgbuild_content" > PKGBUILD
        ok "Patched AUR prepare() glib strip step to be version-agnostic"
    elif [[ "$pkgbuild_content" == *"$broken_rm_block_82"* ]]; then
        warn "Patching known-fragile AUR prepare() step (glib 2.82 bundle version)"
        pkgbuild_content="${pkgbuild_content//"$broken_rm_block_82"/"$fixed_rm_block"}"
        printf '%s\n' "$pkgbuild_content" > PKGBUILD
        ok "Patched AUR prepare() glib strip step to be version-agnostic"
    else
        log "AUR PKGBUILD prepare() glib strip step does not need defensive patch"
    fi

    # Check if AUR PKGBUILD version matches what we're building
    local aur_version
    aur_version=$(grep '^pkgver=' PKGBUILD | cut -d= -f2)
    if [[ "$aur_version" != "$version" ]]; then
        warn "AUR PKGBUILD is for ${aur_version}, but latest is ${version}"
        warn "Updating pkgver in PKGBUILD to ${version}"
        sed -i "s/^pkgver=.*/pkgver=${version}/" PKGBUILD
        sed -i "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
    fi

    # Verify the zip file is in the build directory
    local zip_name="DaVinci_Resolve_${version}_Linux.zip"
    if [[ ! -f "$zip_name" ]]; then
        err "Zip file not found: ${AUR_DIR}/${zip_name}"
        popd > /dev/null
        return 1
    fi

    # Update sha256sums
    log "Verifying sha256sums..."
    local new_hash
    new_hash=$(sha256sum "$zip_name" | awk '{print $1}')
    local old_hash
    old_hash=$(grep -A1 "^sha256sums=" PKGBUILD | tail -1 | tr -d "' \t" | head -c 64)

    if [[ "$old_hash" != "$new_hash" ]]; then
        log "Updating sha256sum in PKGBUILD..."
        if command -v updpkgsums &>/dev/null; then
            updpkgsums 2>/dev/null
            ok "Updated sha256sums via updpkgsums"
        else
            if [[ -n "$old_hash" && ${#old_hash} -eq 64 ]]; then
                sed -i "s/${old_hash}/${new_hash}/" PKGBUILD
                ok "Updated zip sha256sum: ${new_hash:0:16}..."
            else
                warn "Could not auto-update sha256sum. You may need to run 'updpkgsums' manually."
            fi
        fi
    else
        ok "sha256sums already match"
    fi

    popd > /dev/null
}

# Step 5: Build and install
build_and_install() {
    log "Building package with makepkg in ${AUR_DIR}..."
    pushd "$AUR_DIR" > /dev/null

    # Arch Wiki tip (Decrease installation time): disable zstd compression
    # to avoid spending minutes compressing a ~10GB package that will be installed immediately.
    export PKGEXT='.pkg.tar'

    if [[ "$SKIP_INSTALL" == "true" ]]; then
        yes "" | makepkg -sf --noconfirm || [[ ${PIPESTATUS[1]} -eq 0 ]]
        ok "Package built (not installed due to --skip-install)"
    else
        yes "" | makepkg -sric --noconfirm || [[ ${PIPESTATUS[1]} -eq 0 ]]
        ok "Package built and installed!"
    fi

    popd > /dev/null
}

# Step 6: Warn about runtime support directories Resolve cannot create itself.
check_runtime_dirs() {
    local resolve_dir="/opt/resolve"
    [[ -d "$resolve_dir" ]] || return 0

    # Immersive: Resolve 21.1 startup directory
    # Extras: AI voice models and downloader
    # .license: Studio edition license activation folder
    local needed=("Immersive" "Extras" ".license")
    local broken=() d
    for d in "${needed[@]}"; do
        if [[ ! -d "${resolve_dir}/${d}" || ! -w "${resolve_dir}/${d}" ]]; then
            broken+=("$d")
        fi
    done

    if [[ ${#broken[@]} -eq 0 ]]; then
        ok "Resolve support directories look OK"
        return 0
    fi

    echo ""
    warn "Resolve may fail to launch or activate if support directories are missing or non-writable."
    warn "Directories needing attention:"
    for d in "${broken[@]}"; do
        echo "      ${resolve_dir}/${d}"
    done
    echo ""
    echo "  Fix with:"
    for d in "${broken[@]}"; do
        echo "      sudo mkdir -p '${resolve_dir}/${d}' && sudo chown -R $(id -un):$(id -gn) '${resolve_dir}/${d}'"
    done
    echo ""
    echo "  If it still fails, find any other missing paths with:"
    echo "      strace -f -e trace=mkdir,mkdirat davinci-resolve 2>&1 | grep -E 'EACCES|EPERM'"
    echo ""
}

# --- Main ---
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  DaVinci Resolve Updater for Arch Linux  ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""

    # Install script dependencies if missing
    local missing_tools=()
    for cmd in curl jq git; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_tools+=("$cmd")
        fi
    done
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "Installing missing tools: ${missing_tools[*]}"
        sudo pacman -S --needed --noconfirm "${missing_tools[@]}"
    fi

    # Verify core tools are available (makepkg/pacman should always exist on Arch)
    for cmd in curl jq makepkg pacman git; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Missing dependency: $cmd (could not auto-install)"
            exit 1
        fi
    done

    # Load or create configuration
    load_config

    log "Using AUR directory: ${AUR_DIR}"

    # Get versions
    local installed_version
    installed_version=$(get_installed_version)
    log "Installed version: ${installed_version}"

    log "Checking Blackmagic API for latest version..."
    local latest_info latest_version download_id
    latest_info=$(get_latest_version)
    latest_version=$(echo "$latest_info" | cut -d'|' -f1)
    download_id=$(echo "$latest_info" | cut -d'|' -f2)

    ok "Latest version: ${latest_version}"

    # Compare versions
    if [[ "$installed_version" == "$latest_version" && "$FORCE" != "true" ]]; then
        ok "Already on latest version (${installed_version}). Nothing to do."
        if [[ "$CHECK_ONLY" == "true" ]]; then
            exit 0
        fi
        echo ""
        echo "Use --force to reinstall anyway."
        exit 0
    fi

    if [[ "$installed_version" != "$latest_version" ]]; then
        log "Update available: ${installed_version} → ${latest_version}"
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        warn "Check-only mode. Exiting."
        exit 0
    fi

    # Sync / pull AUR repository
    sync_aur_repo

    # Install dependencies (dynamically resolved from AUR PKGBUILD)
    install_dependencies

    # Download installer
    download_resolve "$download_id" "$latest_version"

    # Setup PKGBUILD
    setup_pkgbuild "$latest_version"

    # Build and install
    build_and_install

    if [[ "$SKIP_INSTALL" != "true" ]]; then
        check_runtime_dirs
    fi

    echo ""
    ok "DaVinci Resolve ${latest_version} installed successfully!"
    log "Run 'davinci-resolve' to launch."
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        log "Note (Wayland): If Resolve fails with a Qt platform error, launch with: QT_QPA_PLATFORM=xcb davinci-resolve"
    fi
}

main "$@"
