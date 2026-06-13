<p align="center">
  <img src="macos-ify-logo.png" alt="macos-ify logo" width="480">
</p>

# MacOS-ify

> A single bash script that detects your Linux distribution and makes your desktop look like macOS using the [WhiteSur](https://github.com/vinceliuice/WhiteSur-gtk-theme) theme suite — from a terminal or from a built-in graphical installer.

[![Shell](https://img.shields.io/badge/shell-bash-1f425f.svg)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](#license)
[![Distros](https://img.shields.io/badge/distros-Fedora%2FRHEL%20%7C%20Debian%2FUbuntu%20%7C%20Arch-orange.svg)](#supported-systems)

`macos-ify` automates the tedious parts of skinning a Linux desktop to look like macOS: detecting your distro, installing prerequisites with the correct package manager, pulling and building WhiteSur (GTK theme, icons, cursors, wallpapers), installing the Inter UI font, adding the right GNOME Shell extensions for your shell version, and applying everything via `gsettings`. It can run as a plain terminal script or launch a **GTK graphical installer** (`--gui`) with the same options as buttons and live install output.

The WhiteSur theme pack (GTK theme, icons, cursors, wallpaper) installs and works on **any** supported desktop environment. The full macOS experience — top bar, animated dock, blurred panels, Spotlight-style search — requires GNOME Shell. On non-GNOME desktops the script offers to add GNOME alongside your existing DE; if you decline it applies the themes only.

It is **not** magic. It is a wrapper around well-maintained upstream projects with sensible defaults, real error handling, and an honest set of warnings about what it cannot do.

---

## Table of contents

- [Features](#features)
- [Supported systems](#supported-systems)
- [Quick start](#quick-start)
- [The graphical installer](#the-graphical-installer)
- [Usage](#usage)
- [Examples](#examples)
- [What it installs](#what-it-installs)
- [How it works](#how-it-works)
- [Caveats and limitations](#caveats-and-limitations)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Credits](#credits)
- [License](#license)

---

## Features

- **One file, two front-ends.** Run it in a terminal, or pass `--gui` for a GTK installer. The GUI is embedded inside the same `.sh` file — there is nothing else to download.
- **Distro auto-detection** via `/etc/os-release` with `ID_LIKE` fallback. No need to tell it what you're running.
- **Package-manager abstraction.** Same script, same flags, works across `dnf`, `apt`, and `pacman`.
- **Per-distro package-name resolution.** Packages that are named differently (or removed) on a given release are resolved correctly; missing *optional* packages warn and continue instead of aborting.
- **GNOME Shell version awareness.** Queries the official extensions.gnome.org API to fetch only extension builds compatible with your installed GNOME version.
- **Tiered extensions.** A small, reliable core set by default; a fuller macOS treatment behind `--extras`, opt-in per extension via `--extras-only`.
- **Inter UI font** installed and applied by default (the single biggest visual tell), with a GitHub fallback if your distro doesn't package it.
- **Quick Look** (`gnome-sushi`) for spacebar file previews, like Finder.
- **Optional Cmd-style keyboard** (`--keyboard`, via [Toshy](https://github.com/RedBearAK/toshy)).
- **Robust failure reporting.** An `ERR` trap names the exact failing command and line instead of a bare exit code. Logs are timestamped to `~/.cache/macos-ify/install.log` (rotated, not clobbered).
- **Dry-run mode.** Print every command without touching anything.
- **Confirmation prompts** on destructive operations, with `--yes` for unattended runs.
- **Honest about what it can't do.** See [Caveats](#caveats-and-limitations).

---

## Supported systems

| Family       | Distros                                                                    | Package manager |
|--------------|----------------------------------------------------------------------------|-----------------|
| RHEL-based   | Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux                              | `dnf`           |
| Debian-based | Debian, Ubuntu, Linux Mint, Pop!_OS, elementary OS, Zorin OS, Kali, Parrot | `apt`           |
| Arch-based   | Arch, Manjaro, EndeavourOS, Garuda                                         | `pacman`        |

**Desktop environment:** GNOME Shell 42 or newer is required for the full macOS experience (top bar, dock, blur, animations). Some extras (Rounded Window Corners) require GNOME 46+ and are skipped automatically on older shells. If a non-GNOME desktop is detected, the script offers to install GNOME Shell alongside it — your existing DE and display manager are left untouched. WhiteSur themes, icons, cursors, and wallpaper install and work on any desktop.

> **A note on RHEL 10 / Rocky 10 / AlmaLinux 10:** RHEL 10 removed several GTK2-era packages from its base repositories, including `gnome-tweaks`, the murrine theme engine, and `gnome-themes-extra`. These are **optional** — the script installs them best-effort and continues without them (WhiteSur compiles via `sassc`, which is required and present). `gnome-tweaks` on EL10 can be installed via Flatpak (`flatpak install flathub org.gnome.tweaks`) if you want it; its settings otherwise live in GNOME Settings.

> **Non-GNOME installs (e.g. Linux Mint / Cinnamon):** On Debian-based systems, `apt` will prompt you to choose a default display manager during the GNOME Shell install. **You must select gdm3.** Choosing `lightdm` will prevent GNOME from loading correctly.

**Display server:** Both Wayland (default on most modern distros) and X11 are supported. On GNOME installs the script reboots so extensions activate on first login; a one-time autostart job finalizes extension-dependent settings after that login. On non-GNOME installs (themes only) no reboot is triggered — log out and back in instead.

**Not supported:** openSUSE/SLES (`zypper`), Void (`xbps`), Gentoo (`portage`), Alpine, NixOS. PRs welcome.

---

## Quick start

```bash
# Clone the repo
git clone https://github.com/BushidoCyb3r/MacOS-ify.git
cd MacOS-ify
chmod +x macos-ify.sh

# Graphical installer (recommended)
./macos-ify.sh --gui

# ...or terminal, with a dry run first
./macos-ify.sh --dry-run
./macos-ify.sh
```

**On GNOME:** the script reboots when done. A one-time autostart job runs automatically on first login to finalize extension-dependent settings (dock position, blur, shell theme), then removes itself.

**On non-GNOME (themes only):** no reboot is triggered. Log out and back in for the WhiteSur theme to take effect, then select it in your desktop's Appearance or Tweaks tool.

```bash
# Re-apply GNOME settings manually after login if needed:
./macos-ify.sh --post-login
```

---

## The graphical installer

`./macos-ify.sh --gui` launches a GTK3 front-end. There is no separate file to install — the Python GUI is embedded in the script and extracted to `~/.cache/macos-ify/` at launch, so it always matches the script version. If the GTK/PyGObject bindings are missing, the script installs them first (`python3-gi`/`python3-gobject` + GTK3 introspection, per distro).

The GUI presents:

- **Theme** — dark/light and accent color.
- **Options** — Inter font, Quick Look, libadwaita theming, GDM login-screen theming, Cmd-style keyboard (Toshy), and dry-run, as checkboxes.
- **Extras** — each extension (Apple menu, Spotlight search, tray icons, panel tweaks, genie minimize, rounded corners, Cmd-style app switching) as a toggle, plus Select All.
- **Wallpaper** — Orange / Green / Blue / Purple, with live image previews.

Clicking **Install** streams the real installer output into a console view. The GUI handles privilege escalation and interactive prompts itself:

- **sudo password** is requested once via a dialog and supplied to the installer over a pseudo-terminal. It is held in memory only for the duration of the run and never written to disk or passed on a command line.
- **Interactive third-party prompts** (for example, Toshy's installer asking questions) are detected when the installer blocks on input; an input bar appears in the GUI so you can answer them, just like a terminal.

When finished, a Reboot button (which prompts for your password) and a View Output button are shown.

> The GUI runs the installer non-interactively (`--yes --no-reboot`) and adds its own reboot control. Everything the GUI does is also doable from the terminal with the flags below.

---

## Usage

```text
Usage: macos-ify.sh [OPTIONS]

Theme options:
  -a, --accent COLOR     Theme accent
                         (default|blue|purple|pink|red|orange|yellow|green|grey)
                         [default: default]
  -c, --color VARIANT    light | dark                  [default: dark]
  -i, --icon VARIANT     Activities-icon variant
                         (apple|simple|gnome|fedora|ubuntu|arch|...)  [default: apple]
      --gdm              Also theme the GDM login screen (requires sudo)
      --no-libadwaita    Skip the libadwaita override (safer; Settings/Files/Calendar
                         keep the stock GNOME look but won't break on upgrades)
      --no-extensions    Skip GNOME extension installation
      --no-wallpapers    Skip WhiteSur wallpaper pack download

Behavior options:
      --extras           Install the extended extension set (see table below)
                         plus macOS-style app switching (Super+Tab = apps,
                         Super+` = windows of the current app)
      --extras-only LIST Install only the named extras (comma-separated). Names:
                         logo-menu, search-light, appindicator-support,
                         just-perfection, compiz-alike-magic-lamp-effect,
                         rounded-window-corners-reborn, app-switcher
                         ('app-switcher' = the Super+Tab keybinds only)
      --keyboard         Install Toshy for system-wide Cmd-style shortcuts
                         (Cmd+C/V/W/T/Q...). Runs Toshy's own installer; adds
                         systemd user services and udev rules. Opt-in.
      --no-font          Skip installing/applying the Inter UI font
      --no-quicklook     Skip GNOME Sushi (spacebar file previews in Files)

Run modes:
      --gui              Launch the embedded GTK graphical installer
      --wallpaper N      Wallpaper choice 1-4 (Orange/Green/Blue/Purple);
                         skips the interactive prompt
      --no-reboot        Don't reboot at the end (the GUI uses this)
      --post-login       Finalize-only mode: re-applies dock position, button
                         layout, blur, shell theme, and wallpaper. Auto-run via
                         XDG autostart on first login; can also be run manually.
  -y, --yes              Assume yes to every confirmation prompt
  -n, --dry-run          Print every command without changing anything
  -h, --help             Show help and exit
```

### Risk reference

| Flag                | What it controls                                                   | Risk           |
|---------------------|--------------------------------------------------------------------|----------------|
| `-a` / `-c` / `-i`  | Theme accent / light-dark / Activities icon                        | None           |
| `--extras` / `--extras-only` | Extra extensions + app-switching keybinds                 | Low–Medium     |
| `--keyboard`        | Toshy: systemd user services, udev rules, `input` group membership | **Higher**     |
| `--no-font`         | Skip Inter font                                                    | Reduces effect |
| `--no-quicklook`    | Skip gnome-sushi previews                                          | Reduces effect |
| `--gdm`             | Theme GDM login screen — modifies system files via sudo            | Medium         |
| `--no-libadwaita`   | Don't overwrite `~/.config/gtk-4.0`                                | Reduces risk   |
| `--no-extensions`   | Don't install any extensions                                       | Reduces effect |
| `--no-wallpapers`   | Don't clone the WhiteSur wallpaper pack                            | None           |
| `--wallpaper N`     | Preselect wallpaper, skip prompt                                   | None           |
| `--no-reboot`       | Skip the final reboot                                              | None           |
| `--post-login`      | Re-apply gsettings only                                            | None           |
| `-y, --yes`         | Skip all prompts (combine with `--gdm`/`--keyboard` carefully)     | Higher         |
| `-n, --dry-run`     | Plan-only mode                                                     | None           |

---

## Examples

```bash
# Graphical installer
./macos-ify.sh --gui

# Sensible default: dark theme, Inter font, Quick Look, core extensions
./macos-ify.sh

# The full macOS treatment (Spotlight, Apple menu, genie effect, etc.)
./macos-ify.sh --extras

# Everything, including Cmd-style keyboard, no prompts
./macos-ify.sh --extras --keyboard -y

# Only a couple of extras
./macos-ify.sh --extras-only logo-menu,search-light,app-switcher

# Light theme, blue accent, theme the login screen, no prompts
./macos-ify.sh -c light -a blue --gdm -y

# Conservative: no libadwaita override, no font, blue wallpaper
./macos-ify.sh --no-libadwaita --no-font --wallpaper 3

# Plan-only — see every command that would run
./macos-ify.sh --extras -n
```

---

## What it installs

### System packages

Prerequisites are split into **required** (the run stops if these fail) and **optional** (best-effort; a missing or renamed package warns and continues).

| Family   | Required                          | Optional (best-effort)                                                        |
|----------|-----------------------------------|-------------------------------------------------------------------------------|
| RHEL     | `git curl unzip sassc glib2-devel`| `gnome-tweaks gnome-extensions-app gtk-murrine-engine gnome-themes-extra`      |
| Debian   | `git curl unzip sassc libglib2.0-dev-bin` | `gnome-tweaks gnome-shell-extension-manager gtk2-engines-murrine gnome-themes-extra` |
| Arch     | `git curl unzip sassc glib2`      | `gnome-tweaks gtk-engine-murrine gnome-themes-extra`                           |

Some optional packages do not exist on every release (notably on RHEL 10 — see [Supported systems](#supported-systems)). The murrine engine only matters at runtime for GTK2 apps, which are essentially absent on a modern GNOME desktop, so its absence is harmless. `imagemagick` is additionally installed (best-effort) only when Search Light is selected. `flatpak` is installed and the Flathub user remote added (best-effort).

For `--gui`, GTK3 + PyGObject are installed if missing: `python3-gi gir1.2-gtk-3.0` (Debian), `python3-gobject gtk3` (RHEL), `python-gobject gtk3` (Arch).

### Inter UI font

Installed from the distro package where available (`fonts-inter` on Debian, `rsms-inter-fonts` on Fedora/EPEL, `inter-font` on Arch). If the package isn't available (e.g. RHEL 10), it falls back to the upstream GitHub release — the API first, then a pinned release URL if the API is rate-limited — installed under `~/.local/share/fonts`. The font is only applied via gsettings once it's confirmed visible to fontconfig.

### GNOME (if not already installed)

On non-GNOME systems, if you confirm, the script installs `gnome-shell` and `gnome-session`. Your existing display manager is **not** replaced. On Debian-based systems `apt` will prompt for a display manager — **select gdm3**. After rebooting, choose the GNOME session from your login screen.

### GNOME Shell extensions

Pulled from extensions.gnome.org with version-matched downloads. **Core** (always, unless `--no-extensions`):

| Extension     | ID   | Why                                                   |
|---------------|------|-------------------------------------------------------|
| User Themes   | 19   | Required to apply a Shell (top bar) theme at all      |
| Dash to Dock  | 307  | macOS-style bottom dock with intelligent autohide     |
| Blur My Shell | 3193 | Translucent / blurred top bar and overview            |
| Desktop Cube  | 4648 | Spaces-like workspace movement                        |

**Extras** (`--extras`, or individually via `--extras-only`):

| Extension                         | ID   | Provides                                  | Notes        |
|-----------------------------------|------|-------------------------------------------|--------------|
| Logo Menu                         | 4451 | Apple-style menu, top-left                |              |
| Search Light                      | 5489 | Spotlight-style floating search popup     |              |
| AppIndicator Support              | 615  | Menu-bar style tray icons                 |              |
| Just Perfection                   | 3843 | Panel / clock / UI element control        |              |
| Compiz-alike Magic Lamp Effect    | 3740 | Genie minimize animation                  |              |
| Rounded Window Corners Reborn     | 7048 | Rounds all window corners                 | GNOME 46+    |

`--extras` (and `--extras-only ...,app-switcher`) also sets macOS-style switching: **Super+Tab** cycles applications, **Super+`** cycles windows of the current app.

### WhiteSur components (cloned to `~/.cache/macos-ify/`)

| Repo | Provides |
|------|----------|
| [`vinceliuice/WhiteSur-gtk-theme`](https://github.com/vinceliuice/WhiteSur-gtk-theme) | GTK3/GTK4 theme, optional GDM theme |
| [`vinceliuice/WhiteSur-icon-theme`](https://github.com/vinceliuice/WhiteSur-icon-theme) | macOS-style icon set |
| [`vinceliuice/WhiteSur-cursors`](https://github.com/vinceliuice/WhiteSur-cursors) | macOS-style cursors |
| [`vinceliuice/WhiteSur-wallpapers`](https://github.com/vinceliuice/WhiteSur-wallpapers) | Wallpaper pack |

### dconf / gsettings keys modified

```
org.gnome.shell                               disable-extension-version-validation → true
                                              enabled-extensions → adds core (+ extra) entries
org.gnome.desktop.interface                   gtk-theme        → WhiteSur-{Light|Dark}[-accent]
org.gnome.desktop.interface                   icon-theme       → WhiteSur
org.gnome.desktop.interface                   cursor-theme     → WhiteSur-cursors
org.gnome.desktop.interface                   color-scheme     → prefer-{light|dark}
org.gnome.desktop.interface                   font-name        → Inter 11           (if font applied)
org.gnome.desktop.interface                   document-font-name → Inter 11         (if font applied)
org.gnome.desktop.wm.preferences              titlebar-font    → Inter Bold 11      (if font applied)
org.gnome.desktop.wm.preferences              button-layout    → close,minimize,maximize:
org.gnome.desktop.wm.keybindings              switch-applications / switch-group … (with --extras app-switcher)
org.gnome.desktop.background                  picture-uri[-dark] → file://…/<color>-Dark.png
org.gnome.shell.extensions.user-theme         name             → WhiteSur-{Light|Dark}[-accent]
org.gnome.shell.extensions.dash-to-dock        (dock-position BOTTOM, intellihide, icon size, dots, …)
org.gnome.shell.extensions.blur-my-shell.panel (blur, static-blur)
org.cinnamon.desktop.* (interface font, background)              (Cinnamon equivalents, harmless elsewhere)
```

### Other GNOME Shell state changed

- **Disables `ubuntu-dock@ubuntu.com`** and **`dash-to-panel@jderose9.github.com`** if active (competing docks; both + Dash to Dock means neither displays correctly).
- **Sets `disable-extension-version-validation=true`** so extensions whose `metadata.json` doesn't list your exact GNOME version still load.

These are not undone by WhiteSur's uninstallers. See [Uninstall](#uninstall).

---

## How it works

```
detect_distro      parse /etc/os-release → DISTRO_FAMILY, PKG_MGR
        │
        ├── --gui? → install GTK/PyGObject if needed, extract the embedded
        │            Python payload to ~/.cache/macos-ify/, exec it. The GUI
        │            collects options and re-invokes this script with flags.
        │
detect_desktop     if not GNOME: offer to install gnome-shell alongside the
        │          current DE (display manager untouched); if declined, skip
        │          extensions and GNOME-only gsettings. Capture shell version.
        │
install_prereqs    required packages (fatal on failure) + optional packages
        │          (best-effort, one at a time so a missing name only warns)
        │
install_font       distro package → GitHub fallback (API, then pinned URL)
install_quicklook  gnome-sushi (best-effort)
install_extensions version-matched downloads from extensions.gnome.org; core,
        │          plus selected extras; disables conflicting docks first
install_whitesur_* git clone + run upstream install.sh; libadwaita / GDM hooks
        │          gated on confirmation
install_keyboard   (--keyboard) clone + run Toshy's interactive installer
apply_settings     writes gsettings only for schemas that are registered
set_wallpaper      downloads the chosen wallpaper and sets it
setup_post_login_autostart  (GNOME) one-shot XDG autostart → --post-login on
        │          first login, then self-deletes
do_reboot          (GNOME, unless --no-reboot) prompt then reboot
```

The whole thing is a single file. The GUI is stored as an inert heredoc payload after the script's `exit`, so bash never executes it and `shellcheck` parses the file cleanly; `--gui` extracts and runs it. An `ERR` trap reports the failing command and line. The `run` wrapper logs every command and respects `--dry-run`. Upstream repos are cloned shallowly under `~/.cache/macos-ify/` and re-pulled on subsequent runs.

---

## Caveats and limitations

These are real. Read them before running.

### The script changes more than just themes

- **`disable-extension-version-validation` is set to `true`.** Required for Dash to Dock and friends to load on newer GNOME (authors lag GNOME's 6-month cadence). Downside: an extension that's genuinely broken on your shell will try to load and may misbehave rather than being skipped.
- **Conflicting docks are disabled.** `ubuntu-dock` / `dash-to-panel` are disabled before enabling Dash to Dock. If you used either intentionally, re-enable it afterward.

Neither is reverted by WhiteSur's uninstall scripts. See [Uninstall](#uninstall).

### libadwaita is the elephant in the room

Since GNOME 43, built-in apps (Settings, Files, Calendar, etc.) use **libadwaita**, which intentionally doesn't support custom themes. WhiteSur's workaround (`install.sh -l`) overwrites `~/.config/gtk-4.0/{gtk.css,gtk-dark.css}`. Consequences: only one theme active at a time for those apps; a GNOME/libadwaita update can break it; switching themes later means re-running `install.sh -l`. Run with `--no-libadwaita` if you want a setup that stays coherent through updates.

### GNOME extensions need a shell restart

On Wayland (the default nearly everywhere now) the running shell can't load new extensions without a full session restart. The script reboots at the end and registers a one-time autostart entry that runs `--post-login` on first login. If you skipped the reboot: log out/in (Wayland) or `Alt+F2` → `r` (X11), then `./macos-ify.sh --post-login`. Until then, the Shell theme, dock, and blur won't appear.

### Extension version drift

When a major GNOME version drops, extensions break en masse until updated. The script fetches builds matching your shell version; if none exists yet it warns and skips that extension, leaving a partial result. Check back in a few weeks. Rounded Window Corners requires GNOME 46+ and is skipped on older shells by design.

### Toshy (the `--keyboard` option) is heavy and interactive

Toshy installs systemd user services and udev rules, and adds your user to the `input` group. Its installer is **interactive and has no non-interactive flag** — it asks several questions (including some that show a code you must type back). In the terminal you answer normally; in the GUI an input bar appears for each prompt. It is removable via Toshy's own `uninstall`. It's opt-in for a reason; skip it if you only want the look.

### What it can't make look like macOS

- Window animations beyond what extensions provide (those are GNOME's).
- Mission Control, Stage Manager, true Spotlight (different paradigms; Search Light approximates Spotlight).
- App-specific UIs (Electron, Qt, anything that ships its own theme).

GNOME + WhiteSur gets you ~75% of the way. A KDE Plasma macOS layout can get closer if that's your goal.

---

## Troubleshooting

The single most useful thing: **read the `[FAIL]` line.** On any error the script prints `[FAIL] line N: command failed (exit X): <command>` and the full log is at `~/.cache/macos-ify/install.log`. In the GUI, click **View Output**.

### Dash to Dock isn't appearing after login

1. **Did the system reboot?** Wayland won't load new extensions until the session restarts. `sudo reboot`, then log in.
2. **Is it enabled?** `gnome-extensions list --enabled | grep dash-to-dock` — if empty, `gnome-extensions enable dash-to-dock@micxgx.gmail.com`, then log out/in.
3. **Version validation off?** `gsettings get org.gnome.shell disable-extension-version-validation` should be `true`.
4. **Competing dock?** `gnome-extensions list --enabled | grep -E 'dock|panel'` → `gnome-extensions disable ubuntu-dock@ubuntu.com`.
5. **Did the post-login job run?** `./macos-ify.sh --post-login`.
6. **Extension state:** `gnome-extensions info dash-to-dock@micxgx.gmail.com` — `ERROR`/`OUT_OF_DATE` means it's broken on your GNOME version; wait for an upstream update.

### Linux Mint / Cinnamon: theme isn't active

Open **System Settings → Themes** and set Controls `WhiteSur-Dark`, Icons `WhiteSur`, Mouse pointer `WhiteSur-cursors`, then log out/in.

### The GUI's Reboot button did nothing / failed

It prompts for your password and runs `sudo reboot`. If it reports a failure, just run `sudo reboot` in a terminal — your install is already on disk and the post-login job runs on next login regardless.

### A prompt appeared in the GUI and I don't know what it wants

That's a third-party installer (almost always Toshy) asking a question. Read the prompt text shown above the input bar — some prompts display a code you must type back exactly — type your answer and press Enter/Send.

### "No match for argument: <package>"

An optional package isn't in your distro's repos (common on RHEL 10 for the murrine engine, `gnome-themes-extra`, and `rsms-inter-fonts`). The script now treats these as best-effort and continues; the font falls back to GitHub. If you see this as a fatal `[FAIL]`, you're on an old version — pull the latest.

### "Could not find dynamic library libsass" / sassc errors

Install the required build dep: Fedora `sudo dnf install sassc glib2-devel`; Debian/Ubuntu `sudo apt install sassc libglib2.0-dev-bin`; Arch `sudo pacman -S sassc glib2`.

### GDM theming broke my login screen

Recovery TTY (Ctrl+Alt+F2), then `sudo ~/.cache/macos-ify/WhiteSur-gtk-theme/tweaks.sh -g -r` and reboot.

---

## Uninstall

Repos are cached under `~/.cache/macos-ify/`. Each component's installer has a `-r` flag.

```bash
# Themes / icons / cursors
~/.cache/macos-ify/WhiteSur-gtk-theme/install.sh -r
~/.cache/macos-ify/WhiteSur-icon-theme/install.sh -r
~/.cache/macos-ify/WhiteSur-cursors/install.sh -r

# GDM theme (only if you used --gdm)
sudo ~/.cache/macos-ify/WhiteSur-gtk-theme/tweaks.sh -g -r

# libadwaita override
rm -rf ~/.config/gtk-4.0

# Inter font (only if installed via the GitHub fallback)
rm -rf ~/.local/share/fonts/inter && fc-cache -f

# Wallpaper
rm -f ~/.local/share/backgrounds/*-Dark.png

# Reset interface + keybinding settings
gsettings reset org.gnome.desktop.interface gtk-theme
gsettings reset org.gnome.desktop.interface icon-theme
gsettings reset org.gnome.desktop.interface cursor-theme
gsettings reset org.gnome.desktop.interface color-scheme
gsettings reset org.gnome.desktop.interface font-name
gsettings reset org.gnome.desktop.wm.preferences button-layout
gsettings reset org.gnome.desktop.background picture-uri
gsettings reset org.gnome.desktop.background picture-uri-dark
gsettings reset org.gnome.shell disable-extension-version-validation
gsettings reset-recursively org.gnome.desktop.wm.keybindings   # if --extras app-switcher was used

# Disable / remove extensions installed by the script
for uuid in \
  user-theme@gnome-shell-extensions.gcampax.github.com \
  dash-to-dock@micxgx.gmail.com \
  blur-my-shell@aunetx \
  logomenu@aryan_k \
  search-light@icedman.github.com \
  appindicatorsupport@rgcjonas.gmail.com \
  just-perfection-desktop@just-perfection \
  compiz-alike-magic-lamp-effect@hermes83.github.com \
  rounded-window-corners@fxgn ; do
    gnome-extensions disable "$uuid" 2>/dev/null
    gnome-extensions uninstall "$uuid" 2>/dev/null
done
# Desktop Cube is also installed as a core extension; uninstall it too
# (run `gnome-extensions list | grep -i cube` to confirm its UUID on your system):
# gnome-extensions disable <cube-uuid> && gnome-extensions uninstall <cube-uuid>

# Re-enable Ubuntu Dock if you're on Ubuntu/Pop/Zorin and want it back
gnome-extensions enable ubuntu-dock@ubuntu.com 2>/dev/null || true

# Toshy (only if you used --keyboard)
~/.cache/macos-ify/toshy/setup_toshy.py uninstall

# Remove cached repos, the extracted GUI, and logs
rm -rf ~/.cache/macos-ify
```

Log out and back in.

---

## Credits

A wrapper around the work of:

- **[vinceliuice](https://github.com/vinceliuice)** — WhiteSur and the broader family of macOS-styled GTK themes. [Buy them a coffee.](https://ko-fi.com/vinceliuice)
- **[RedBearAK](https://github.com/RedBearAK)** — Toshy, the keymapper behind `--keyboard`.
- **[micheleg](https://github.com/micheleg)** and the Dash to Dock contributors.
- **[aunetx](https://github.com/aunetx)** — Blur My Shell.
- The authors of Logo Menu, Search Light, Just Perfection, AppIndicator Support, Magic Lamp, Rounded Window Corners, Desktop Cube, and rsms's Inter typeface.
- The GNOME Shell Extensions team for a usable JSON API at extensions.gnome.org.

---

## Contributing

PRs welcome for openSUSE/zypper support, Void/xbps support, additional extras, better libadwaita handling, and i18n of log messages.

Please run `shellcheck --severity=warning macos-ify.sh` clean before opening a PR. Note that the GUI Python lives in an embedded heredoc at the end of the script; if you edit it, extract it (`--gui` writes it to `~/.cache/macos-ify/macos-ify-gui.py`), edit and lint it there, and paste it back — and never put a line consisting solely of the payload marker inside the Python.

---

## License

MIT. Bundled WhiteSur components and the extensions retain their own licenses (GPL-3.0 for most). See each repo for details.

---

## Disclaimer

This script modifies system files with `--gdm`, overwrites `~/.config/gtk-4.0` by default, installs systemd services with `--keyboard`, and changes a number of dconf settings. It is written defensively with command-level failure reporting, but **you are responsible for your own system.** Run `--dry-run` first, keep a backup, and understand what `gsettings` is before running.
