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
# VERSION = Crewline release; skeleton/VERSION = project context frame.
crew_read_version() {
    crew_v=''
    if [ -f "$1" ]; then crew_v=$(tr -d ' \r\n' <"$1") || crew_v=''; fi
    case "$crew_v" in
        ''|*[!0-9]*) echo '' ;;
        *) echo "$crew_v" ;;
    esac
}
crew_product_version() {
    crew_v=''
    if [ -f "$1/VERSION" ]; then
        crew_v=$(LC_ALL=C awk '
            NR == 1 { version = $0 }
            NR > 1 { version = version "\n" $0 }
            END {
                sub(/^[[:space:]]+/, "", version)
                sub(/[[:space:]]+$/, "", version)
                if (version ~ /^[1-9][0-9]*([.][1-9][0-9]*)?$/) print version
            }
        ' "$1/VERSION") || crew_v=''
    fi
    if [ -n "$crew_v" ]; then echo "v$crew_v"; else echo 'ban cu'; fi
}
crew_context_version() {
    crew_v=$(crew_read_version "$1/skeleton/VERSION")
    if [ -n "$crew_v" ]; then echo "$crew_v"; else echo '?'; fi
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
        crew_before=$(git -C "$crew_dir" rev-parse --short HEAD) || return 1
        crew_before_crew=$(crew_product_version "$crew_dir")
        crew_before_version=$(crew_context_version "$crew_dir")
        if [ -n "$crew_dirty" ]; then
            echo "bootstrap: uncommitted changes; skip git pull, still on old version Crewline $crew_before_crew (commit $crew_before, khung context v$crew_before_version), run install. Inspect: git -C \"$crew_dir\" status; save changes: git -C \"$crew_dir\" stash."
        else
            git -C "$crew_dir" pull --ff-only -q || return 1
            crew_after=$(git -C "$crew_dir" rev-parse --short HEAD) || return 1
            crew_after_crew=$(crew_product_version "$crew_dir")
            crew_after_version=$(crew_context_version "$crew_dir")
            if [ "$crew_before" = "$crew_after" ]; then
                echo "bootstrap: da o ban moi nhat: Crewline $crew_after_crew (commit $crew_after, khung context v$crew_after_version)"
            else
                if [ "$crew_before_version" = "$crew_after_version" ]; then
                    crew_context_line="khung context v$crew_after_version"
                else
                    crew_context_line="khung context v$crew_before_version -> v$crew_after_version"
                fi
                echo "bootstrap: cap nhat Crewline $crew_before_crew -> $crew_after_crew (commit $crew_before -> $crew_after, $crew_context_line)"
            fi
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
