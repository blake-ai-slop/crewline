#!/bin/sh
# Crewline for Linux/macOS. No sudo; all installs stay in HOME.
crew_pwsh_asset() {
    case "$(uname -s):$(uname -m)" in
        Linux:x86_64) echo linux-x64 ;;
        Linux:aarch64|Linux:arm64) echo linux-arm64 ;;
        Darwin:arm64|Darwin:aarch64) echo osx-arm64 ;;
        Darwin:x86_64) echo osx-x64 ;;
        *) echo "bootstrap: unsupported platform: $(uname -s) $(uname -m)" >&2; return 1 ;;
    esac
}
crew_bootstrap() {
    for tool in curl git tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            case "$(uname -s)" in
                Darwin) echo "bootstrap: missing $tool. Install with: brew install $tool" >&2 ;;
                *) echo "bootstrap: missing $tool. Install with: sudo apt install $tool (or sudo dnf install $tool)" >&2 ;;
            esac
            return 1
        fi
    done
    crew_bin="$HOME/.local/bin"
    if ! command -v pwsh >/dev/null 2>&1; then
        crew_asset=$(crew_pwsh_asset) || return 1
        # GitHub's latest release redirect excludes prereleases.
        crew_release=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/PowerShell/PowerShell/releases/latest) || return 1
        crew_version=${crew_release##*/v}
        case "$crew_version" in
            ''|*[!0-9.]*) echo 'bootstrap: invalid PowerShell release version' >&2; return 1 ;;
        esac
        crew_tmp=$(mktemp -d) || return 1
        crew_url="https://github.com/PowerShell/PowerShell/releases/download/v$crew_version/powershell-$crew_version-$crew_asset.tar.gz"
        echo "bootstrap: install PowerShell $crew_version ($crew_asset)"
        if ! curl -fsSL "$crew_url" -o "$crew_tmp/pwsh.tar.gz"; then
            rm -f "$crew_tmp/pwsh.tar.gz"; rmdir "$crew_tmp"; return 1
        fi
        mkdir -p "$HOME/.local/share/powershell" "$crew_bin" || return 1
        if ! tar -xzf "$crew_tmp/pwsh.tar.gz" -C "$HOME/.local/share/powershell"; then
            rm -f "$crew_tmp/pwsh.tar.gz"; rmdir "$crew_tmp"; return 1
        fi
        rm -f "$crew_tmp/pwsh.tar.gz"; rmdir "$crew_tmp"
        chmod +x "$HOME/.local/share/powershell/pwsh" || return 1
        ln -sf "$HOME/.local/share/powershell/pwsh" "$crew_bin/pwsh" || return 1
        PATH="$crew_bin:$PATH"
        export PATH
    fi
    crew_dir=${CREWLINE_DIR:-"$HOME/Crewline"}
    crew_repo=${CREWLINE_REPO:-https://github.com/blake-ai-slop/crewline}
    crew_branch=${CREWLINE_BRANCH:-main}
    if [ -f "$crew_dir/scripts/crew.ps1" ] && [ -f "$crew_dir/install.ps1" ]; then
        crew_dirty=$(git -C "$crew_dir" status --porcelain) || return 1
        if [ -n "$crew_dirty" ]; then
            echo 'bootstrap: uncommitted changes; skip git pull, run install.'
        else
            git -C "$crew_dir" pull --ff-only -q || return 1
        fi
    elif [ ! -d "$crew_dir" ] || [ -z "$(ls -A "$crew_dir")" ]; then
        git clone -q --branch "$crew_branch" "$crew_repo" "$crew_dir" || return 1
    else
        echo "bootstrap: $crew_dir exists and is not Crewline; refusing to overwrite." >&2
        return 1
    fi
    # curl | sh consumes stdin. Reconnect the installer to the terminal if available.
    if ( : </dev/tty ) 2>/dev/null; then
        pwsh -NoProfile -File "$crew_dir/install.ps1" </dev/tty
    else
        CREWLINE_DEFAULTS=1 pwsh -NoProfile -File "$crew_dir/install.ps1" </dev/null
    fi
}
if [ "${CREWLINE_BOOTSTRAP_LIBRARY:-}" != 1 ]; then
    crew_bootstrap
    exit $?
fi
