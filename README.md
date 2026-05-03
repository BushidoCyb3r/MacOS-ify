<p align="center">
  <img src="IMG_0050.PNG" alt="macos-ify logo" width="480">
</p>

# MacOS-ify

> A bash script that detects your Linux distribution and makes your desktop look like macOS using the [WhiteSur](https://github.com/vinceliuice/WhiteSur-gtk-theme) theme suite.

[![Shell](https://img.shields.io/badge/shell-bash-1f425f.svg)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](#license)
[![Distros](https://img.shields.io/badge/distros-Fedora%20%7C%20Debian%2FUbuntu%20%7C%20Arch-orange.svg)](#supported-systems)

`macos-ify` automates the tedious parts of skinning a Linux desktop to look like macOS: detecting your distro, installing prerequisites with the correct package manager, pulling and building WhiteSur (GTK theme, icons, cursors, wallpapers), setting a matching wallpaper, installing the right GNOME Shell extensions for your shell version, and applying everything via `gsettings`.

The WhiteSur theme pack (GTK theme, icons, cursors, wallpaper) installs and works on **any** supported desktop environment. The full macOS experience — top bar, animated dock, blurred panels — requires GNOME Shell. On non-GNOME desktops the script asks whether to add GNOME alongside your existing DE; if you decline it applies the themes only.

It is **not** magic. It is a wrapper around well-maintained upstream projects with sensible defaults, error handling, and an honest set of warnings about what it cannot do.

---

## Table of contents

- [Features](#features)
- [Supported systems](#supported-systems)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Examples](#examples)
- [What it installs](#what-it-installs)
- [How it works](#how-it-works)
- [Caveats and limitations](#caveats-and-limitations)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Customization](#customization)
- [Credits](#credits)
- [License](#license)

---

## Features

- **Distro auto-detection** via `/etc/os-release` with `ID_LIKE` fallback. No need to tell it what you're running.
- **Package-manager abstraction.** Same script, same flags, works across `dnf`, `apt`, and `pacman`.
- **GNOME Shell version awareness.** Queries the official extensions.gnome.org API to fetch only extension builds compatible with your installed GNOME version.
- **Non-GNOME DE support.** On Cinnamon, XFCE, KDE, etc. the script installs WhiteSur themes, icons, cursors, and wallpaper and asks before touching your desktop environment.
- **Custom wallpaper.** Downloads and sets a matching dark wallpaper automatically on both GNOME and Cinnamon.
- **Dry-run mode.** Print every command without touching anything. Always run this first.
- **Confirmation prompts** on destructive operations (libadwaita override, GDM theming, GNOME install on non-GNOME systems), with `--yes` for unattended runs.
- **Idempotent where possible.** Re-running pulls latest from upstream rather than re-cloning.
- **Logged.** Every action is timestamped to `~/.cache/macos-ify/install.log`.
- **Honest about what it can't do.** See [Caveats](#caveats-and-limitations).

---

## Supported systems

| Family       | Distros                                                                    | Package manager |
|--------------|----------------------------------------------------------------------------|-----------------|
| RHEL-based   | Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux                              | `dnf`           |
| Debian-based | Debian, Ubuntu, Linux Mint, Pop!_OS, elementary OS, Zorin OS, Kali, Parrot | `apt`           |
| Arch-based   | Arch, Manjaro, EndeavourOS, Garuda                                         | `pacman`        |

**Desktop environment:** GNOME Shell 42 or newer is required for the full macOS experience (top bar, dock, blur, animations). If a non-GNOME desktop is detected, the script will ask whether to install GNOME Shell alongside it — your existing DE and display manager are left untouched. WhiteSur themes, icons, cursors, and wallpaper install and work on any desktop.

> **Non-GNOME installs (e.g. Linux Mint / Cinnamon):** On Debian-based systems, `apt` will prompt you to choose a default display manager during the GNOME Shell install. **You must select gdm3.** Choosing `lightdm` will prevent GNOME from loading correctly.

**Display server:** Both Wayland (default on most modern distros) and X11 are supported. On GNOME installs the script reboots automatically so extensions activate on first login. On non-GNOME installs (themes only) no reboot is triggered — log out and back in instead.

**Not supported:** openSUSE/SLES (`zypper` is not implemented), Void Linux (`xbps`), Gentoo (`portage`), Alpine, NixOS. PRs welcome.

---

## Quick start

```bash
# Clone the repo
git clone https://github.com/BushidoCyb3r/macos-ify.git
cd macos-ify
chmod +x macos-ify.sh

# Always do a dry run first
./macos-ify.sh --dry-run

# Run the installer
./macos-ify.sh
```

**On GNOME:** the script reboots the system when done. A one-time autostart job runs automatically on first login to finalize extension-dependent settings (dock position, blur, shell theme), then removes itself.

**On non-GNOME (themes only):** no reboot is triggered. Log out and back in for the WhiteSur theme to take full effect, then select it in your desktop's Appearance or Tweaks tool.

```bash
# If you ever need to re-apply GNOME settings manually after login:
./macos-ify.sh --post-login
```

---

## Usage

```text
Usage: macos-ify.sh [OPTIONS]

Options:
  -a, --accent COLOR     Theme accent color
                         (default|blue|purple|pink|red|orange|yellow|green|grey)
                         [default: default]
  -c, --color VARIANT    Theme color variant: light | dark
                         [default: dark]
  -i, --icon VARIANT     Activities-icon variant
                         (apple|simple|gnome|fedora|ubuntu|arch|manjaro|debian|...)
                         [default: apple]
      --gdm              Also theme the GDM login screen (requires sudo)
      --no-libadwaita    Skip the libadwaita override (safer; Settings/Files/Calendar
                         will keep stock GNOME look but won't break on upgrades)
      --no-extensions    Skip GNOME extension installation
      --no-wallpapers    Skip WhiteSur wallpaper pack download
      --post-login       Finalize-only mode. Re-applies dock position, button
                         layout, blur, shell theme, and wallpaper — settings that
                         require GNOME Shell extensions to be loaded. Run this
                         AFTER logging out and back in.
  -y, --yes              Assume yes to every confirmation prompt
  -n, --dry-run          Print every command without changing anything
  -h, --help             Show help and exit
```

### Flag reference

| Flag                | What it controls                                                  | Risk    |
|---------------------|-------------------------------------------------------------------|---------|
| `-a, --accent`      | Window/widget accent color used by WhiteSur                       | None    |
| `-c, --color`       | Light vs dark variant of the theme                                | None    |
| `-i, --icon`        | Activities-icon variant (applied via WhiteSur's `--shell -i` sub-call; tolerated if unsupported) | None |
| `--gdm`             | Theme the GDM login screen — modifies system files via sudo       | Medium  |
| `--no-libadwaita`   | Don't overwrite `~/.config/gtk-4.0` to force-theme libadwaita apps | Reduces risk |
| `--no-extensions`   | Don't install user-themes, Dash to Dock, Blur My Shell            | Reduces effect |
| `--no-wallpapers`   | Don't clone the WhiteSur wallpaper pack (~50 MB saved)            | None    |
| `--post-login`      | Skip install; only re-apply gsettings and wallpaper (auto-triggered via XDG autostart after reboot; can also be run manually) | None |
| `-y, --yes`         | Skip all confirmation prompts (combine with `--gdm` carefully)    | Higher  |
| `-n, --dry-run`     | Plan-only mode                                                    | None    |

---

## Examples

```bash
# Default: dark theme, default accent, libadwaita override on, no GDM theming
./macos-ify.sh

# Light theme with a blue accent, also theme the login screen, no prompts
./macos-ify.sh -c light -a blue --gdm -y

# Conservative install: skip libadwaita override and skip GDM
./macos-ify.sh --no-libadwaita

# Just the themes, no GNOME extensions (e.g. if you manage extensions yourself)
./macos-ify.sh --no-extensions

# Plan-only — see every command that would run
./macos-ify.sh -n

# CI / automated bootstrap: light theme, blue accent, everything on, no prompts
./macos-ify.sh -c light -a blue -i apple --gdm -y
```

---

## What it installs

### System packages (per distro family)

| Family   | Packages                                                                                                           |
|----------|--------------------------------------------------------------------------------------------------------------------|
| RHEL     | `git curl unzip gnome-tweaks gnome-extensions-app sassc glib2-devel gtk-murrine-engine gnome-themes-extra flatpak` |
| Debian   | `git curl unzip gnome-tweaks gnome-shell-extension-manager sassc libglib2.0-dev-bin gtk2-engines-murrine gnome-themes-extra flatpak` |
| Arch     | `git curl unzip gnome-tweaks sassc glib2 gtk-engine-murrine gnome-themes-extra flatpak`                            |

### GNOME (if not already installed)

On non-GNOME systems, if you confirm, the script installs `gnome-shell` and `gnome-session`. Your existing display manager is **not** replaced. On Debian-based systems `apt` will prompt you to choose a display manager — **select gdm3**. After rebooting, choose the GNOME session from your login screen's session menu.

### Flatpak

Adds the Flathub remote (user scope) if not already present.

### GNOME Shell extensions

Pulled directly from extensions.gnome.org with version-matched downloads:

| Extension     | ID   | Why                                                              |
|---------------|------|------------------------------------------------------------------|
| User Themes   | 19   | Required to apply a Shell (top bar) theme at all                 |
| Dash to Dock  | 307  | The macOS-style bottom dock with intelligent autohide            |
| Blur My Shell | 3193 | Translucent / blurred top bar and overview                       |

### WhiteSur components (cloned to `~/.cache/macos-ify/`)

| Repo                                                                              | Provides                                  |
|-----------------------------------------------------------------------------------|-------------------------------------------|
| [`vinceliuice/WhiteSur-gtk-theme`](https://github.com/vinceliuice/WhiteSur-gtk-theme) | GTK3/GTK4 theme, optional GDM theme       |
| [`vinceliuice/WhiteSur-icon-theme`](https://github.com/vinceliuice/WhiteSur-icon-theme) | macOS-style icon set                      |
| [`vinceliuice/WhiteSur-cursors`](https://github.com/vinceliuice/WhiteSur-cursors)     | macOS-style cursors                       |
| [`vinceliuice/WhiteSur-wallpapers`](https://github.com/vinceliuice/WhiteSur-wallpapers) | Wallpaper pack (`~/.local/share/backgrounds`) |

### Wallpaper

Downloads `Orange-Dark.png` to `~/.local/share/backgrounds/` and sets it as the desktop wallpaper via gsettings. Applied on both GNOME and Cinnamon.

### dconf / gsettings keys modified

```
org.gnome.shell                              disable-extension-version-validation → true
                                             enabled-extensions → adds 3 entries
org.gnome.desktop.interface                  gtk-theme         → WhiteSur-{Light|Dark}[-accent]
org.gnome.desktop.interface                  icon-theme        → WhiteSur
org.gnome.desktop.interface                  cursor-theme      → WhiteSur-cursors
org.gnome.desktop.interface                  color-scheme      → prefer-{light|dark}
org.gnome.desktop.wm.preferences             button-layout     → close,minimize,maximize:
org.gnome.desktop.background                 picture-uri       → file://~/.local/share/backgrounds/Orange-Dark.png
org.gnome.desktop.background                 picture-uri-dark  → file://~/.local/share/backgrounds/Orange-Dark.png
org.gnome.shell.extensions.user-theme        name              → WhiteSur-{Light|Dark}[-accent]
org.gnome.shell.extensions.dash-to-dock      dock-position             → BOTTOM
org.gnome.shell.extensions.dash-to-dock      dock-fixed                → false
org.gnome.shell.extensions.dash-to-dock      intellihide               → true
org.gnome.shell.extensions.dash-to-dock      extend-height             → false
org.gnome.shell.extensions.dash-to-dock      dash-max-icon-size        → 42
org.gnome.shell.extensions.dash-to-dock      transparency-mode         → DYNAMIC
org.gnome.shell.extensions.dash-to-dock      running-indicator-style   → DOTS
org.gnome.shell.extensions.dash-to-dock      click-action              → minimize
org.gnome.shell.extensions.dash-to-dock      show-apps-at-top          → true
org.gnome.shell.extensions.blur-my-shell.panel  blur                   → true
org.gnome.shell.extensions.blur-my-shell.panel  static-blur            → true
org.cinnamon.desktop.background              picture-uri               → file://~/.local/share/backgrounds/Orange-Dark.png
```

### Other GNOME Shell state changed

The script will also:

- **Disable `ubuntu-dock@ubuntu.com`** if it's enabled (Ubuntu, Pop!_OS, Zorin OS ship this fork — both it and Dash to Dock active at the same time means neither displays correctly).
- **Disable `dash-to-panel@jderose9.github.com`** if it's enabled (same reason — competing dock implementation).
- **Set `disable-extension-version-validation=true`** so extensions whose `metadata.json` doesn't list your exact GNOME version still load. Without this, Dash to Dock is the most common silent-failure case after a GNOME upgrade.

These changes are not undone by the upstream theme uninstallers. See [Uninstall](#uninstall) for the full reset recipe.

---

## How it works

```
 ┌────────────────┐
 │  detect_distro │  parse /etc/os-release → DISTRO_FAMILY, PKG_MGR
 └───────┬────────┘
         │
 ┌───────▼────────┐  if XDG_CURRENT_DESKTOP is not GNOME:
 │ detect_desktop │   • warn user and ask to install GNOME Shell alongside
 │                │     existing DE (display manager is NOT changed)
 │                │   • if declined: set GNOME_SKIP_SETTINGS=true,
 │                │     skip extensions, skip GNOME-specific gsettings
 │                │  then: capture GNOME Shell version
 └───────┬────────┘
         │
 ┌───────▼────────┐
 │ install_prereqs│  dnf | apt | pacman with the right package list
 └───────┬────────┘
         │
 ┌───────▼────────┐
 │ install_flatpak│  install flatpak + add Flathub user remote
 └───────┬────────┘
         │
 ┌───────▼────────┐  PRE-FLIGHT:
 │                │   • set disable-extension-version-validation = true
 │ install_       │   • disable ubuntu-dock & dash-to-panel if active
 │  extensions    │  THEN per extension:
 │                │   • query extensions.gnome.org/extension-info for
 │                │     a build matching the detected shell version
 │                │   • parse JSON with grep (no jq dependency)
 │                │   • download .zip, install with `gnome-extensions
 │                │     install --force`, enable via dconf
 │                │   • verify enable wrote the dconf flag
 │                │  (skipped entirely on non-GNOME installs)
 └───────┬────────┘
         │
 ┌───────▼────────┐
 │ install_       │  git clone + run upstream install.sh with flags;
 │  whitesur_*    │  optional libadwaita / GDM hooks gated on confirmation
 └───────┬────────┘
         │
 ┌───────▼────────┐  Detects which extension schemas are *registered*
 │ apply_settings │  before writing keys (avoids silent no-ops when
 │                │  the shell hasn't loaded an extension yet).
 │                │  On non-GNOME installs: applies only gtk-theme,
 │                │  icon-theme, cursor-theme, button-layout.
 └───────┬────────┘
         │
 ┌───────▼────────┐  Downloads Orange-Dark.png to ~/.local/share/backgrounds/
 │  set_wallpaper │  Sets it via GNOME and Cinnamon gsettings schemas.
 └───────┬────────┘
         │
 ┌───────▼────────┐  (GNOME only) writes
 │ setup_post_    │  ~/.config/autostart/macos-ify-post-login.desktop
 │  login_        │  (a self-deleting wrapper that calls --post-login --yes
 │  autostart     │  on first login, then removes the autostart entry)
 └───────┬────────┘
         │
 ┌───────▼────────┐
 │    summary     │  print state
 └───────┬────────┘
         │
 ┌───────▼────────┐  (GNOME only) prompt then sudo reboot
 │   do_reboot    │  Non-GNOME installs skip the reboot and prompt
 └────────────────┘  the user to log out and back in instead.

 ━━━━━━━━━━━━━━━━━━━ system reboots; user logs into GNOME ━━━━━━━━━━━━━━━━━

 ┌────────────────┐
 │  --post-login  │  triggered automatically by XDG autostart on first login;
 │  (autostart)   │  re-runs apply_settings and set_wallpaper now that
 │                │  extension schemas are registered; verifies which
 │                │  extensions loaded; removes the autostart entry when done.
 └────────────────┘
```

The `run` wrapper logs every command and respects `--dry-run`. All upstream repos are cloned shallowly (`--depth=1`) under `~/.cache/macos-ify/` and re-pulled on subsequent runs.

---

## Caveats and limitations

These are real, and you should read them before running.

### The script changes more than just themes

Two GNOME-wide settings get flipped that are easy to miss:

- **`disable-extension-version-validation` is set to `true`.** This is required for Dash to Dock and similar extensions to load on newer GNOME releases (extension authors lag behind GNOME's 6-month cadence). The downside: an extension that's actually broken on your shell version will now still try to load and may misbehave instead of being silently skipped.
- **Conflicting docks are disabled.** If `ubuntu-dock@ubuntu.com` (Ubuntu/Pop/Zorin) or `dash-to-panel@jderose9.github.com` is active, the script disables it before enabling Dash to Dock. If you used either intentionally, that's a behavior change — re-enable manually after install if you want it back.

Neither change is reverted by WhiteSur's uninstall scripts. The [Uninstall](#uninstall) section below has the full reset commands.

### libadwaita is the elephant in the room

Since GNOME 43, built-in apps (Settings, Files, Calendar, Contacts, Weather, etc.) use **libadwaita**, which intentionally does not support custom themes. WhiteSur's "fix" — applied with `install.sh -l` — overwrites `~/.config/gtk-4.0/{gtk.css,gtk-dark.css}` to force the theme. Consequences:

- Only **one** theme can be active at a time (no per-app or system dark/light switching for those apps).
- A GNOME upgrade or a new libadwaita release can break it overnight.
- If you ever switch to a different theme, you must re-run `install.sh -l` to overwrite the override.

If you want a system that *stays* coherent through updates, run with `--no-libadwaita`. Your stock GNOME apps will keep their default look, but they won't randomly break.

### GNOME extensions need a shell restart

The script installs and enables extensions, but on Wayland (the default on Fedora 36+, Ubuntu 21.04+, etc.) the running shell can't reload extensions without a full session restart. The script handles this automatically by rebooting at the end and registering a one-time XDG autostart entry that runs `--post-login` on first login.

If you skipped the reboot or need to re-apply settings manually:

- **Wayland**: log out and back in, then run `./macos-ify.sh --post-login`.
- **X11**: `Alt+F2`, type `r`, press Enter, then run `./macos-ify.sh --post-login`.

Until extensions are loaded, the Shell theme, dock, and blur effects will not appear.

### Extension version drift

When a major GNOME version drops (44 → 45, 45 → 46, etc.), extensions break en masse and need updates. This script queries the extensions.gnome.org API for builds matching your shell version. If no compatible build exists yet, the script will warn and skip that extension — you'll get a partially themed result. Check back in a few weeks.

### Non-GNOME desktops get a partial result

The WhiteSur GTK theme, icons, cursors, and wallpaper all work on Cinnamon, XFCE, KDE, and others. GNOME Shell extensions and Shell-specific gsettings (dock, blur, top bar theme) are skipped. You'll need to apply the WhiteSur theme manually through your desktop's Appearance or Tweaks settings after the script finishes.

### What it can't make look like macOS

- The system font (set GNOME's font to Inter or SF Pro Display manually if you want closer)
- Window animations (those are GNOME's, not theme-able)
- Mission Control, Stage Manager, Spotlight (different paradigms entirely)
- App-specific UIs (anything Electron, anything Qt, anything that ships its own theme)

If you want a *truly* macOS-faithful Linux desktop, consider KDE Plasma with a macOS layout. GNOME + WhiteSur gets you maybe 75% of the way; KDE can get to ~90%.

---

## Troubleshooting

### Dash to Dock isn't appearing after I logged in

This is the single most common failure mode. Diagnose in this order:

**1. Did the system reboot?** The script reboots automatically when done. On Wayland (Fedora's default), GNOME Shell will not load newly installed extensions until the session restarts — a reboot satisfies this. If you cancelled the reboot prompt, run `sudo reboot` now, then log back in.

**2. Is the extension loaded?**
```bash
gnome-extensions list --enabled | grep dash-to-dock
```
If empty, the extension is installed but not enabled. Enable it:
```bash
gnome-extensions enable dash-to-dock@micxgx.gmail.com
```
Log out / log in again.

**3. Is version validation rejecting it?** The script disables this by default, but verify:
```bash
gsettings get org.gnome.shell disable-extension-version-validation
# Should print: true
```
If `false`, set it and log out/in:
```bash
gsettings set org.gnome.shell disable-extension-version-validation true
```

**4. Is a competing dock enabled?** Ubuntu/Pop/Zorin ship `ubuntu-dock@ubuntu.com`, a Dash to Dock fork. Both enabled simultaneously means neither works correctly:
```bash
gnome-extensions list --enabled | grep -E 'dock|panel'
gnome-extensions disable ubuntu-dock@ubuntu.com  # if present
```

**5. Did the post-login autostart run?** After the reboot, a one-time autostart job fires on your first login to finalize dock position/size/transparency. If it didn't run (e.g. it was deleted or you skipped the reboot), run it manually:
```bash
./macos-ify.sh --post-login
```
That step writes ~10 gsettings keys that only take effect once the extension's schema is registered (which happens after the shell loads it).

**6. Check the extension's actual state:**
```bash
gnome-extensions info dash-to-dock@micxgx.gmail.com
```
If `State: ERROR` or `State: OUT_OF_DATE`, the extension is actively broken on your GNOME version. You'll need to wait for an upstream update — or use [Dash to Panel](https://extensions.gnome.org/extension/1160/dash-to-panel/) as a substitute.

### I installed on Linux Mint / Cinnamon and the theme isn't active

The script applies gsettings keys for the theme, but Cinnamon may not pick them up automatically. Open **System Settings → Themes** and set:

- Controls: `WhiteSur-Dark` (or Light)
- Icons: `WhiteSur`
- Mouse pointer: `WhiteSur-cursors`

Then log out and back in.

### "ERROR: Unrecognized installation option '-i'" (or similar)

WhiteSur's `install.sh` does **not** accept `-i` as a top-level flag. The Activities-icon variant lives in a sub-namespace gated by `--shell` / `--gnomeshell`. The correct upstream invocation is:

```bash
./install.sh --shell -i apple
```

The macos-ify script handles this correctly (two separate calls). If you see this error from a previous version of macos-ify, pull the latest.

### "user-themes extension not enabled — Shell theme not applied"

Log out and back in, then re-run with `--no-extensions` (so the script skips re-downloading) — it will reapply the gsettings keys with the extension now active.

### Top bar still looks stock after logout/login

Open the **Extensions** app and verify *User Themes* is toggled on. Then in **GNOME Tweaks → Appearance**, set Shell to a `WhiteSur-*` value. If "Shell" is greyed out, User Themes isn't enabled.

### Settings app is themed but looks wrong / partially broken

That's the libadwaita override. Either accept it as-is, or run:

```bash
~/.cache/macos-ify/WhiteSur-gtk-theme/install.sh -r
rm -rf ~/.config/gtk-4.0
```

Log out and back in. Settings will return to stock libadwaita.

### Dash to Dock didn't install

Most likely the upstream extension hasn't published a build for your GNOME version yet. Check:

```bash
gnome-shell --version
curl -s "https://extensions.gnome.org/extension-info/?pk=307&shell_version=$(gnome-shell --version | awk '{print $3}' | cut -d. -f1)"
```

If the response is empty, wait for an upstream release or use Dash to Panel as an alternative.

### "Could not find dynamic library libsass"

You're missing `sassc` or its dev headers. Install manually:

- Fedora: `sudo dnf install sassc glib2-devel`
- Debian/Ubuntu: `sudo apt install sassc libglib2.0-dev-bin`
- Arch: `sudo pacman -S sassc glib2`

### GDM theming broke my login screen

Boot into a recovery TTY (Ctrl+Alt+F2), log in, and run:

```bash
sudo ~/.cache/macos-ify/WhiteSur-gtk-theme/tweaks.sh -g -r
```

Reboot. GDM will return to the stock theme.

### Everything's broken, nuke it

See [Uninstall](#uninstall).

---

## Uninstall

The repos are cached under `~/.cache/macos-ify/`. Each component's installer has a `-r` (remove) flag:

```bash
# Remove themes
~/.cache/macos-ify/WhiteSur-gtk-theme/install.sh -r
~/.cache/macos-ify/WhiteSur-icon-theme/install.sh -r
~/.cache/macos-ify/WhiteSur-cursors/install.sh -r

# Remove GDM theme (only if you used --gdm)
sudo ~/.cache/macos-ify/WhiteSur-gtk-theme/tweaks.sh -g -r

# Remove libadwaita override
rm -rf ~/.config/gtk-4.0

# Remove custom wallpaper
rm -f ~/.local/share/backgrounds/Orange-Dark.png

# Reset interface settings to GNOME defaults
gsettings reset org.gnome.desktop.interface gtk-theme
gsettings reset org.gnome.desktop.interface icon-theme
gsettings reset org.gnome.desktop.interface cursor-theme
gsettings reset org.gnome.desktop.interface color-scheme
gsettings reset org.gnome.desktop.wm.preferences button-layout
gsettings reset org.gnome.desktop.background picture-uri
gsettings reset org.gnome.desktop.background picture-uri-dark

# Reset the version-validation flag the script flipped
gsettings reset org.gnome.shell disable-extension-version-validation

# Disable / remove the extensions installed by the script
gnome-extensions disable user-theme@gnome-shell-extensions.gcampax.github.com
gnome-extensions disable dash-to-dock@micxgx.gmail.com
gnome-extensions disable blur-my-shell@aunetx
gnome-extensions uninstall dash-to-dock@micxgx.gmail.com
gnome-extensions uninstall blur-my-shell@aunetx

# Re-enable Ubuntu Dock if you're on Ubuntu/Pop/Zorin and want it back
gnome-extensions enable ubuntu-dock@ubuntu.com 2>/dev/null || true

# Reset extension-specific dconf trees (cleans dock/blur settings)
dconf reset -f /org/gnome/shell/extensions/dash-to-dock/
dconf reset -f /org/gnome/shell/extensions/blur-my-shell/
dconf reset -f /org/gnome/shell/extensions/user-theme/

# Remove cached repos and logs
rm -rf ~/.cache/macos-ify
```

Log out and back in.

---

## Customization

### Add a new distro family

Edit the `detect_distro()` function. The pattern is:

```bash
case "$DISTRO_ID" in
    yourdistro|relateddistro)
        DISTRO_FAMILY="yourfamily"; PKG_MGR="yourmgr" ;;
    ...
```

Then add a matching branch in `pkg_install()` and a package list in `install_prereqs()`.

### Add or remove extensions

Edit the `EXTENSIONS` array near the top:

```bash
EXTENSIONS=(
    "user-themes|19"
    "dash-to-dock|307"
    "blur-my-shell|3193"
    "your-extension|XXXX"      # add yours
)
```

The number is the extension ID from the URL on extensions.gnome.org (`/extension/XXXX/name/`).

### Change dock behavior

Edit the `gsettings set org.gnome.shell.extensions.dash-to-dock ...` lines in `apply_settings()`. The full schema is in `/usr/share/glib-2.0/schemas/org.gnome.shell.extensions.dash-to-dock.gschema.xml`.

### Use a different theme

The script is hardcoded to WhiteSur, but the structure (clone → run upstream installer → gsettings) is generic. Replace the URLs in `install_whitesur_*` functions with another vinceliuice theme:

- `Fluent-gtk-theme`
- `McMojave-gtk-theme`
- `Orchis-theme`

Then update the `theme_name` variable in `apply_settings()` accordingly.

---

## Credits

This script is a wrapper around the work of:

- **[vinceliuice](https://github.com/vinceliuice)** — author and maintainer of WhiteSur, McMojave, Fluent, Orchis, and most of the polished macOS-styled GTK themes for Linux. If you use this script, [buy them a coffee](https://ko-fi.com/vinceliuice).
- **[Simon Schneegans](https://github.com/Schneegans)** — maintainer of Burn-My-Windows, Desktop Cube, and other GNOME Shell effects that pair well with WhiteSur.
- **[micheleg](https://github.com/micheleg)** and the Dash to Dock contributors.
- **[aunetx](https://github.com/aunetx)** — author of Blur My Shell.
- The **GNOME Shell Extensions** team for keeping a usable JSON API at extensions.gnome.org.

---

## Contributing

PRs welcome for:

- openSUSE/zypper support
- Void/xbps support
- KDE Plasma equivalent (would require a separate script — different theme engine)
- Better libadwaita handling once upstream lands a real solution
- Internationalization of log messages

Please run `shellcheck --severity=warning macos-ify.sh` clean before opening a PR.

---

## License

MIT. The bundled WhiteSur components retain their own licenses (GPL-3.0 for most). See each repo for details.

---

## Disclaimer

This script modifies system files when run with `--gdm`, overwrites `~/.config/gtk-4.0` when run with default flags, and changes a number of dconf settings. It has been written defensively and tested on common distros, but **you are responsible for your own system**. Always run with `--dry-run` first. Always have a backup. If you don't know what `gsettings` is, learn before running.
