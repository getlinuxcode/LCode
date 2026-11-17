#!/usr/bin/env bash
# LCode installer.
#
#   curl -fsSL https://raw.githubusercontent.com/getlinuxcode/LCode/master/install.sh | bash
#
# Installs the system dependencies (apt), Swift (through swiftly) if it is missing, then clones and
# builds LCode in ~/.local/share/lcode/src and adds the `lcode` and `lcode-ide` commands to
# ~/.local/bin, plus a desktop menu entry. Running it again updates LCode.
#
# Environment variables:
#   LCODE_DIR      where the sources are cloned (default: ~/.local/share/lcode/src)
#   LCODE_BRANCH   branch to install (default: master)
#   LCODE_REPO     repository URL (default: https://github.com/getlinuxcode/LCode.git)
#   LCODE_NO_APT=1 skip installing system packages

# Everything lives in main(), so a partially downloaded script never runs.
main() {
    set -euo pipefail

    local repo="${LCODE_REPO:-https://github.com/getlinuxcode/LCode.git}"
    local branch="${LCODE_BRANCH:-master}"
    local dir="${LCODE_DIR:-$HOME/.local/share/lcode/src}"
    local bin="$HOME/.local/bin"

    say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
    warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
    die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

    [ "$(uname -s)" = Linux ] || die "LCode currently runs on Linux only."
    case "$(uname -m)" in x86_64|aarch64) ;; *) die "unsupported architecture: $(uname -m)";; esac
    [ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root (sudo is used when needed)."

    # --- System packages -------------------------------------------------------------------------
    if [ "${LCODE_NO_APT:-0}" != 1 ]; then
        if command -v apt-get >/dev/null; then
            say "Installing system packages (sudo may ask for your password)…"
            local sudo=""
            [ "$(id -u)" -eq 0 ] || sudo="sudo"
            $sudo apt-get update -qq
            # GTK4 / libadwaita / GtkSourceView for the IDE, ffmpeg + paplay for media in the
            # simulator, then the Swift toolchain's own prerequisites.
            $sudo apt-get install -y -qq \
                git curl ca-certificates pkg-config \
                libgtk-4-dev libadwaita-1-dev libgtksourceview-5-dev \
                ffmpeg pulseaudio-utils \
                binutils gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libncurses-dev \
                libpython3-dev libsqlite3-0 libxml2-dev libz3-dev tzdata unzip zlib1g-dev \
                "libgcc-$(gcc_major)-dev" "libstdc++-$(gcc_major)-dev" >/dev/null
        else
            warn "apt-get not found: install GTK 4, libadwaita 1, GtkSourceView 5, ffmpeg, paplay,"
            warn "git and the Swift toolchain prerequisites with your package manager, then rerun"
            warn "with LCODE_NO_APT=1."
            die "unsupported distribution"
        fi
    fi

    # --- Swift -----------------------------------------------------------------------------------
    local swiftly_env="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
    # shellcheck disable=SC1090
    [ -f "$swiftly_env" ] && . "$swiftly_env"
    if ! command -v swift >/dev/null; then
        say "Installing Swift with swiftly…"
        local tmp
        tmp="$(mktemp -d)"
        curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" -o "$tmp/swiftly.tar.gz"
        tar -xzf "$tmp/swiftly.tar.gz" -C "$tmp"
        local platform_args=()
        local platform
        platform="$(swift_platform)"
        [ -n "$platform" ] && platform_args=(--platform "$platform")
        "$tmp/swiftly" init --assume-yes --quiet-shell-followup "${platform_args[@]}"
        rm -rf "$tmp"
        # shellcheck disable=SC1090
        . "$swiftly_env"
    fi
    command -v swift >/dev/null || die "swift is still not on PATH; open a new terminal and rerun."
    say "Using $(swift --version 2>/dev/null | head -1)"

    # --- Sources ---------------------------------------------------------------------------------
    if [ -d "$dir/.git" ]; then
        say "Updating LCode in $dir…"
        git -C "$dir" fetch --quiet origin "$branch"
        git -C "$dir" checkout --quiet "$branch"
        git -C "$dir" merge --quiet --ff-only "origin/$branch" || die "local changes in $dir prevent the update."
    else
        say "Cloning LCode into $dir…"
        mkdir -p "$(dirname "$dir")"
        git clone --quiet --branch "$branch" "$repo" "$dir"
    fi

    # --- Build -----------------------------------------------------------------------------------
    # The binaries find LCode's sources (needed to build apps for the simulator) at the path they
    # were compiled from, so they must stay in $dir.
    say "Building LCode (the first build takes several minutes)…"
    (cd "$dir" && swift build -c release --product lcode && swift build -c release --product lcode-ide)

    # --- Commands and menu entry ------------------------------------------------------------------
    mkdir -p "$bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/scalable/apps"
    cp "$dir/Resources/lcode.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/lcode.svg"
    ln -sf "$dir/.build/release/lcode" "$bin/lcode"
    ln -sf "$dir/.build/release/lcode-ide" "$bin/lcode-ide"
    cat > "$HOME/.local/share/applications/lcode.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LCode
Comment=Build iOS apps in Swift and SwiftUI on Linux
Exec=$bin/lcode-ide %F
Icon=lcode
Terminal=false
Categories=Development;IDE;
EOF
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$HOME/.local/share/applications" || true

    say "LCode is installed."
    echo "    lcode-ide              open the IDE (also in your applications menu)"
    echo "    lcode new MyApp        create an iOS app project"
    echo "    lcode run MyApp        run it in the simulator"
    case ":$PATH:" in
        *":$bin:"*) ;;
        *) warn "$bin is not on your PATH yet: open a new terminal (or log out and back in).";;
    esac
    if ! command -v xtool >/dev/null && [ ! -x "$bin/xtool" ]; then
        echo
        echo "To build for a real iPhone, also install xtool: https://github.com/xtool-org/xtool"
    fi
}

# Major version of the default GCC, for the matching libgcc/libstdc++ dev packages: the Swift
# toolchain links against the newest GCC install it finds, so it must be complete.
gcc_major() {
    local v=""
    command -v gcc >/dev/null && v="$(gcc -dumpversion 2>/dev/null | cut -d. -f1)"
    if [ -z "$v" ] && [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        case "$(. /etc/os-release; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")" in
            jammy) v=12 ;; focal) v=10 ;; bookworm) v=12 ;; *) v=13 ;;
        esac
    fi
    echo "${v:-13}"
}

# swiftly platform name for Ubuntu derivatives (Linux Mint, Pop!_OS, Zorin…) that swiftly does not
# recognize by itself; empty when swiftly can detect it.
swift_platform() {
    [ -r /etc/os-release ] || return 0
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in ubuntu|debian|fedora|rhel|amzn) return 0;; esac
    case "${UBUNTU_CODENAME:-}" in
        noble) echo ubuntu24.04 ;;
        jammy) echo ubuntu22.04 ;;
        focal) echo ubuntu20.04 ;;
    esac
}

main "$@"
