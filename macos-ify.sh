#!/usr/bin/env bash
# macos-ify.sh
# -----------------------------------------------------------------------------
# Detects the running Linux distro, installs prerequisites, then installs and
# configures the WhiteSur theme suite (GTK, icons, cursors, wallpapers) plus
# the GNOME Shell extensions needed to mimic a macOS desktop experience.
#
# Supported distros : Fedora, RHEL, Debian, Ubuntu (and derivatives), Arch
# Supported DE      : GNOME (Shell 42+)
#
# Author : BushidoCyb3r
# License: MIT
# -----------------------------------------------------------------------------

set -euo pipefail

# ---------- globals ----------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
WORK_DIR="${HOME}/.cache/macos-ify"
LOG_FILE="${WORK_DIR}/install.log"

# defaults (override via CLI flags)
ACCENT="default"            # default|blue|purple|pink|red|orange|yellow|green|grey
COLOR="dark"                # light|dark
ICON_VARIANT="apple"        # apple|simple|gnome|fedora|ubuntu|...
INSTALL_GDM=false
INSTALL_LIBADWAITA=true
INSTALL_EXTENSIONS=true
INSTALL_WALLPAPERS=true
ASSUME_YES=false
DRY_RUN=false
POST_LOGIN=false            # finalize-only mode: re-apply gsettings after logout/login
GNOME_SKIP_SETTINGS=false   # set true when non-GNOME DE is kept; skips shell/extension gsettings

DISTRO_ID=""
DISTRO_FAMILY=""
PKG_MGR=""
GNOME_VERSION=""

# extensions to install: name|id  (id from extensions.gnome.org)
EXTENSIONS=(
    "user-themes|19"
    "dash-to-dock|307"
    "blur-my-shell|3193"
    "desktop-cube|4648"
)

# ---------- color / logging helpers -----------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'
    C_BLD=$'\e[1m';  C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi

log()   { printf '%s[%s]%s %s\n' "$C_BLU" "$(date +%H:%M:%S)" "$C_RST" "$*" | tee -a "$LOG_FILE"; }
ok()    { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*" | tee -a "$LOG_FILE"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" | tee -a "$LOG_FILE"; }
err()   { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" | tee -a "$LOG_FILE" >&2; }
die()   { err "$*"; exit 1; }
hdr()   { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_RST" | tee -a "$LOG_FILE"; }

run() {
    # wrap a command so we can dry-run / log it
    log "+ $*"
    if [[ "$DRY_RUN" == false ]]; then
        eval "$*"
    fi
}

confirm() {
    [[ "$ASSUME_YES" == true ]] && return 0
    read -r -p "$1 [y/N] " ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ---------- usage -----------------------------------------------------------
usage() {
    cat <<EOF
${C_BLD}${SCRIPT_NAME}${C_RST} - turn a Linux/GNOME desktop into a macOS lookalike

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  -a, --accent COLOR     Theme accent (default|blue|purple|pink|red|orange|
                         yellow|green|grey)            [default: $ACCENT]
  -c, --color VARIANT    light | dark                  [default: $COLOR]
  -i, --icon VARIANT     Activities-icon variant       [default: $ICON_VARIANT]
                         (apple|simple|gnome|fedora|ubuntu|arch|...)
      --gdm              Also theme the GDM login screen (requires sudo)
      --no-libadwaita    Skip the libadwaita override hack (safer, but Settings
                         / Files / Calendar will keep stock GNOME look)
      --no-extensions    Skip GNOME extension install
      --no-wallpapers    Skip WhiteSur wallpaper download
      --post-login       Finalize-only mode: re-applies dock position, button
                         layout, and theme settings AFTER you've logged out and
                         back in. Run this once extensions are loaded.
  -y, --yes              Assume yes to every prompt
  -n, --dry-run          Print what would happen, change nothing
  -h, --help             Show this help and exit

Examples:
  # Sensible default: dark accent, libadwaita override on, no GDM theming
  $SCRIPT_NAME

  # Blue-accented light theme + GDM login + Apple icon, no prompts
  $SCRIPT_NAME -c light -a blue --gdm -y

  # See what it would do without touching anything
  $SCRIPT_NAME -n

  # After log-out/log-in, finalize extension-dependent settings (dock, etc.)
  $SCRIPT_NAME --post-login
EOF
}

# ---------- argument parsing -----------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--accent)        ACCENT="$2"; shift 2 ;;
        -c|--color)         COLOR="$2"; shift 2 ;;
        -i|--icon)          ICON_VARIANT="$2"; shift 2 ;;
        --gdm)              INSTALL_GDM=true; shift ;;
        --no-libadwaita)    INSTALL_LIBADWAITA=false; shift ;;
        --no-extensions)    INSTALL_EXTENSIONS=false; shift ;;
        --no-wallpapers)    INSTALL_WALLPAPERS=false; shift ;;
        --post-login)       POST_LOGIN=true; shift ;;
        -y|--yes)           ASSUME_YES=true; shift ;;
        -n|--dry-run)       DRY_RUN=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) die "Unknown option: $1   (try --help)" ;;
    esac
done

# ---------- preflight -------------------------------------------------------
mkdir -p "$WORK_DIR"
: > "$LOG_FILE"

[[ $EUID -eq 0 ]] && die "Run as your normal user, not root. Sudo is invoked only where required."

command -v sudo >/dev/null 2>&1 || die "sudo is required."
command -v git  >/dev/null 2>&1 || warn "git not found yet — will install with prerequisites."

# ---------- distro detection ------------------------------------------------
detect_distro() {
    hdr "Detecting Linux distribution"
    [[ -r /etc/os-release ]] || die "/etc/os-release not found; unsupported system."
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID,,}"
    local id_like="${ID_LIKE:-}"
    log "ID=$DISTRO_ID  PRETTY_NAME=\"${PRETTY_NAME:-?}\"  ID_LIKE=\"$id_like\""

    case "$DISTRO_ID" in
        fedora|rhel|centos|rocky|almalinux)
            DISTRO_FAMILY="rhel"; PKG_MGR="dnf" ;;
        debian|ubuntu|linuxmint|pop|elementary|zorin|kali|parrot)
            DISTRO_FAMILY="debian"; PKG_MGR="apt" ;;
        arch|manjaro|endeavouros|garuda)
            DISTRO_FAMILY="arch"; PKG_MGR="pacman" ;;
        *)
            # fall back to ID_LIKE
            if   [[ "$id_like" == *fedora*  || "$id_like" == *rhel* ]]; then
                DISTRO_FAMILY="rhel";   PKG_MGR="dnf"
            elif [[ "$id_like" == *debian*  || "$id_like" == *ubuntu* ]]; then
                DISTRO_FAMILY="debian"; PKG_MGR="apt"
            elif [[ "$id_like" == *arch* ]]; then
                DISTRO_FAMILY="arch";   PKG_MGR="pacman"
            else
                die "Unsupported distro: $DISTRO_ID (ID_LIKE=$id_like)"
            fi
            ;;
    esac
    ok  "Distro family: $DISTRO_FAMILY  (package manager: $PKG_MGR)"
}

# ---------- desktop detection -----------------------------------------------
detect_desktop() {
    hdr "Detecting desktop environment"
    local de="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-unknown}}"
    log "XDG_CURRENT_DESKTOP=$de"

    if [[ "${de,,}" != *gnome* ]]; then
        warn "Detected '$de' — not GNOME."
        warn "The full macOS look (top bar, dock, blur) requires GNOME Shell."
        warn "WhiteSur GTK themes, icons, cursors, and wallpapers will still install"
        warn "and work on your current desktop."
        warn ""
        warn "To add GNOME, this script will install gnome-shell and gnome-session."
        warn "Your existing desktop ($de) and display manager are left untouched."
        warn "After rebooting, select 'GNOME' from your login screen's session menu."

        if confirm "Install GNOME Shell alongside $de?"; then
            install_gnome
        else
            warn "Skipping GNOME install. Themes/icons/cursors will still be applied."
            warn "GNOME Shell extensions and shell gsettings will be skipped."
            INSTALL_EXTENSIONS=false
            GNOME_SKIP_SETTINGS=true
        fi
    fi

    if command -v gnome-shell >/dev/null 2>&1; then
        GNOME_VERSION="$(gnome-shell --version | awk '{print $3}')"
        ok "GNOME Shell version: $GNOME_VERSION"
    else
        warn "gnome-shell not found — extension installation will be skipped."
        INSTALL_EXTENSIONS=false
    fi
}

# ---------- GNOME installation (for non-GNOME DEs) --------------------------
install_gnome() {
    hdr "Installing GNOME desktop environment"
    # Install only gnome-shell and gnome-session — not GDM.
    # The existing display manager (e.g. LightDM on Mint) already supports
    # multiple sessions; GNOME will appear in its session chooser at login.
    # GDM is only installed/switched when --gdm is explicitly passed.
    local rhel_pkgs=(gnome-shell gnome-session)
    local deb_pkgs=(gnome-shell gnome-session)
    local arch_pkgs=(gnome-shell gnome-session)

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        warn "────────────────────────────────────────────────────────────"
        warn "  IMPORTANT: apt will prompt you to select a display manager."
        warn "  If asked to choose between lightdm and gdm3, you MUST"
        warn "  select gdm3. Choosing lightdm will prevent GNOME from"
        warn "  loading correctly."
        warn "────────────────────────────────────────────────────────────"
        if ! confirm "Understood — I will select gdm3 if prompted. Continue?"; then
            die "Aborted. Re-run when ready."
        fi
    fi

    case "$DISTRO_FAMILY" in
        rhel)   pkg_install "${rhel_pkgs[@]}" ;;
        debian) pkg_install "${deb_pkgs[@]}" ;;
        arch)   pkg_install "${arch_pkgs[@]}" ;;
    esac

    run "sudo systemctl set-default graphical.target"
    ok "GNOME Shell installed. Select 'GNOME' from your login screen's session menu after rebooting."
}

# ---------- RHEL extra repos (EPEL + CRB/PowerTools) ------------------------
enable_rhel_repos() {
    # Fedora ships a full package set; nothing extra needed.
    [[ "$DISTRO_ID" == "fedora" ]] && return 0

    hdr "Enabling EPEL and CodeReady Builder repositories"

    if ! rpm -q epel-release &>/dev/null; then
        run "sudo dnf install -y epel-release"
    else
        ok "EPEL already installed."
    fi

    # CRB (v9+) / PowerTools (v8) provides sassc and other devel packages.
    local major="${VERSION_ID%%.*}"
    run "sudo dnf install -y dnf-plugins-core"
    if (( major >= 9 )); then
        sudo dnf config-manager --set-enabled crb 2>/dev/null || true
    else
        sudo dnf config-manager --set-enabled powertools 2>/dev/null || true
    fi
}

# ---------- package install (distro abstraction) ----------------------------
pkg_install() {
    local pkgs=("$@")
    case "$DISTRO_FAMILY" in
        rhel)
            run "sudo dnf install -y ${pkgs[*]}" ;;
        debian)
            run "sudo apt-get update -qq"
            run "sudo apt-get install -y ${pkgs[*]}" ;;
        arch)
            run "sudo pacman -Sy --needed --noconfirm ${pkgs[*]}" ;;
    esac
}

install_prereqs() {
    hdr "Installing prerequisites"
    local common=(git curl unzip)
    local rhel=(gnome-tweaks gnome-extensions-app sassc glib2-devel)
    local deb=(gnome-tweaks gnome-shell-extension-manager sassc
               libglib2.0-dev-bin gtk2-engines-murrine gnome-themes-extra)
    local arch=(gnome-tweaks sassc glib2 gtk-engine-murrine gnome-themes-extra)

    case "$DISTRO_FAMILY" in
        rhel)
            enable_rhel_repos
            pkg_install "${common[@]}" "${rhel[@]}" ;;
        debian) pkg_install "${common[@]}" "${deb[@]}" ;;
        arch)   pkg_install "${common[@]}" "${arch[@]}" ;;
    esac
    ok "Prerequisites installed."
}

# ---------- flatpak + flathub ----------------------------------------------
install_flatpak() {
    hdr "Configuring Flatpak / Flathub"
    if ! command -v flatpak >/dev/null 2>&1; then
        case "$DISTRO_FAMILY" in
            rhel)   pkg_install flatpak ;;
            debian) pkg_install flatpak ;;
            arch)   pkg_install flatpak ;;
        esac
    else
        ok "flatpak already installed."
    fi
    run "flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo"
}

# ---------- GNOME extensions ------------------------------------------------
install_extensions() {
    [[ "$INSTALL_EXTENSIONS" == false ]] && { log "Skipping extensions (per flag)."; return; }
    hdr "Installing GNOME Shell extensions"
    command -v gnome-extensions >/dev/null 2>&1 \
        || { warn "gnome-extensions CLI missing; skipping."; return; }

    # ---- Critical: allow extensions that target older GNOME releases to load.
    # Without this, an extension whose metadata.json doesn't list the running
    # shell version is installed but inert. Dash to Dock often lags one GNOME
    # major version behind the latest Fedora ships.
    log "Disabling extension version validation (so borderline-compatible extensions load)..."
    run "gsettings set org.gnome.shell disable-extension-version-validation true"

    # ---- Disable docks that conflict with Dash to Dock.
    # Ubuntu/Pop/Zorin ship 'ubuntu-dock@ubuntu.com' (a Dash to Dock fork).
    # Both enabled simultaneously means neither displays correctly.
    local conflicting_docks=(
        "ubuntu-dock@ubuntu.com"
        "dash-to-panel@jderose9.github.com"     # only matters if user installed it themselves
    )
    for dock in "${conflicting_docks[@]}"; do
        if gnome-extensions list --enabled 2>/dev/null | grep -q "^${dock}$"; then
            warn "Disabling conflicting dock: $dock"
            run "gnome-extensions disable '$dock' || true"
        fi
    done

    local shell_major
    shell_major="$(echo "$GNOME_VERSION" | cut -d. -f1)"

    for entry in "${EXTENSIONS[@]}"; do
        local name="${entry%%|*}"
        local id="${entry##*|}"
        log "→ $name (extensions.gnome.org id=$id)"

        # query info to find a compatible release for this shell version
        local info_url="https://extensions.gnome.org/extension-info/?pk=${id}&shell_version=${shell_major}"
        local info_json="${WORK_DIR}/${name}.json"
        run "curl -fsSL '$info_url' -o '$info_json'" || { warn "  query failed; skipping."; continue; }

        # extract the download URL from JSON without needing jq
        local dl_path
        dl_path="$(grep -o '"download_url": *"[^"]*"' "$info_json" | head -n1 | cut -d'"' -f4 || true)"
        if [[ -z "$dl_path" ]]; then
            # fall back: try without shell_version filter (gets latest, version validation will permit it)
            warn "  no exact-match build for shell $shell_major; querying any version..."
            local fb_url="https://extensions.gnome.org/extension-info/?pk=${id}"
            run "curl -fsSL '$fb_url' -o '$info_json'" || { warn "  fallback query failed; skipping."; continue; }
            dl_path="$(grep -o '"download_url": *"[^"]*"' "$info_json" | head -n1 | cut -d'"' -f4 || true)"
            [[ -z "$dl_path" ]] && { warn "  still no download URL; skipping."; continue; }
        fi

        local zip="${WORK_DIR}/${name}.zip"
        run "curl -fsSL 'https://extensions.gnome.org${dl_path}' -o '$zip'"
        run "gnome-extensions install --force '$zip'"

        # uuid is reported on stdout from gnome-extensions list after install
        local uuid
        uuid="$(unzip -p "$zip" metadata.json 2>/dev/null \
                | grep -o '"uuid": *"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"
        if [[ -n "$uuid" ]]; then
            # Primary path: gnome-extensions enable talks to the running Shell over D-Bus.
            # This works when a GNOME session is live but silently fails otherwise.
            run "gnome-extensions enable '$uuid' 2>/dev/null || true"

            # Belt-and-suspenders: write directly to the enabled-extensions gsettings key.
            # This works even without a running shell and is what GNOME reads on startup,
            # so the extension is guaranteed to be ON after the next shell restart.
            if [[ "$DRY_RUN" == false ]]; then
                local current_list
                current_list="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '@as []')"
                if ! echo "$current_list" | grep -qF "'${uuid}'"; then
                    if [[ "$current_list" == "@as []" || "$current_list" == "[]" ]]; then
                        gsettings set org.gnome.shell enabled-extensions "['${uuid}']"
                    else
                        gsettings set org.gnome.shell enabled-extensions "${current_list%]}, '${uuid}']"
                    fi
                fi
                if gsettings get org.gnome.shell enabled-extensions 2>/dev/null | grep -qF "'${uuid}'"; then
                    ok "  $name enabled in dconf (will activate after reboot)"
                else
                    warn "  $name could not be enabled — run manually: gnome-extensions enable $uuid"
                fi
            fi
        else
            warn "  could not extract UUID from $zip; cannot enable."
        fi
    done

    ok "Extensions installed and enabled in dconf — will activate after reboot."
}

# ---------- WhiteSur GTK theme ---------------------------------------------
install_whitesur_gtk() {
    hdr "Installing WhiteSur GTK theme"
    local repo="${WORK_DIR}/WhiteSur-gtk-theme"
    if [[ -d "$repo/.git" ]]; then
        run "git -C '$repo' pull --ff-only"
    else
        run "git clone --depth=1 https://github.com/vinceliuice/WhiteSur-gtk-theme.git '$repo'"
    fi

    local theme_dest="${HOME}/.local/share/themes"
    run "mkdir -p '$theme_dest'"

    # base GTK install (NOTE: -i is NOT valid here — it's a sub-option of --shell)
    run "'$repo/install.sh' -d '$theme_dest' -t '$ACCENT' -c '$COLOR'"

    # GNOME Shell tweaks: apply Activities-icon variant via --shell sub-namespace.
    # Older WhiteSur releases may not have --shell; tolerate failure.
    if [[ -n "$ICON_VARIANT" && "$ICON_VARIANT" != "standard" ]]; then
        run "'$repo/install.sh' -d '$theme_dest' --shell -i '$ICON_VARIANT' || warn 'Activities-icon variant not applied (older WhiteSur?)'"
    fi

    # libadwaita override (the destructive one)
    if [[ "$INSTALL_LIBADWAITA" == true ]]; then
        warn "Applying libadwaita override — this overwrites ~/.config/gtk-4.0"
        if confirm "Proceed with libadwaita override?"; then
            run "'$repo/install.sh' -d '$theme_dest' -l -t '$ACCENT' -c '$COLOR'"
        else
            log "Skipped libadwaita override."
        fi
    fi

    # GDM theme (sudo). Per upstream docs, GDM-side gnome-shell tweaks (icon, etc.)
    # are also done via --shell on tweaks.sh, not as direct flags.
    if [[ "$INSTALL_GDM" == true ]]; then
        warn "Theming GDM login screen requires sudo and modifies system files."
        if confirm "Proceed with GDM theming?"; then
            run "sudo '$repo/tweaks.sh' -g"
            if [[ -n "$ICON_VARIANT" && "$ICON_VARIANT" != "standard" ]]; then
                run "sudo '$repo/tweaks.sh' -g --shell -i '$ICON_VARIANT' || warn 'GDM icon variant not applied'"
            fi
        else
            log "Skipped GDM theming."
        fi
    fi
    ok "WhiteSur GTK installed."
}

# ---------- WhiteSur icons --------------------------------------------------
install_whitesur_icons() {
    hdr "Installing WhiteSur icon theme"
    local repo="${WORK_DIR}/WhiteSur-icon-theme"
    if [[ -d "$repo/.git" ]]; then
        run "git -C '$repo' pull --ff-only"
    else
        run "git clone --depth=1 https://github.com/vinceliuice/WhiteSur-icon-theme.git '$repo'"
    fi
    run "'$repo/install.sh'"
    ok "WhiteSur icons installed."
}

# ---------- WhiteSur cursors ------------------------------------------------
install_whitesur_cursors() {
    hdr "Installing WhiteSur cursor theme"
    local repo="${WORK_DIR}/WhiteSur-cursors"
    if [[ -d "$repo/.git" ]]; then
        run "git -C '$repo' pull --ff-only"
    else
        run "git clone --depth=1 https://github.com/vinceliuice/WhiteSur-cursors.git '$repo'"
    fi
    run "'$repo/install.sh'"
    ok "WhiteSur cursors installed."
}

# ---------- WhiteSur wallpapers --------------------------------------------
install_whitesur_wallpapers() {
    [[ "$INSTALL_WALLPAPERS" == false ]] && { log "Skipping wallpapers (per flag)."; return; }
    hdr "Installing WhiteSur wallpapers"
    local repo="${WORK_DIR}/WhiteSur-wallpapers"
    if [[ -d "$repo/.git" ]]; then
        run "git -C '$repo' pull --ff-only"
    else
        run "git clone --depth=1 https://github.com/vinceliuice/WhiteSur-wallpapers.git '$repo'"
    fi
    run "'$repo/install-wallpapers.sh'"
    ok "WhiteSur wallpapers installed."
}

# ---------- apply via gsettings + dconf ------------------------------------
apply_settings() {
    hdr "Applying themes via gsettings"
    command -v gsettings >/dev/null 2>&1 || { warn "gsettings missing; skipping."; return; }

    # theme name pattern WhiteSur builds: WhiteSur-{Light|Dark}[-accent]
    local case_color
    case "$COLOR" in
        light) case_color="Light" ;;
        dark)  case_color="Dark" ;;
        *)     case_color="Dark" ;;
    esac
    local theme_name="WhiteSur-${case_color}"
    [[ "$ACCENT" != "default" ]] && theme_name="${theme_name}-${ACCENT}"

    run "gsettings set org.gnome.desktop.interface gtk-theme '$theme_name'"
    run "gsettings set org.gnome.desktop.interface icon-theme 'WhiteSur'"
    run "gsettings set org.gnome.desktop.interface cursor-theme 'WhiteSur-cursors'"
    run "gsettings set org.gnome.desktop.interface color-scheme 'prefer-${COLOR}'"

    # Window-button layout — close/min/max on left, like macOS
    run "gsettings set org.gnome.desktop.wm.preferences button-layout 'close,minimize,maximize:'"

    if [[ "$GNOME_SKIP_SETTINGS" == true ]]; then
        warn "Non-GNOME desktop retained — skipping GNOME Shell extension settings."
        warn "Open your desktop's Appearance/Tweaks tool to select the WhiteSur theme manually."
        ok "Base theme settings applied (gtk-theme, icon-theme, cursor-theme)."
        return
    fi

    # ---- shell theme requires user-themes extension to be LOADED (not just enabled in dconf)
    if gnome-extensions list --enabled 2>/dev/null | grep -q "user-theme@gnome-shell-extensions.gcampax.github.com"; then
        # schema only registered once shell loads the extension; this may still no-op
        # immediately after install but works after logout/login
        if gsettings list-schemas 2>/dev/null | grep -q "org.gnome.shell.extensions.user-theme"; then
            run "gsettings set org.gnome.shell.extensions.user-theme name '$theme_name' || true"
            ok "Shell theme set: $theme_name"
        else
            warn "user-theme schema not registered yet — log out/in then re-run with --post-login"
        fi
    else
        warn "user-themes extension not enabled — Shell theme not applied."
    fi

    # ---- Dash to Dock — bottom, intelligent autohide, smaller icons (macOS-ish)
    if gsettings list-schemas 2>/dev/null | grep -q "org.gnome.shell.extensions.dash-to-dock"; then
        run "gsettings set org.gnome.shell.extensions.dash-to-dock dock-position BOTTOM"
        run "gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed false"
        run "gsettings set org.gnome.shell.extensions.dash-to-dock intellihide true"
        run "gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false"
        run "gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 42"
        run "gsettings set org.gnome.shell.extensions.dash-to-dock transparency-mode 'DYNAMIC'"
        run "gsettings set org.gnome.shell.extensions.dash-to-dock running-indicator-style 'DOTS'"
        run "gsettings set org.gnome.shell.extensions.dash-to-dock click-action 'minimize'"
        run "gsettings set org.gnome.shell.extensions.dash-to-dock show-apps-at-top true"
        ok "Dash to Dock configured."
    else
        warn "dash-to-dock schema not found — settings not applied."
        warn "  This usually means the extension hasn't loaded yet."
        warn "  Log out, log back in, then run: $0 --post-login"
    fi

    # ---- Blur My Shell tweaks for macOS-ish translucency
    if gsettings list-schemas 2>/dev/null | grep -q "org.gnome.shell.extensions.blur-my-shell"; then
        run "gsettings set org.gnome.shell.extensions.blur-my-shell.panel blur true"
        run "gsettings set org.gnome.shell.extensions.blur-my-shell.panel static-blur true"
        ok "Blur My Shell configured."
    fi

    ok "Theme settings applied."
}

# ---------- wallpaper -------------------------------------------------------
set_wallpaper() {
    hdr "Setting desktop wallpaper"

    local choice url filename
    echo ""
    echo "  Choose a wallpaper color:"
    echo "  1) Orange"
    echo "  2) Green"
    echo "  3) Blue"
    echo "  4) Purple"
    echo ""

    if [[ "$ASSUME_YES" == true ]]; then
        choice="1"
    else
        read -r -p "  Enter 1-4 [default: 1]: " choice
        choice="${choice:-1}"
    fi

    case "$choice" in
        2) url="https://miloszfalinski.com/content/files/2025/06/Green-Dark.png";  filename="Green-Dark.png"  ;;
        3) url="https://miloszfalinski.com/content/files/2025/06/Blue-Dark.png";   filename="Blue-Dark.png"   ;;
        4) url="https://miloszfalinski.com/content/files/2025/06/Purple-Dark.png"; filename="Purple-Dark.png" ;;
        *) url="https://miloszfalinski.com/content/files/2025/06/Orange-Dark.png"; filename="Orange-Dark.png" ;;
    esac

    local dest="${HOME}/.local/share/backgrounds/${filename}"

    run "mkdir -p '${HOME}/.local/share/backgrounds'"
    run "curl -fsSL '$url' -o '$dest'"

    local uri="file://${dest}"

    # GNOME (picture-uri-dark covers dark-mode preference)
    run "gsettings set org.gnome.desktop.background picture-uri '$uri' 2>/dev/null || true"
    run "gsettings set org.gnome.desktop.background picture-uri-dark '$uri' 2>/dev/null || true"

    # Cinnamon
    run "gsettings set org.cinnamon.desktop.background picture-uri '$uri' 2>/dev/null || true"

    ok "Wallpaper set: $dest"
}

# ---------- post-login finalize -------------------------------------------
post_login() {
    hdr "Post-login finalize: verifying extensions and re-applying settings"

    command -v gnome-extensions >/dev/null 2>&1 \
        || die "gnome-extensions not found. Are you sure you're on GNOME?"

    local needed=(
        "user-theme@gnome-shell-extensions.gcampax.github.com"
        "dash-to-dock@micxgx.gmail.com"
        "blur-my-shell@aunetx"
    )
    local active=()
    local inactive=()
    for ext in "${needed[@]}"; do
        if gnome-extensions list --enabled 2>/dev/null | grep -q "^${ext}$"; then
            active+=("$ext")
        else
            inactive+=("$ext")
        fi
    done

    if [[ ${#active[@]} -gt 0 ]]; then
        ok "Active extensions:"
        for e in "${active[@]}"; do log "    ✓ $e"; done
    fi

    if [[ ${#inactive[@]} -gt 0 ]]; then
        warn "Inactive extensions (these need attention):"
        for e in "${inactive[@]}"; do log "    ✗ $e"; done
        log ""
        log "Try fixing each one manually:"
        for e in "${inactive[@]}"; do log "    gnome-extensions enable $e"; done
        log ""
        log "If that fails, the extension may not be compatible with your GNOME version."
        log "Check status with: gnome-extensions info <uuid>"
    fi

    apply_settings
    set_wallpaper
    summary
    ok "Post-login finalize done."
}

# ---------- summary --------------------------------------------------------
summary() {
    hdr "Summary"
    cat <<EOF | tee -a "$LOG_FILE"
  Distro family    : $DISTRO_FAMILY ($DISTRO_ID)
  GNOME Shell      : ${GNOME_VERSION:-n/a}
  Theme color      : $COLOR
  Theme accent     : $ACCENT
  Activities icon  : $ICON_VARIANT
  Libadwaita hack  : $INSTALL_LIBADWAITA
  GDM theme        : $INSTALL_GDM
  Extensions       : $INSTALL_EXTENSIONS
  Wallpapers       : $INSTALL_WALLPAPERS
  Log file         : $LOG_FILE

${C_BLD}${C_YLW}WHAT HAPPENS NEXT:${C_RST}
  ${C_BLD}1.${C_RST} The system is rebooting into GNOME.
  ${C_BLD}2.${C_RST} Log in — a one-time autostart job will automatically finalize
     the dock layout, button placement, blur, and shell theme once extensions load.
  ${C_BLD}3.${C_RST} If something still looks wrong after login, open ${C_BLD}gnome-tweaks${C_RST} and
     verify Shell, Application, Cursor, and Icon themes are set to WhiteSur variants.
     Or re-run manually: ${C_BLD}$0 --post-login${C_RST}

${C_YLW}If Dash to Dock isn't visible after login:${C_RST}
  • Verify it's enabled:  gnome-extensions list --enabled | grep dash-to-dock
  • Check for errors:     gnome-extensions info dash-to-dock@micxgx.gmail.com
  • Check version compat: the script disabled extension version validation,
                          but if the extension still won't load, your GNOME
                          version may be too new even for that.

${C_YLW}To uninstall:${C_RST}
  ~/.cache/macos-ify/WhiteSur-gtk-theme/install.sh -d ~/.local/share/themes -r
  ~/.cache/macos-ify/WhiteSur-icon-theme/install.sh -r
  ~/.cache/macos-ify/WhiteSur-cursors/install.sh -r
  sudo ~/.cache/macos-ify/WhiteSur-gtk-theme/tweaks.sh -g -r   # if GDM was themed
EOF
}

# ---------- post-login autostart -------------------------------------------
setup_post_login_autostart() {
    hdr "Scheduling post-login finalization"
    local autostart_dir="${HOME}/.config/autostart"
    local desktop_file="${autostart_dir}/macos-ify-post-login.desktop"
    local wrapper="${WORK_DIR}/post-login-run.sh"
    local script_path
    script_path="$(realpath "$0")"

    log "Autostart entry  : $desktop_file"
    log "Wrapper script   : $wrapper"

    if [[ "$DRY_RUN" == true ]]; then
        log "(dry-run) Would register post-login autostart at $desktop_file"
        return
    fi

    mkdir -p "$autostart_dir"

    # Write a self-deleting wrapper so the autostart only fires once
    cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash
"${script_path}" --post-login --yes
rm -f "${desktop_file}"
WRAPPER
    chmod +x "$wrapper"

    cat > "$desktop_file" <<DESKTOP
[Desktop Entry]
Type=Application
Name=macos-ify post-login finalize
Comment=Applies WhiteSur extension-dependent settings after first GNOME login
Exec=${wrapper}
X-GNOME-Autostart-enabled=true
NoDisplay=true
DESKTOP

    ok "Autostart registered — will run once on next login, then remove itself."
}

# ---------- reboot ----------------------------------------------------------
do_reboot() {
    hdr "Rebooting system"
    log "A reboot is required to activate GNOME Shell extensions and all theme changes."

    if [[ "$DRY_RUN" == true ]]; then
        log "(dry-run) Would reboot now."
        return
    fi

    if [[ "$ASSUME_YES" == true ]]; then
        ok "Rebooting now (--yes flag set)..."
        sleep 2
        sudo reboot
    else
        if confirm "Reboot now to apply all changes?"; then
            ok "Rebooting in 5 seconds... (Ctrl+C to cancel)"
            sleep 5
            sudo reboot
        else
            warn "Reboot skipped. Run 'sudo reboot' when ready."
            warn "After rebooting and logging into GNOME, post-login finalization runs automatically."
        fi
    fi
}

# ---------- main ------------------------------------------------------------
main() {
    if [[ "$POST_LOGIN" == true ]]; then
        hdr "macos-ify post-login finalize (dry-run=$DRY_RUN)"
        detect_distro
        detect_desktop
        post_login
        return
    fi

    hdr "macos-ify starting (dry-run=$DRY_RUN)"
    detect_distro
    detect_desktop
    install_prereqs
    install_flatpak
    install_extensions
    install_whitesur_gtk
    install_whitesur_icons
    install_whitesur_cursors
    install_whitesur_wallpapers
    apply_settings
    set_wallpaper
    if [[ "$GNOME_SKIP_SETTINGS" == false ]]; then
        setup_post_login_autostart
    fi
    summary
    if [[ "$GNOME_SKIP_SETTINGS" == false ]]; then
        do_reboot
    else
        log "No reboot needed — your existing desktop environment is unchanged."
        log "Log out and back in for the WhiteSur theme to take full effect."
    fi
}

main "$@"
