#!/usr/bin/env bash
# macos-ify.sh
# -----------------------------------------------------------------------------
# Detects the running Linux distro, installs prerequisites, then installs and
# configures the WhiteSur theme suite (GTK, icons, cursors, wallpapers) plus
# the GNOME Shell extensions needed to mimic a macOS desktop experience.
#
# v2 additions:
#   * Inter UI font (the single biggest visual tell) — default ON
#   * GNOME Sushi quick-look previews (spacebar in Files)  — default ON
#   * --extras: Logo Menu, Search Light (Spotlight), AppIndicator tray,
#               Just Perfection, Magic Lamp minimize, Rounded Window Corners,
#               plus macOS-style Super+Tab application switching
#   * --keyboard: Toshy keymapper for system-wide Cmd-style shortcuts
#
# Supported distros : Fedora, RHEL, Debian, Ubuntu (and derivatives), Arch
# Supported DE      : GNOME (Shell 42+) for the full experience
#
# Author : BushidoCyb3r
# License: MIT
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# Any unhandled failure prints exactly what died and where, instead of a
# bare exit-code-1. -E (errtrace) makes the trap fire inside functions too.
trap 'printf "\e[31m[FAIL]\e[0m line %s: command failed (exit %s): %s\n" \
      "$LINENO" "$?" "$BASH_COMMAND" | tee -a "${LOG_FILE:-/dev/null}" >&2' ERR

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
INSTALL_FONT=true           # Inter UI font (--no-font to skip)
INSTALL_QUICKLOOK=true      # gnome-sushi spacebar previews (--no-quicklook to skip)
INSTALL_EXTRAS=false        # extra extensions + app-switcher keybinds (--extras)
EXTRAS_ONLY=""              # comma-separated subset of extras (--extras-only a,b)
INSTALL_KEYBOARD=false      # Toshy Cmd-style keyboard remapping (--keyboard)
WALLPAPER_CHOICE=""         # 1-4; set via --wallpaper to skip the prompt
NO_REBOOT=false             # --no-reboot: skip the reboot step (GUI handles it)
LAUNCH_GUI=false            # --gui: hand off to the GTK front-end
ASSUME_YES=false
DRY_RUN=false
POST_LOGIN=false            # finalize-only mode: re-apply gsettings after logout/login
GNOME_SKIP_SETTINGS=false   # set true when non-GNOME DE is kept; skips shell/extension gsettings
FONT_APPLIED=false          # set true once Inter is confirmed on disk

DISTRO_ID=""
DISTRO_FAMILY=""
PKG_MGR=""
GNOME_VERSION=""

# -----------------------------------------------------------------------------
# Extensions, tiered. Format: "name|id|min_shell"
#   id        = extension ID from extensions.gnome.org (/extension/<ID>/...)
#   min_shell = minimum GNOME Shell major version (0 = no gate)
#
# CORE = the boring, reliable default. EXTRA = the full macOS treatment,
# opt-in via --extras, because every extension added is another thing that
# breaks on the next GNOME major release.
# -----------------------------------------------------------------------------
EXTENSIONS_CORE=(
    "user-themes|19|0"
    "dash-to-dock|307|0"
    "blur-my-shell|3193|0"
    "desktop-cube|4648|0"
)

EXTENSIONS_EXTRA=(
    "logo-menu|4451|0"                      # Apple-style menu, top-left
    "search-light|5489|0"                   # Spotlight-style floating search
    "appindicator-support|615|0"            # menu-bar style tray icons
    "just-perfection|3843|0"                # panel/clock/UI tweaks
    "compiz-alike-magic-lamp-effect|3740|0" # genie minimize animation
    "rounded-window-corners-reborn|7048|46" # upstream supports GNOME 46+
)

# UUIDs of CORE extensions, used by --post-login verification.
CORE_UUIDS=(
    "user-theme@gnome-shell-extensions.gcampax.github.com"
    "dash-to-dock@micxgx.gmail.com"
    "blur-my-shell@aunetx"
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

# True if a given extra is wanted: either --extras (all of them) or the name
# appears in the --extras-only comma list. 'app-switcher' is a pseudo-extra
# covering only the Super+Tab keybinding changes.
extras_wanted() {
    [[ "$INSTALL_EXTRAS" == true ]] && return 0
    [[ -n "$EXTRAS_ONLY" ]] && [[ ",${EXTRAS_ONLY}," == *",$1,"* ]]
}

any_extras() {
    [[ "$INSTALL_EXTRAS" == true || -n "$EXTRAS_ONLY" ]]
}

# ---------- usage -----------------------------------------------------------
usage() {
    cat <<EOF
${C_BLD}${SCRIPT_NAME}${C_RST} - turn a Linux/GNOME desktop into a macOS lookalike

Usage: $SCRIPT_NAME [OPTIONS]

Theme options:
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

Behavior options (new):
      --extras           Install the extended extension set:
                           Logo Menu (Apple-style menu, top-left)
                           Search Light (Spotlight-style search popup)
                           AppIndicator (menu-bar tray icons)
                           Just Perfection (panel/UI tweaks)
                           Magic Lamp (genie minimize effect)
                           Rounded Window Corners (GNOME 46+ only)
                         Also sets macOS-style application switching:
                           Super+Tab = switch apps, Super+\` = switch windows
      --extras-only LIST Install only the named extras (comma-separated):
                           logo-menu,search-light,appindicator-support,
                           just-perfection,compiz-alike-magic-lamp-effect,
                           rounded-window-corners-reborn,app-switcher
                         ('app-switcher' = the Super+Tab keybinds only)
      --keyboard         Install Toshy (github.com/RedBearAK/toshy) for
                         system-wide Cmd-style shortcuts (Cmd+C/V/W/T/Q...).
                         Runs Toshy's own installer; adds systemd user
                         services and udev rules. The deepest change this
                         script can make — read the prompt before agreeing.
      --no-font          Skip installing/applying the Inter UI font
      --no-quicklook     Skip GNOME Sushi (spacebar file previews in Files)

Run modes:
      --gui              Launch the GTK front-end (macos-ify-gui.py) instead
                         of the terminal flow. Installs python3-gobject /
                         python3-gi if missing.
      --wallpaper N      Wallpaper choice 1-4 (Orange/Green/Blue/Purple);
                         skips the interactive prompt
      --no-reboot        Skip the reboot at the end (the GUI uses this and
                         offers its own reboot button)
      --post-login       Finalize-only mode: re-applies dock position, button
                         layout, and theme settings AFTER you've logged out and
                         back in. Run this once extensions are loaded.
  -y, --yes              Assume yes to every prompt
  -n, --dry-run          Print what would happen, change nothing
  -h, --help             Show this help and exit

Examples:
  # Sensible default: dark theme, Inter font, quick-look, core extensions
  $SCRIPT_NAME

  # The full macOS treatment, including Spotlight, Apple menu, genie effect
  $SCRIPT_NAME --extras

  # Everything, including Cmd-style keyboard shortcuts, no prompts
  $SCRIPT_NAME --extras --keyboard -y

  # Blue-accented light theme + GDM login + Apple icon, no prompts
  $SCRIPT_NAME -c light -a blue --gdm -y

  # See what it would do without touching anything
  $SCRIPT_NAME --extras -n

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
        --extras)           INSTALL_EXTRAS=true; shift ;;
        --extras-only)      EXTRAS_ONLY="$2"; shift 2 ;;
        --keyboard)         INSTALL_KEYBOARD=true; shift ;;
        --wallpaper)        WALLPAPER_CHOICE="$2"; shift 2 ;;
        --no-reboot)        NO_REBOOT=true; shift ;;
        --gui)              LAUNCH_GUI=true; shift ;;
        --no-font)          INSTALL_FONT=false; shift ;;
        --no-quicklook)     INSTALL_QUICKLOOK=false; shift ;;
        --post-login)       POST_LOGIN=true; shift ;;
        -y|--yes)           ASSUME_YES=true; shift ;;
        -n|--dry-run)       DRY_RUN=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) die "Unknown option: $1   (try --help)" ;;
    esac
done

# ---------- preflight -------------------------------------------------------
mkdir -p "$WORK_DIR"
# Rotate rather than truncate: a failed run's log must survive the next run.
[[ -f "$LOG_FILE" ]] && mv -f "$LOG_FILE" "${LOG_FILE}.prev"
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

# -----------------------------------------------------------------------------
# Per-distro package name resolution.
#
# The same software ships under different names per family. Verified against
# Repology / distro package indexes (June 2026):
#
#   logical name   rhel/fedora (dnf)    debian/ubuntu (apt)   arch (pacman)
#   ------------   ------------------   -------------------   -------------
#   sushi          sushi                gnome-sushi           sushi
#   inter-font     rsms-inter-fonts     fonts-inter           inter-font
#   imagemagick    ImageMagick          imagemagick           imagemagick
#                  ^ dnf names are case-sensitive; Fedora capitalizes this one.
#
# Anything not listed here resolves to itself (name identical across families).
# -----------------------------------------------------------------------------
resolve_pkg() {
    local logical="$1"
    case "${logical}:${DISTRO_FAMILY}" in
        sushi:rhel)          echo "sushi" ;;
        sushi:debian)        echo "gnome-sushi" ;;
        sushi:arch)          echo "sushi" ;;
        inter-font:rhel)     echo "rsms-inter-fonts" ;;
        inter-font:debian)   echo "fonts-inter" ;;
        inter-font:arch)     echo "inter-font" ;;
        imagemagick:rhel)    echo "ImageMagick" ;;
        imagemagick:debian)  echo "imagemagick" ;;
        imagemagick:arch)    echo "imagemagick" ;;
        pygobject:rhel)      echo "python3-gobject gtk3" ;;
        pygobject:debian)    echo "python3-gi gir1.2-gtk-3.0" ;;
        pygobject:arch)      echo "python-gobject gtk3" ;;
        *)                   echo "$logical" ;;
    esac
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

    pkg_install gnome-shell gnome-session

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

# Best-effort variant. ALWAYS returns 0 so it can be called with or without a
# guard without tripping the ERR trap — the previous design returned non-zero,
# which trips `set -e`/trap at any unguarded call site (a footgun that already
# bit us once). Instead it reports the outcome via PKG_OPTIONAL_OK: "true" if
# the package installed, "false" if it failed. Callers that care read that;
# callers that don't can ignore it safely.
PKG_OPTIONAL_OK="true"
pkg_install_optional() {
    local pkgs=("$@") rc=0
    case "$DISTRO_FAMILY" in
        rhel)
            run "sudo dnf install -y ${pkgs[*]}" || rc=$? ;;
        debian)
            run "sudo apt-get update -qq" || true
            run "sudo apt-get install -y ${pkgs[*]}" || rc=$? ;;
        arch)
            run "sudo pacman -Sy --needed --noconfirm ${pkgs[*]}" || rc=$? ;;
    esac
    if (( rc == 0 )); then PKG_OPTIONAL_OK="true"; else PKG_OPTIONAL_OK="false"; fi
    return 0
}

install_prereqs() {
    hdr "Installing prerequisites"

    # REQUIRED: the run genuinely cannot proceed without these. sassc compiles
    # the WhiteSur theme; git/curl/unzip fetch and unpack everything.
    local req_common=(git curl unzip)
    local req_rhel=(sassc glib2-devel)
    local req_deb=(sassc libglib2.0-dev-bin)
    local req_arch=(sassc glib2)

    # OPTIONAL: nice-to-haves that are absent or renamed on some releases.
    #   * RHEL 10 REMOVED gnome-tweaks (folded into GNOME Settings) and does
    #     not ship the GTK2 murrine engine or gnome-themes-extra in base repos.
    #   * The murrine engine only matters at runtime for GTK2 apps, which are
    #     near-extinct on a GNOME 49 desktop; WhiteSur compiles fine without it.
    #   Installed one-at-a-time so a single missing name can't fail the batch.
    local opt_rhel=(gnome-tweaks gnome-extensions-app gtk-murrine-engine gnome-themes-extra)
    local opt_deb=(gnome-tweaks gnome-shell-extension-manager gtk2-engines-murrine gnome-themes-extra)
    local opt_arch=(gnome-tweaks gtk-engine-murrine gnome-themes-extra)

    local required=() optional=()
    case "$DISTRO_FAMILY" in
        rhel)
            enable_rhel_repos
            required=("${req_common[@]}" "${req_rhel[@]}"); optional=("${opt_rhel[@]}") ;;
        debian)
            required=("${req_common[@]}" "${req_deb[@]}");  optional=("${opt_deb[@]}") ;;
        arch)
            required=("${req_common[@]}" "${req_arch[@]}"); optional=("${opt_arch[@]}") ;;
    esac

    # Hard requirement: if this fails, stop with a clear message (the ERR trap
    # would already name the command, but be explicit about why it's fatal).
    pkg_install "${required[@]}" \
        || die "A required package failed to install. See the FAIL line above."

    # Best-effort, individually, so one bad name is just a warning.
    local pkg
    for pkg in "${optional[@]}"; do
        pkg_install_optional "$pkg"
        [[ "$PKG_OPTIONAL_OK" == "true" ]] || \
            warn "Optional package not available on this release: $pkg (continuing)"
    done

    # gnome-tweaks is the one optional people actually miss. On RHEL 10 it's
    # gone from base; point the user at where its settings moved.
    if ! command -v gnome-tweaks >/dev/null 2>&1 && [[ "$DRY_RUN" == false ]]; then
        warn "gnome-tweaks is not installed (removed from RHEL 10 base repos)."
        warn "  Its options now live in GNOME Settings, or install via Flatpak:"
        warn "  flatpak install -y flathub org.gnome.tweaks"
    fi

    # Search Light's blurred-background feature needs imagemagick.
    if extras_wanted "search-light"; then
        pkg_install_optional "$(resolve_pkg imagemagick)"
        [[ "$PKG_OPTIONAL_OK" == "true" ]] || \
            warn "imagemagick unavailable; Search Light blur may be limited."
    fi

    ok "Prerequisites installed."
}

# ---------- flatpak + flathub ----------------------------------------------
install_flatpak() {
    hdr "Configuring Flatpak / Flathub"
    if ! command -v flatpak >/dev/null 2>&1; then
        pkg_install flatpak
    else
        ok "flatpak already installed."
    fi
    run "flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo || true"
    ok "Flathub remote configured (best-effort)."
}

# ---------- Inter UI font ----------------------------------------------------
# The system font is the loudest "this is Linux" tell after the theme itself.
# Inter is the defensible choice for a public repo: SIL OFL licensed and
# packaged in every supported family (SF Pro is Apple-EULA gray territory).
#
# Verified package names: rsms-inter-fonts (Fedora/EPEL), fonts-inter
# (Debian/Ubuntu), inter-font (Arch). If the package is unavailable (e.g. a
# minimal RHEL without the EPEL build), fall back to the upstream GitHub
# release, installed per-user under ~/.local/share/fonts.
install_font() {
    [[ "$INSTALL_FONT" == false ]] && { log "Skipping Inter font (per flag)."; return; }
    hdr "Installing Inter UI font"

    if fc-list 2>/dev/null | grep -qi "Inter[-: ]"; then
        ok "Inter already present on system."
        FONT_APPLIED=true
        return
    fi

    pkg_install_optional "$(resolve_pkg inter-font)"

    if [[ "$DRY_RUN" == true ]] || fc-list 2>/dev/null | grep -qi "Inter[-: ]"; then
        ok "Inter font installed via package manager."
        FONT_APPLIED=true
        return
    fi

    # Package path failed — fall back to the upstream release. Try the API
    # first (always current), but the GitHub API is rate-limited per IP and
    # can 403; if that happens, fall back to a known direct release URL that
    # needs no API call at all. -A sets a User-Agent (GitHub requires one).
    warn "Distro package unavailable; falling back to upstream GitHub release."
    local api="https://api.github.com/repos/rsms/inter/releases/latest"
    local meta="${WORK_DIR}/inter-release.json"
    local dl_url=""
    if curl -fsSL -A "macos-ify-installer" "$api" -o "$meta" 2>/dev/null; then
        dl_url="$(grep -o '"browser_download_url": *"[^"]*Inter-[0-9.]*\.zip"' "$meta" \
                  | head -n1 | cut -d'"' -f4 || true)"
    fi
    if [[ -z "$dl_url" ]]; then
        # API unavailable/rate-limited — use a pinned known-good release.
        warn "GitHub API unavailable (rate limit?); using pinned Inter release."
        dl_url="https://github.com/rsms/inter/releases/download/v4.0/Inter-4.0.zip"
    fi

    local zip="${WORK_DIR}/inter.zip"
    local font_dir="${HOME}/.local/share/fonts/inter"
    if ! run "curl -fsSL '$dl_url' -o '$zip'"; then
        warn "Could not download Inter from $dl_url — skipping font."
        return
    fi
    run "mkdir -p '$font_dir'"
    # Upstream zips ship OTF + variable TTF in subfolders; flatten what we need.
    run "unzip -o -j '$zip' '*.otf' -d '$font_dir' || unzip -o -j '$zip' '*.ttf' -d '$font_dir' || true"
    run "fc-cache -f '$font_dir'"

    if [[ "$DRY_RUN" == true ]] || fc-list 2>/dev/null | grep -qi "Inter[-: ]"; then
        ok "Inter font installed to $font_dir"
        FONT_APPLIED=true
    else
        warn "Inter still not visible to fontconfig — font will not be applied."
    fi
}

# ---------- GNOME Sushi (Quick Look) -----------------------------------------
# Spacebar previews in GNOME Files, exactly like Finder's Quick Look.
# One package; the cheapest behavioral win in this entire script.
# Verified names: sushi (Fedora, Arch), gnome-sushi (Debian/Ubuntu).
install_quicklook() {
    [[ "$INSTALL_QUICKLOOK" == false ]] && { log "Skipping Sushi quick-look (per flag)."; return; }
    if [[ "$GNOME_SKIP_SETTINGS" == true ]]; then
        log "Skipping Sushi — it only integrates with GNOME Files."
        return
    fi
    hdr "Installing GNOME Sushi (spacebar Quick Look in Files)"
    pkg_install_optional "$(resolve_pkg sushi)"
    if [[ "$PKG_OPTIONAL_OK" == "true" ]]; then
        ok "Sushi installed. Select a file in Files and press Space."
    else
        warn "Sushi unavailable on this release; spacebar Quick Look skipped."
    fi
}

# ---------- Toshy keyboard remapping (opt-in) --------------------------------
# Toshy (github.com/RedBearAK/toshy) makes Cmd-style shortcuts work
# system-wide: Cmd+C/V/X/W/T/Q, Cmd+Tab app switching, terminal-aware
# Ctrl handling, per-app keymaps. Chosen over kinto.sh because Toshy
# supports Wayland (kinto is X11-centric and stale).
#
# This is NOT a theme tweak. Toshy's installer adds:
#   * systemd user services (starts at login)
#   * udev rules + membership in the input group
#   * a Python virtualenv under ~/.config/toshy
# It is the deepest change this script can make, which is why it is opt-in
# (--keyboard), prompts even with a clear conscience, and runs Toshy's own
# vetted installer rather than reimplementing it.
install_keyboard() {
    [[ "$INSTALL_KEYBOARD" == false ]] && return
    hdr "Installing Toshy (Cmd-style keyboard shortcuts)"

    warn "Toshy installs systemd user services, udev rules, and adds your user"
    warn "to the 'input' group so it can read keyboard events. It is removable"
    warn "(re-run its setup with 'uninstall'), but understand what it does:"
    warn "  https://github.com/RedBearAK/toshy"
    if ! confirm "Proceed with Toshy install?"; then
        log "Skipped Toshy."
        return
    fi

    local repo="${WORK_DIR}/toshy"
    if [[ -d "$repo/.git" ]]; then
        run "git -C '$repo' pull --ff-only"
    else
        run "git clone --depth=1 https://github.com/RedBearAK/toshy.git '$repo'"
    fi

    # Toshy's installer (setup_toshy.py) is interactive — it asks several
    # questions via input(). That's fine in a real terminal AND in the GUI:
    # the GUI's console detects when the installer blocks on a prompt and
    # surfaces an input bar that writes the answer back to the pty, so we run
    # it inline in both modes.
    run "cd '$repo' && ./setup_toshy.py install" \
        || warn "Toshy setup reported a failure — see its output above."

    ok "Toshy installed. Log out/in (or reboot) for services to start."
    log "Tray icon: 'Toshy' — preferences, keyboard-type override, on/off toggle."
}

# ---------- GNOME extensions ------------------------------------------------
install_one_extension() {
    # $1 = name, $2 = extensions.gnome.org ID, $3 = minimum shell major (0 = none)
    local name="$1" id="$2" min_shell="$3"
    local shell_major
    shell_major="$(echo "$GNOME_VERSION" | cut -d. -f1)"

    if (( min_shell > 0 )) && (( shell_major < min_shell )); then
        warn "→ $name requires GNOME ${min_shell}+, you have ${shell_major}; skipping."
        return
    fi

    log "→ $name (extensions.gnome.org id=$id)"

    # query info to find a compatible release for this shell version
    local info_url="https://extensions.gnome.org/extension-info/?pk=${id}&shell_version=${shell_major}"
    local info_json="${WORK_DIR}/${name}.json"
    run "curl -fsSL '$info_url' -o '$info_json'" || { warn "  query failed; skipping."; return; }

    # extract the download URL from JSON without needing jq
    local dl_path
    dl_path="$(grep -o '"download_url": *"[^"]*"' "$info_json" | head -n1 | cut -d'"' -f4 || true)"
    if [[ -z "$dl_path" ]]; then
        # fall back: try without shell_version filter (gets latest, version validation will permit it)
        warn "  no exact-match build for shell $shell_major; querying any version..."
        local fb_url="https://extensions.gnome.org/extension-info/?pk=${id}"
        run "curl -fsSL '$fb_url' -o '$info_json'" || { warn "  fallback query failed; skipping."; return; }
        dl_path="$(grep -o '"download_url": *"[^"]*"' "$info_json" | head -n1 | cut -d'"' -f4 || true)"
        [[ -z "$dl_path" ]] && { warn "  still no download URL; skipping."; return; }
    fi

    local zip="${WORK_DIR}/${name}.zip"
    run "curl -fsSL 'https://extensions.gnome.org${dl_path}' -o '$zip'"
    run "gnome-extensions install --force '$zip'"

    # uuid lives inside the zip's metadata.json
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
}

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
    run "gsettings set org.gnome.shell disable-extension-version-validation true || true"

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

    local entry name id min_shell
    for entry in "${EXTENSIONS_CORE[@]}"; do
        IFS='|' read -r name id min_shell <<< "$entry"
        install_one_extension "$name" "$id" "$min_shell"
    done

    if any_extras; then
        log ""
        log "Installing extras extension set..."
        for entry in "${EXTENSIONS_EXTRA[@]}"; do
            IFS='|' read -r name id min_shell <<< "$entry"
            if extras_wanted "$name"; then
                install_one_extension "$name" "$id" "$min_shell"
            else
                log "→ $name not selected; skipping."
            fi
        done
    fi

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

    # ---- Inter UI font. Only when confirmed on disk: setting font-name to a
    # font fontconfig can't resolve silently falls back to an uglier default.
    if [[ "$FONT_APPLIED" == true ]]; then
        run "gsettings set org.gnome.desktop.interface font-name 'Inter 11' 2>/dev/null || true"
        run "gsettings set org.gnome.desktop.interface document-font-name 'Inter 11' 2>/dev/null || true"
        run "gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Inter Bold 11' 2>/dev/null || true"
        # Cinnamon equivalent, harmless no-op elsewhere
        run "gsettings set org.cinnamon.desktop.interface font-name 'Inter 11' 2>/dev/null || true"
        ok "UI font set to Inter."
    fi

    if [[ "$GNOME_SKIP_SETTINGS" == true ]]; then
        warn "Non-GNOME desktop retained — skipping GNOME Shell extension settings."
        warn "Open your desktop's Appearance/Tweaks tool to select the WhiteSur theme manually."
        ok "Base theme settings applied (gtk-theme, icon-theme, cursor-theme)."
        return
    fi

    # ---- macOS-style application switching (part of --extras).
    # macOS Cmd+Tab cycles APPLICATIONS; Cmd+` cycles windows of the current
    # app. Stock GNOME already binds switch-applications, but Ubuntu remaps
    # Alt+Tab to per-window switching — enforce the app-based behavior on
    # both Super and Alt so it holds across all supported distros.
    if extras_wanted "app-switcher"; then
        run "gsettings set org.gnome.desktop.wm.keybindings switch-applications \"['<Super>Tab', '<Alt>Tab']\""
        run "gsettings set org.gnome.desktop.wm.keybindings switch-applications-backward \"['<Shift><Super>Tab', '<Shift><Alt>Tab']\""
        run "gsettings set org.gnome.desktop.wm.keybindings switch-group \"['<Super>Above_Tab', '<Alt>Above_Tab']\""
        run "gsettings set org.gnome.desktop.wm.keybindings switch-group-backward \"['<Shift><Super>Above_Tab', '<Shift><Alt>Above_Tab']\""
        run "gsettings set org.gnome.desktop.wm.keybindings switch-windows \"[]\""
        run "gsettings set org.gnome.desktop.wm.keybindings switch-windows-backward \"[]\""
        ok "App-based switching: Super+Tab = apps, Super+\` = windows of app."
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

    # ---- Extras: deliberately NOT writing dconf keys for Logo Menu, Search
    # Light, or Just Perfection. Their schema key names/values were not
    # verifiable against published schemas at the time of writing, and a
    # wrong key name aborts under `set -e` or silently misconfigures.
    # Their upstream defaults are sane; preferences live in the Extensions
    # app. Search Light's default hotkey is Ctrl+Super+Space.
    if any_extras && [[ "$GNOME_SKIP_SETTINGS" == false ]]; then
        log "Extras installed with upstream defaults — fine-tune in the Extensions app."
    fi

    ok "Theme settings applied."
}

# ---------- wallpaper -------------------------------------------------------
set_wallpaper() {
    hdr "Setting desktop wallpaper"

    local choice url filename
    if [[ "$WALLPAPER_CHOICE" =~ ^[1-4]$ ]]; then
        choice="$WALLPAPER_CHOICE"
        log "Wallpaper preselected via --wallpaper: $choice"
    elif [[ "$ASSUME_YES" == true ]]; then
        choice="1"
    else
        echo ""
        echo "  Choose a wallpaper color:"
        echo "  1) Orange"
        echo "  2) Green"
        echo "  3) Blue"
        echo "  4) Purple"
        echo ""
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
    if ! run "curl -fsSL '$url' -o '$dest'"; then
        warn "Wallpaper download failed: $url"
        warn "The hosting URL may be dead — install continues without it."
        warn "WhiteSur wallpaper pack (if installed) is in ~/.local/share/backgrounds."
        return 0
    fi

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

    local active=()
    local inactive=()
    local ext
    for ext in "${CORE_UUIDS[@]}"; do
        if gnome-extensions list --enabled 2>/dev/null | grep -q "^${ext}$"; then
            active+=("$ext")
        else
            inactive+=("$ext")
        fi
    done

    # Extras are best-effort: only report on ones that are actually installed,
    # since post-login runs without knowledge of the original flags.
    local installed enabled
    installed="$(gnome-extensions list 2>/dev/null || true)"
    enabled="$(gnome-extensions list --enabled 2>/dev/null || true)"
    local extra_uuids=(
        "logomenu@aryan_k"
        "search-light@icedman.github.com"
        "appindicatorsupport@rgcjonas.gmail.com"
        "just-perfection-desktop@just-perfection"
        "compiz-alike-magic-lamp-effect@hermes83.github.com"
        "rounded-window-corners@fxgn"
    )
    for ext in "${extra_uuids[@]}"; do
        if echo "$installed" | grep -q "^${ext}$"; then
            if echo "$enabled" | grep -q "^${ext}$"; then
                active+=("$ext")
            else
                inactive+=("$ext")
            fi
        fi
    done

    if [[ ${#active[@]} -gt 0 ]]; then
        ok "Active extensions:"
        local e
        for e in "${active[@]}"; do log "    ✓ $e"; done
    fi

    if [[ ${#inactive[@]} -gt 0 ]]; then
        warn "Inactive extensions (these need attention):"
        local e
        for e in "${inactive[@]}"; do log "    ✗ $e"; done
        log ""
        log "Try fixing each one manually:"
        for e in "${inactive[@]}"; do log "    gnome-extensions enable $e"; done
        log ""
        log "If that fails, the extension may not be compatible with your GNOME version."
        log "Check status with: gnome-extensions info <uuid>"
    fi

    # Re-detect the font so the gsettings font keys apply on post-login too.
    if [[ "$INSTALL_FONT" == true ]] && fc-list 2>/dev/null | grep -qi "Inter[-: ]"; then
        FONT_APPLIED=true
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
  Extensions       : $INSTALL_EXTENSIONS (extras: $INSTALL_EXTRAS)
  Inter UI font    : $INSTALL_FONT (applied: $FONT_APPLIED)
  Quick Look       : $INSTALL_QUICKLOOK
  Toshy keyboard   : $INSTALL_KEYBOARD
  Wallpapers       : $INSTALL_WALLPAPERS
  Log file         : $LOG_FILE

${C_BLD}${C_YLW}WHAT HAPPENS NEXT:${C_RST}
  ${C_BLD}1.${C_RST} The system is rebooting into GNOME.
  ${C_BLD}2.${C_RST} Log in — a one-time autostart job will automatically finalize
     the dock layout, button placement, blur, and shell theme once extensions load.
  ${C_BLD}3.${C_RST} If something still looks wrong after login, open ${C_BLD}gnome-tweaks${C_RST} and
     verify Shell, Application, Cursor, and Icon themes are set to WhiteSur variants.
     Or re-run manually: ${C_BLD}$0 --post-login${C_RST}

${C_YLW}If you installed --extras:${C_RST}
  • Spotlight search : Search Light, default hotkey Ctrl+Super+Space
  • Apple menu       : Logo Menu replaces Activities, top-left
  • App switching    : Super+Tab cycles apps, Super+\` cycles app windows
  • Fine-tune all of them in the Extensions app (preferences per extension)

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
  gsettings reset org.gnome.desktop.interface font-name        # if font applied
  gsettings reset-recursively org.gnome.desktop.wm.keybindings # if extras applied
  ~/.cache/macos-ify/toshy/setup_toshy.py uninstall            # if Toshy installed
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

    # Carry behavior flags into the post-login run so font/extras settings
    # re-apply consistently. (Extensions are already installed by then.)
    local fwd_flags="--post-login --yes"
    [[ "$INSTALL_EXTRAS" == true ]] && fwd_flags+=" --extras"
    [[ -n "$EXTRAS_ONLY" ]] && fwd_flags+=" --extras-only ${EXTRAS_ONLY}"
    [[ "$INSTALL_FONT" == false ]] && fwd_flags+=" --no-font"
    [[ "$WALLPAPER_CHOICE" =~ ^[1-4]$ ]] && fwd_flags+=" --wallpaper ${WALLPAPER_CHOICE}"

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
"${script_path}" ${fwd_flags}
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
    if [[ "$NO_REBOOT" == true ]]; then
        hdr "Reboot skipped (--no-reboot)"
        log "Reboot when ready: sudo reboot"
        log "Post-login finalization will run automatically on next GNOME login."
        return
    fi
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

# ---------- GUI launcher -----------------------------------------------------
# The GTK front-end is EMBEDDED at the bottom of this file, inside an inert
# `: <<'____GUI_PAYLOAD____'` heredoc placed after the final `exit`. Bash
# never executes it; --gui extracts it to the cache dir and runs it. The GUI
# collects every choice up front (theme, wallpaper previews, extras as toggle
# buttons), then re-invokes THIS script — path passed via $MACOSIFY_SCRIPT —
# with the matching flags plus --yes --no-reboot, streaming output live.
launch_gui() {
    hdr "Launching GUI"
    local self gui_py
    self="$(realpath "$0")"
    gui_py="${WORK_DIR}/macos-ify-gui.py"

    if ! python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
        warn "PyGObject / GTK3 bindings not found — installing."
        # resolve_pkg returns two names here; deliberate word splitting.
        # shellcheck disable=SC2046
        pkg_install $(resolve_pkg pygobject)
    fi

    # Extract the payload: everything between the heredoc start marker and
    # the terminating marker line, exclusive. Re-extracted on every launch so
    # the GUI is always exactly in sync with this script version.
    sed -n "/^: <<'____GUI_PAYLOAD____'$/,/^____GUI_PAYLOAD____$/p" "$self" \
        | sed '1d;$d' > "$gui_py"

    [[ -s "$gui_py" ]] || die "Could not extract embedded GUI payload from $self"

    log "Starting GUI (extracted to $gui_py)"
    MACOSIFY_SCRIPT="$self" exec python3 "$gui_py"
}

# ---------- main ------------------------------------------------------------
main() {
    if [[ "$LAUNCH_GUI" == true ]]; then
        detect_distro
        launch_gui
        # exec replaces the process; nothing runs past here.
    fi

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
    install_font
    install_quicklook
    install_extensions
    install_whitesur_gtk
    install_whitesur_icons
    install_whitesur_cursors
    install_whitesur_wallpapers
    install_keyboard
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
exit $?

# =============================================================================
# EMBEDDED GTK GUI — extracted and run by --gui. Never executed by bash:
# the `exit` above is unconditional and `:` ignores heredoc input anyway.
# Do not place a line consisting solely of the marker inside the Python.
# =============================================================================
: <<'____GUI_PAYLOAD____'
#!/usr/bin/env python3
"""
macos-ify-gui.py — GTK3 front-end for macos-ify.sh

Three pages (GtkStack):
  1. Setup    — logo header, theme options, extras as toggle buttons,
                wallpaper chooser with live image previews
  2. Install  — streams macos-ify.sh output line-by-line
  3. Done     — result + reboot button

The GUI never reimplements install logic. It collects choices, primes a sudo
timestamp (the script calls sudo internally and has no terminal to ask on),
then runs:  macos-ify.sh <flags> --yes --no-reboot --wallpaper N

Requires: python3-gobject + GTK3 (the .sh --gui launcher installs these).
Author : BushidoCyb3r   License: MIT
"""

import fcntl
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import termios
import threading
import urllib.request

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib, GdkPixbuf, Pango  # noqa: E402

SCRIPT_SH = os.environ.get("MACOSIFY_SCRIPT", "")
SCRIPT_DIR = os.path.dirname(SCRIPT_SH) if SCRIPT_SH else os.path.dirname(os.path.realpath(__file__))
if not SCRIPT_SH:
    SCRIPT_SH = os.path.join(SCRIPT_DIR, "macos-ify.sh")
CACHE_DIR = os.path.expanduser("~/.cache/macos-ify")
PREVIEW_DIR = os.path.join(CACHE_DIR, "previews")
LOGO_LOCAL = os.path.join(SCRIPT_DIR, "macos-ify-logo.png")
LOGO_CACHE = os.path.join(CACHE_DIR, "macos-ify-logo.png")
LOGO_URL = ("https://raw.githubusercontent.com/BushidoCyb3r/"
            "MacOS-ify/main/macos-ify-logo.png")

WALLPAPERS = [
    ("1", "Orange", "https://miloszfalinski.com/content/files/2025/06/Orange-Dark.png"),
    ("2", "Green",  "https://miloszfalinski.com/content/files/2025/06/Green-Dark.png"),
    ("3", "Blue",   "https://miloszfalinski.com/content/files/2025/06/Blue-Dark.png"),
    ("4", "Purple", "https://miloszfalinski.com/content/files/2025/06/Purple-Dark.png"),
]

# (script name, button label, tooltip)
EXTRAS = [
    ("logo-menu", "Apple Menu",
     "Logo Menu — Apple-style menu in the top-left, replacing Activities"),
    ("search-light", "Spotlight Search",
     "Search Light — floating search popup (default hotkey Ctrl+Super+Space)"),
    ("appindicator-support", "Tray Icons",
     "AppIndicator — menu-bar style system tray icons in the top panel"),
    ("just-perfection", "Panel Tweaks",
     "Just Perfection — clock position, panel cleanup, UI element control"),
    ("compiz-alike-magic-lamp-effect", "Genie Minimize",
     "Magic Lamp — the macOS genie animation when minimizing windows"),
    ("rounded-window-corners-reborn", "Rounded Corners",
     "Rounded Window Corners — rounds every window (requires GNOME 46+)"),
    ("app-switcher", "Cmd-style App Switching",
     "Super+Tab cycles applications, Super+` cycles windows of the current "
     "app (gsettings only, no extension)"),
]

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
# Distinctive sudo prompt so the reader thread can spot it in the pty
# stream and inject the stored password exactly when sudo asks.
SUDO_MARKER = "MACOSIFY_SUDO_PROMPT::"

# ---- design tokens, derived from the project logo itself:
#   ink #0d1420 (logo navy)   panel #16202e   line #263246
#   accent #f09000 (logo orange = default wallpaper)   info #48a8d8 (logo blue)
CSS = b"""
window { background-color: #0d1420; }
headerbar { background: linear-gradient(180deg, #121b2a, #0d1420);
            border: none; box-shadow: none; min-height: 42px; }
headerbar .title { color: #8b98ab; font-weight: 600; letter-spacing: 1px; }

.hero-plate { background-color: #fbfbfd; border-radius: 16px;
              padding: 8px 22px;
              box-shadow: 0 12px 30px rgba(0,0,0,0.45); }
.hero-sub  { color: #8b98ab; font-size: 13px; }

.card { background-color: #16202e; border: 1px solid #263246;
        border-radius: 14px; padding: 13px; }
.eyebrow { color: #48a8d8; font-size: 11px; font-weight: 700;
           letter-spacing: 2px; }
label { color: #e8edf4; }
.dim { color: #8b98ab; }

button { background-color: #1c2837; background-image: none;
         color: #e8edf4; border: 1px solid #2c3a50; border-radius: 9px;
         padding: 6px 14px; box-shadow: none;
         transition: all 160ms ease; }
button:hover { background-color: #233247; border-color: #3a4c68; }

button.pill { border-radius: 999px; padding: 8px 18px; }
button.pill:checked { background-color: #f09000; border-color: #f09000;
                      color: #181004; font-weight: 700;
                      box-shadow: 0 2px 14px rgba(240,144,0,0.35); }

button.wall { background-color: #121b28; border: 2px solid #263246;
              border-radius: 14px; padding: 8px; }
button.wall:hover { border-color: #48a8d8; }
button.wall:checked { border-color: #f09000;
    box-shadow: 0 0 0 3px rgba(240,144,0,0.25), 0 6px 18px rgba(0,0,0,0.4); }
button.wall label { color: #8b98ab; font-size: 12px; }
button.wall:checked label { color: #f09000; font-weight: 700; }

button.go { background-image: linear-gradient(180deg, #ffa51e, #ee8c00);
            color: #181004; font-weight: 800; font-size: 15px;
            border: none; border-radius: 12px; padding: 12px 34px;
            box-shadow: 0 6px 20px rgba(240,144,0,0.35); }
button.go:hover { background-image: linear-gradient(180deg, #ffb13d, #f89a14);
                  box-shadow: 0 8px 26px rgba(240,144,0,0.5); }

button.danger { background-color: #3a1620; border-color: #6e2434;
                color: #ff9aa8; }
button.danger:hover { background-color: #4a1c29; }

checkbutton label, radiobutton label { color: #c8d2e0; }
checkbutton:hover label, radiobutton:hover label { color: #ffffff; }

textview.console, textview.console text {
    background-color: #0a1019; color: #c9d4e3; }
.status { color: #48a8d8; font-weight: 600; }
.prompt-text { color: #ffd27a; font-family: monospace; }
spinner { color: #f09000; }

.done-mark  { color: #f09000; font-size: 54px; font-weight: 800; }
.done-title { font-size: 20px; font-weight: 800; }
scrollbar { background-color: transparent; }
"""


def apply_style():
    settings = Gtk.Settings.get_default()
    if settings is not None:
        settings.set_property("gtk-application-prefer-dark-theme", True)
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


class MacosifyWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="MacOS-ify")
        apply_style()
        self.set_default_size(920, 960)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("destroy", self.on_destroy)

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        title_lbl = Gtk.Label(label="MacOS-ify")
        title_lbl.get_style_context().add_class("title")
        header.set_custom_title(title_lbl)
        self.set_titlebar(header)

        self.proc = None
        self.master_fd = None
        self._sudo_pw = None
        self.sudo_keepalive_stop = threading.Event()
        self.wall_buttons = {}
        self.wall_choice = "1"

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(outer)

        outer.pack_start(self._build_header(), False, False, 0)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.stack.set_transition_duration(220)
        outer.pack_start(self.stack, True, True, 0)

        self.stack.add_named(self._build_setup_page(), "setup")
        self.stack.add_named(self._build_install_page(), "install")
        self.stack.add_named(self._build_done_page(), "done")

        self.show_all()
        threading.Thread(target=self._load_previews, daemon=True).start()

    # ---------- hero (logo at README scale) ----------------------------------
    def _build_header(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_top(14)
        box.set_margin_bottom(2)
        box.set_margin_start(24)
        box.set_margin_end(24)

        # The logo asset has a white background; give it a white plate and
        # let it be the hero rather than a 64px chip in a corner.
        plate = Gtk.Box()
        plate.get_style_context().add_class("hero-plate")
        plate.set_halign(Gtk.Align.CENTER)
        self.logo_image = Gtk.Image()
        plate.pack_start(self.logo_image, False, False, 0)
        box.pack_start(plate, False, False, 0)
        threading.Thread(target=self._load_logo, daemon=True).start()

        sub = Gtk.Label(label="Turn this Linux desktop into a macOS lookalike")
        sub.get_style_context().add_class("hero-sub")
        box.pack_start(sub, False, False, 0)
        return box

    def _load_logo(self):
        path = None
        if os.path.isfile(LOGO_LOCAL):
            path = LOGO_LOCAL
        elif os.path.isfile(LOGO_CACHE):
            path = LOGO_CACHE
        else:
            try:
                os.makedirs(CACHE_DIR, exist_ok=True)
                urllib.request.urlretrieve(LOGO_URL, LOGO_CACHE)
                path = LOGO_CACHE
            except Exception:
                return  # no logo; text header stands alone
        try:
            pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, 470, -1, True)
            GLib.idle_add(self.logo_image.set_from_pixbuf, pb)
        except Exception:
            pass

    # ---------- page 1: setup ------------------------------------------------
    def _build_setup_page(self):
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        page.set_margin_top(8)
        page.set_margin_bottom(14)
        page.set_margin_start(24)
        page.set_margin_end(24)
        scroller.add(page)

        # -- theme row
        theme_card = self._card("THEME")
        page.pack_start(theme_card, False, False, 0)
        theme_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.radio_dark = Gtk.RadioButton.new_with_label_from_widget(None, "Dark")
        self.radio_light = Gtk.RadioButton.new_with_label_from_widget(
            self.radio_dark, "Light")
        theme_row.pack_start(self.radio_dark, False, False, 0)
        theme_row.pack_start(self.radio_light, False, False, 0)

        theme_row.pack_start(Gtk.Label(label="   Accent:"), False, False, 0)
        self.accent_combo = Gtk.ComboBoxText()
        for accent in ("default", "blue", "purple", "pink", "red",
                       "orange", "yellow", "green", "grey"):
            self.accent_combo.append_text(accent)
        self.accent_combo.set_active(0)
        theme_row.pack_start(self.accent_combo, False, False, 0)
        theme_card.pack_start(theme_row, False, False, 0)

        # -- base options
        opt_card = self._card("OPTIONS")
        page.pack_start(opt_card, False, False, 0)
        opt_grid = Gtk.FlowBox()
        opt_grid.set_selection_mode(Gtk.SelectionMode.NONE)
        opt_grid.set_max_children_per_line(2)
        self.chk_font = Gtk.CheckButton(label="Inter UI font")
        self.chk_font.set_active(True)
        self.chk_font.set_tooltip_text(
            "Replace the default UI font with Inter — the biggest visual win")
        self.chk_quicklook = Gtk.CheckButton(label="Quick Look (Sushi)")
        self.chk_quicklook.set_active(True)
        self.chk_quicklook.set_tooltip_text(
            "Spacebar file previews in GNOME Files, like Finder's Quick Look")
        self.chk_libadwaita = Gtk.CheckButton(label="Theme GNOME core apps (libadwaita)")
        self.chk_libadwaita.set_active(True)
        self.chk_libadwaita.set_tooltip_text(
            "Overrides ~/.config/gtk-4.0 to theme Settings/Files/etc. "
            "Can break on GNOME upgrades — uncheck for a safer install")
        self.chk_gdm = Gtk.CheckButton(label="Theme login screen (GDM)")
        self.chk_gdm.set_active(False)
        self.chk_gdm.set_tooltip_text("Modifies system files via sudo")
        self.chk_keyboard = Gtk.CheckButton(label="Cmd-style keyboard (Toshy)")
        self.chk_keyboard.set_active(False)
        self.chk_keyboard.set_tooltip_text(
            "System-wide Cmd+C/V/W/T/Q shortcuts via Toshy. Installs systemd "
            "user services, udev rules, and adds you to the 'input' group")
        self.chk_keyboard.connect("toggled", self.on_keyboard_toggled)
        self.chk_dryrun = Gtk.CheckButton(label="Dry run (print, change nothing)")
        self.chk_dryrun.set_active(False)
        for w in (self.chk_font, self.chk_quicklook, self.chk_libadwaita,
                  self.chk_gdm, self.chk_keyboard, self.chk_dryrun):
            opt_grid.add(w)
        opt_card.pack_start(opt_grid, False, False, 0)

        # -- extras as pill toggles (orange when active — the signature)
        extras_card = self._card("EXTRAS")
        page.pack_start(extras_card, False, False, 0)
        extras_flow = Gtk.FlowBox()
        extras_flow.set_selection_mode(Gtk.SelectionMode.NONE)
        extras_flow.set_max_children_per_line(4)
        extras_flow.set_row_spacing(6)
        extras_flow.set_column_spacing(6)
        self.extra_buttons = {}
        for name, label, tip in EXTRAS:
            btn = Gtk.ToggleButton(label=label)
            btn.set_tooltip_text(tip)
            btn.get_style_context().add_class("pill")
            self.extra_buttons[name] = btn
            extras_flow.add(btn)
        sel_all = Gtk.ToggleButton(label="Select All")
        sel_all.get_style_context().add_class("pill")
        sel_all.connect("toggled", self.on_select_all_extras)
        extras_flow.add(sel_all)
        extras_card.pack_start(extras_flow, False, False, 0)

        # -- wallpaper previews
        wall_card = self._card("WALLPAPER")
        page.pack_start(wall_card, False, False, 0)
        wall_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        wall_row.set_halign(Gtk.Align.CENTER)
        for num, label, _url in WALLPAPERS:
            vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            img = Gtk.Image()
            img.set_size_request(168, 105)
            vbox.pack_start(img, False, False, 0)
            vbox.pack_start(Gtk.Label(label=label), False, False, 0)
            btn = Gtk.ToggleButton()
            btn.get_style_context().add_class("wall")
            btn.add(vbox)
            btn.connect("toggled", self.on_wall_toggled, num)
            self.wall_buttons[num] = (btn, img)
            wall_row.pack_start(btn, False, False, 0)
        self.wall_buttons["1"][0].set_active(True)
        wall_card.pack_start(wall_row, False, False, 0)

        # -- install button
        self.install_btn = Gtk.Button(label="Install")
        self.install_btn.get_style_context().add_class("go")
        self.install_btn.connect("clicked", self.on_install_clicked)
        btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        btn_row.set_halign(Gtk.Align.CENTER)
        btn_row.pack_start(self.install_btn, False, False, 0)
        page.pack_start(btn_row, False, False, 10)

        return scroller

    @staticmethod
    def _card(eyebrow_text):
        """A navy card with a blue eyebrow label; callers pack content into it."""
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        card.get_style_context().add_class("card")
        lbl = Gtk.Label(label=eyebrow_text)
        lbl.get_style_context().add_class("eyebrow")
        lbl.set_xalign(0)
        card.pack_start(lbl, False, False, 0)
        return card

    # ---------- wallpaper previews -------------------------------------------
    def _load_previews(self):
        os.makedirs(PREVIEW_DIR, exist_ok=True)
        for num, _label, url in WALLPAPERS:
            dest = os.path.join(PREVIEW_DIR, os.path.basename(url))
            if not os.path.isfile(dest):
                try:
                    urllib.request.urlretrieve(url, dest)
                except Exception:
                    continue  # leave that preview blank; selection still works
            try:
                pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(dest, 168, 105, True)
                img = self.wall_buttons[num][1]
                GLib.idle_add(img.set_from_pixbuf, pb)
            except Exception:
                continue

    def on_wall_toggled(self, button, num):
        if button.get_active():
            self.wall_choice = num
            for other_num, (btn, _img) in self.wall_buttons.items():
                if other_num != num and btn.get_active():
                    btn.set_active(False)
        else:
            # forbid deselecting the only active choice
            if not any(b.get_active() for b, _ in self.wall_buttons.values()):
                button.set_active(True)

    def on_select_all_extras(self, button):
        state = button.get_active()
        for btn in self.extra_buttons.values():
            btn.set_active(state)
        button.set_label("Deselect All" if state else "Select All")

    def on_keyboard_toggled(self, button):
        if not button.get_active():
            return
        dlg = Gtk.MessageDialog(
            transient_for=self, modal=True,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.YES_NO,
            text="Install Toshy keyboard remapping?")
        dlg.format_secondary_text(
            "Toshy installs systemd user services, udev rules, and adds your "
            "user to the 'input' group to read keyboard events. It is the "
            "deepest change this installer can make. It can be removed later "
            "with its own uninstaller. Continue?")
        if dlg.run() != Gtk.ResponseType.YES:
            button.set_active(False)
        dlg.destroy()

    # ---------- page 2: install ----------------------------------------------
    def _build_install_page(self):
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        page.set_margin_top(10)
        page.set_margin_bottom(20)
        page.set_margin_start(24)
        page.set_margin_end(24)

        status_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.spinner = Gtk.Spinner()
        self.spinner.set_size_request(18, 18)
        status_row.pack_start(self.spinner, False, False, 0)
        self.status_label = Gtk.Label(label="Installing…")
        self.status_label.get_style_context().add_class("status")
        self.status_label.set_xalign(0)
        status_row.pack_start(self.status_label, True, True, 0)
        page.pack_start(status_row, False, False, 0)

        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.textview = Gtk.TextView()
        self.textview.set_editable(False)
        self.textview.set_cursor_visible(False)
        self.textview.set_monospace(True)
        self.textview.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.textview.get_style_context().add_class("console")
        self.textview.set_left_margin(12)
        self.textview.set_right_margin(12)
        self.textview.set_top_margin(10)
        self.textbuf = self.textview.get_buffer()
        scroller.add(self.textview)
        page.pack_start(scroller, True, True, 0)

        # Interactive input bar — hidden until the child process blocks on a
        # prompt (e.g. Toshy's installer). When revealed, it shows the prompt
        # text and an entry whose contents get written straight back to the
        # child's pty, so the GUI behaves like a real terminal for any
        # third-party installer that asks questions.
        self.prompt_revealer = Gtk.Revealer()
        self.prompt_revealer.set_transition_type(
            Gtk.RevealerTransitionType.SLIDE_UP)
        self.prompt_revealer.set_transition_duration(150)
        prompt_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        prompt_box.get_style_context().add_class("card")
        self.prompt_label = Gtk.Label()
        self.prompt_label.get_style_context().add_class("prompt-text")
        self.prompt_label.set_xalign(0)
        self.prompt_label.set_line_wrap(True)
        self.prompt_label.set_selectable(True)  # so secret codes can be copied
        prompt_box.pack_start(self.prompt_label, False, False, 0)
        entry_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.prompt_entry = Gtk.Entry()
        self.prompt_entry.set_placeholder_text("Type your answer, then Enter…")
        self.prompt_entry.connect("activate", self.on_prompt_submit)
        entry_row.pack_start(self.prompt_entry, True, True, 0)
        self.prompt_send = Gtk.Button(label="Send")
        self.prompt_send.get_style_context().add_class("go")
        self.prompt_send.connect("clicked", self.on_prompt_submit)
        entry_row.pack_start(self.prompt_send, False, False, 0)
        prompt_box.pack_start(entry_row, False, False, 0)
        self.prompt_revealer.add(prompt_box)
        page.pack_start(self.prompt_revealer, False, False, 0)

        self.cancel_btn = Gtk.Button(label="Cancel")
        self.cancel_btn.connect("clicked", self.on_cancel_clicked)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        row.pack_end(self.cancel_btn, False, False, 0)
        page.pack_start(row, False, False, 0)
        return page

    # ---------- page 3: done -------------------------------------------------
    def _build_done_page(self):
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        page.set_margin_top(36)
        page.set_margin_start(24)
        page.set_margin_end(24)
        self.done_mark = Gtk.Label(label="")
        self.done_mark.get_style_context().add_class("done-mark")
        page.pack_start(self.done_mark, False, False, 0)
        self.done_label = Gtk.Label()
        self.done_label.set_justify(Gtk.Justification.CENTER)
        self.done_label.set_line_wrap(True)
        page.pack_start(self.done_label, False, False, 0)

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        row.set_halign(Gtk.Align.CENTER)
        self.reboot_btn = Gtk.Button(label="Reboot Now")
        self.reboot_btn.get_style_context().add_class("danger")
        self.reboot_btn.connect("clicked", self.on_reboot_clicked)
        close_btn = Gtk.Button(label="Close")
        close_btn.connect("clicked", lambda *_: self.destroy())
        back_btn = Gtk.Button(label="Back to Options")
        back_btn.connect(
            "clicked", lambda *_: self.stack.set_visible_child_name("setup"))
        view_btn = Gtk.Button(label="View Output")
        view_btn.connect(
            "clicked", lambda *_: self.stack.set_visible_child_name("install"))
        row.pack_start(self.reboot_btn, False, False, 0)
        row.pack_start(view_btn, False, False, 0)
        row.pack_start(back_btn, False, False, 0)
        row.pack_start(close_btn, False, False, 0)
        page.pack_start(row, False, False, 0)
        return page

    # ---------- flag assembly --------------------------------------------------
    def build_command(self):
        cmd = [SCRIPT_SH,
               "-c", "light" if self.radio_light.get_active() else "dark",
               "-a", self.accent_combo.get_active_text() or "default",
               "--wallpaper", self.wall_choice,
               "--yes", "--no-reboot"]
        if not self.chk_font.get_active():
            cmd.append("--no-font")
        if not self.chk_quicklook.get_active():
            cmd.append("--no-quicklook")
        if not self.chk_libadwaita.get_active():
            cmd.append("--no-libadwaita")
        if self.chk_gdm.get_active():
            cmd.append("--gdm")
        if self.chk_keyboard.get_active():
            cmd.append("--keyboard")
        if self.chk_dryrun.get_active():
            cmd.append("--dry-run")

        selected = [n for n, b in self.extra_buttons.items() if b.get_active()]
        if len(selected) == len(EXTRAS):
            cmd.append("--extras")
        elif selected:
            cmd += ["--extras-only", ",".join(selected)]
        return cmd

    # ---------- sudo handling ----------------------------------------------------
    # The script invokes sudo internally; with no controlling terminal there is
    # nowhere for sudo to prompt. So: ask once via dialog, validate with
    # `sudo -S -v` (password goes to sudo's stdin and nowhere else, never to
    # disk, never into argv), then keep the timestamp warm in a background
    # thread for the duration of the run.
    def prime_sudo(self):
        if self.chk_dryrun.get_active():
            return True  # dry-run never reaches sudo

        # Detect GENUINE passwordless sudo (NOPASSWD in sudoers), not just a
        # warm timestamp. `sudo -n -v` returns 0 for BOTH cases, which is the
        # trap that bit us: a cached timestamp from an earlier terminal run
        # made the GUI think no password was needed, so it never captured one
        # to inject — then the install's pty (a different tty, with its own
        # empty timestamp on RHEL) prompted and we had nothing to send.
        #
        # `sudo -n -l` lists privileges without prompting; a NOPASSWD entry
        # shows up as "(ALL) NOPASSWD: ...". Only then is it safe to skip the
        # dialog. Invalidate any cached timestamp first (-k) so a warm one
        # can't masquerade as NOPASSWD.
        subprocess.run(["sudo", "-k"], capture_output=True)
        listing = subprocess.run(["sudo", "-n", "-l"],
                                 capture_output=True, text=True)
        if listing.returncode == 0 and "NOPASSWD" in listing.stdout:
            self._sudo_pw = None  # genuinely not needed
            return True

        for _attempt in range(3):
            dlg = Gtk.Dialog(title="Authentication required",
                             transient_for=self, modal=True)
            dlg.add_buttons("Cancel", Gtk.ResponseType.CANCEL,
                            "OK", Gtk.ResponseType.OK)
            box = dlg.get_content_area()
            box.set_spacing(8)
            box.set_margin_top(12)
            box.set_margin_bottom(12)
            box.set_margin_start(12)
            box.set_margin_end(12)
            box.add(Gtk.Label(label="The installer needs sudo. "
                                    "Enter your password:"))
            entry = Gtk.Entry()
            entry.set_visibility(False)
            entry.set_activates_default(True)
            box.add(entry)
            dlg.set_default_response(Gtk.ResponseType.OK)
            dlg.show_all()
            resp = dlg.run()
            password = entry.get_text()
            dlg.destroy()
            if resp != Gtk.ResponseType.OK:
                return False
            check = subprocess.run(
                ["sudo", "-S", "-k", "-v"],
                input=password + "\n", text=True, capture_output=True)
            if check.returncode == 0:
                # Held in memory only, injected when sudo prompts on the
                # installer's pty; cleared the moment the run ends. No
                # keepalive thread — warming THIS process's tty timestamp
                # does nothing for the child pty (sudo keys timestamps
                # per-tty on RHEL), which was the original design flaw.
                self._sudo_pw = password
                return True
            password = ""
            self._error_dialog("Wrong password — try again.")
        return False

    def _start_sudo_keepalive(self):
        self.sudo_keepalive_stop.clear()

        def keepalive():
            while not self.sudo_keepalive_stop.wait(50):
                subprocess.run(["sudo", "-n", "-v"], capture_output=True)
        threading.Thread(target=keepalive, daemon=True).start()

    def _error_dialog(self, text):
        dlg = Gtk.MessageDialog(transient_for=self, modal=True,
                                message_type=Gtk.MessageType.ERROR,
                                buttons=Gtk.ButtonsType.OK, text=text)
        dlg.run()
        dlg.destroy()

    # ---------- run + stream ---------------------------------------------------
    def on_install_clicked(self, _btn):
        if not os.path.isfile(SCRIPT_SH):
            self._error_dialog(f"macos-ify.sh not found at {SCRIPT_SH}")
            return
        if not self.prime_sudo():
            return

        cmd = self.build_command()
        self.textbuf.set_text("$ " + " ".join(cmd) + "\n\n")
        self.stack.set_visible_child_name("install")
        self.spinner.start()
        self.status_label.set_text("Installing…")
        self.cancel_btn.set_sensitive(True)

        # Run the installer attached to a pseudo-terminal. This matters on
        # RHEL-family systems: sudo keys its timestamp per-tty, so a timestamp
        # primed from this GUI process does NOT cover the script's sudo calls,
        # and without a terminal sudo dies with "a terminal is required".
        # With a pty, sudo prompts ON the pty (using our SUDO_MARKER prompt)
        # and the reader thread injects the validated password.
        self.master_fd, slave_fd = pty.openpty()
        env = dict(os.environ, SUDO_PROMPT=SUDO_MARKER)

        def make_pty_controlling():
            os.setsid()  # own session/group: Cancel kills the whole tree
            # stdin is already dup'ed to the pty slave; claim it as the
            # controlling terminal so sudo's /dev/tty resolves to it.
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(
            cmd, stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
            cwd=SCRIPT_DIR, env=env, close_fds=True,
            preexec_fn=make_pty_controlling)
        os.close(slave_fd)
        threading.Thread(target=self._reader_thread, daemon=True).start()

    def _reader_thread(self):
        assert self.proc is not None and self.master_fd is not None
        pending = ""
        prompt_shown = False
        while True:
            # Wait up to 0.4s for output. A timeout with un-newlined text in
            # `pending` means the child produced a line and then went quiet —
            # i.e. it's blocked waiting for input (a prompt). select() is how
            # we distinguish "still working" from "waiting for you".
            try:
                ready, _, _ = select.select([self.master_fd], [], [], 0.4)
            except (OSError, ValueError):
                break

            if ready:
                try:
                    chunk = os.read(self.master_fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                pending += chunk.decode("utf-8", "replace")

                # sudo prompt: answered automatically by injection.
                if SUDO_MARKER in pending:
                    if self._sudo_pw is not None:
                        os.write(self.master_fd, (self._sudo_pw + "\n").encode())
                        pending = pending.replace(SUDO_MARKER, "[sudo] authenticating…")
                    else:
                        pending = pending.replace(
                            SUDO_MARKER, "[sudo] password required.")

                # Flush completed lines; keep any trailing partial line in
                # `pending` (it may be a prompt, or just an unfinished line).
                hold = 0
                for i in range(1, len(SUDO_MARKER)):
                    if pending.endswith(SUDO_MARKER[:i]):
                        hold = i
                if "\n" in pending:
                    head, _, tail = pending.rpartition("\n")
                    clean = ANSI_RE.sub("", head + "\n")
                    clean = clean.replace("\r\n", "\n").replace("\r", "\n")
                    GLib.idle_add(self._append_line, clean)
                    pending = tail
                if prompt_shown:
                    GLib.idle_add(self._hide_prompt)
                    prompt_shown = False
                continue

            # ---- select timed out (no output for 0.4s) ----
            if self.proc.poll() is not None:
                break  # child exited
            tail = ANSI_RE.sub("", pending).replace("\r", "").strip()
            # A non-empty trailing line with no newline, while the child is
            # alive and quiet, is a prompt. Reveal the input bar with it.
            if tail and not prompt_shown and SUDO_MARKER not in pending:
                # show whatever's already flushed, plus the prompt line, in
                # the console too so context (e.g. a secret code above) stays
                # visible; then surface the input bar.
                GLib.idle_add(self._append_line, ANSI_RE.sub("", pending))
                pending = ""
                GLib.idle_add(self._show_prompt, tail)
                prompt_shown = True

        if pending:
            GLib.idle_add(self._append_line, ANSI_RE.sub("", pending))
        rc = self.proc.wait()
        self._sudo_pw = None
        try:
            os.close(self.master_fd)
        except OSError:
            pass
        self.master_fd = None
        self.sudo_keepalive_stop.set()
        GLib.idle_add(self._on_finished, rc)

    # ---- interactive prompt handling ----
    def _show_prompt(self, prompt_text):
        self.status_label.set_text("Waiting for your input…")
        self.spinner.stop()
        self.prompt_label.set_text(prompt_text)
        self.prompt_revealer.set_reveal_child(True)
        self.prompt_entry.set_text("")
        self.prompt_entry.grab_focus()
        return False

    def _hide_prompt(self):
        if self.prompt_revealer.get_reveal_child():
            self.prompt_revealer.set_reveal_child(False)
            self.status_label.set_text("Installing…")
            self.spinner.start()
        return False

    def on_prompt_submit(self, _widget):
        if self.master_fd is None:
            return
        answer = self.prompt_entry.get_text()
        try:
            os.write(self.master_fd, (answer + "\n").encode())
        except OSError:
            return
        # echo the answer into the console so there's a record of it
        GLib.idle_add(self._append_line, answer + "\n")
        self.prompt_entry.set_text("")
        self._hide_prompt()

    def _append_line(self, line):
        end = self.textbuf.get_end_iter()
        self.textbuf.insert(end, line)
        mark = self.textbuf.create_mark(None, self.textbuf.get_end_iter(), False)
        self.textview.scroll_mark_onscreen(mark)
        self.textbuf.delete_mark(mark)
        return False

    def _on_finished(self, rc):
        self.spinner.stop()
        self.proc = None
        if rc == 0:
            self.done_mark.set_text("✓")
            msg = ("<span size='large' weight='bold'>Install complete.</span>\n\n"
                   "A reboot is required to activate GNOME Shell extensions.\n"
                   "A one-time job will finalize dock/theme settings on your "
                   "next login.")
            if self.chk_keyboard.get_active():
                msg += ("\n\nToshy (Cmd-style keyboard) was installed. "
                        "Log out and back in for its services to start.")
            self.done_label.set_markup(msg)
            self.reboot_btn.set_sensitive(True)
        else:
            self.done_mark.set_text("!")
            self.done_label.set_markup(
                f"<span size='large' weight='bold'>Installer exited with "
                f"code {rc}.</span>\n\nClick <b>View Output</b> to see the "
                f"failing command — the [FAIL] line near the end names it.\n"
                f"Log: {CACHE_DIR}/install.log")
            self.reboot_btn.set_sensitive(False)
        self.stack.set_visible_child_name("done")
        return False

    def on_cancel_clicked(self, _btn):
        if self.proc is not None:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            except Exception:
                pass
            self.status_label.set_text("Cancelled.")
            self.cancel_btn.set_sensitive(False)

    def on_reboot_clicked(self, _btn):
        # The install's sudo timestamp is gone by now (and on RHEL it lived on
        # the install pty's tty, not this process), so `sudo -n reboot` fails
        # silently — which is why the button appeared dead. Authenticate
        # explicitly via `sudo -S` feeding the password on stdin, the same
        # mechanism that works elsewhere on this system.
        pw = self._sudo_pw
        if pw is None:
            # Not held (genuine NOPASSWD, or it was cleared). Try passwordless
            # first; if that fails, ask for the password now.
            if subprocess.run(["sudo", "-n", "true"],
                              capture_output=True).returncode == 0:
                subprocess.Popen(["sudo", "reboot"])
                return
            if not self._ask_reboot_password():
                return
            pw = self._sudo_pw

        result = subprocess.run(
            ["sudo", "-S", "reboot"],
            input=(pw or "") + "\n", text=True, capture_output=True)
        # `reboot` normally kills us before returning; if we're still here with
        # a non-zero code, it failed — tell the user instead of doing nothing.
        if result.returncode != 0:
            self._sudo_pw = None  # likely wrong/expired; force a fresh ask next time
            self._error_dialog(
                "Couldn't reboot automatically.\n\n"
                "Open a terminal and run:  sudo reboot\n\n"
                f"({result.stderr.strip() or 'authentication failed'})")

    def _ask_reboot_password(self):
        """Minimal password prompt used only for the post-install reboot."""
        dlg = Gtk.Dialog(title="Authentication required",
                         transient_for=self, modal=True)
        dlg.add_buttons("Cancel", Gtk.ResponseType.CANCEL,
                        "Reboot", Gtk.ResponseType.OK)
        box = dlg.get_content_area()
        box.set_spacing(8)
        box.set_margin_top(12)
        box.set_margin_bottom(12)
        box.set_margin_start(12)
        box.set_margin_end(12)
        box.add(Gtk.Label(label="Enter your password to reboot:"))
        entry = Gtk.Entry()
        entry.set_visibility(False)
        entry.set_activates_default(True)
        box.add(entry)
        dlg.set_default_response(Gtk.ResponseType.OK)
        dlg.show_all()
        resp = dlg.run()
        pw = entry.get_text()
        dlg.destroy()
        if resp != Gtk.ResponseType.OK:
            return False
        # validate before using
        check = subprocess.run(["sudo", "-S", "-k", "-v"],
                              input=pw + "\n", text=True, capture_output=True)
        if check.returncode == 0:
            self._sudo_pw = pw
            return True
        self._error_dialog("Wrong password.")
        return False

    def on_destroy(self, *_args):
        self.sudo_keepalive_stop.set()
        if self.proc is not None:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            except Exception:
                pass
        Gtk.main_quit()


def main():
    if not shutil.which("sudo"):
        print("sudo is required.", file=sys.stderr)
        sys.exit(1)
    win = MacosifyWindow()
    win.connect("delete-event", Gtk.main_quit)
    Gtk.main()


if __name__ == "__main__":
    main()
____GUI_PAYLOAD____
