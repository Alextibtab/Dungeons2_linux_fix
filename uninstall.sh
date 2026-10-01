#!/bin/sh
# Undo install.sh for Minecraft Dungeons II (Steam app 1912410).
#
# Removes the injected xgameruntime.dll / xgameruntime.path copies and the
# XCurl.dll that install.sh put in place, clears the Steam launch option, and
# deletes the cached Microsoft tokens. The Proton prefix is left intact; only
# the xgameruntime.dll that install.sh copied into its system32 is removed.
#
# Steam's "Verify integrity of game files" does NOT remove extra files, which
# is why the xgameruntime copies have to be deleted here; it only restores the
# genuine XCurl.dll that install.sh overwrote. Run it after this script.
#
# Usage:
#   ./uninstall.sh [--dry-run]
#
#   --dry-run         show what would be removed, change nothing
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
APPID=1912410
GAME_NAME="Minecraft Dungeons II"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

remove_path() {
    # Remove a file/symlink if it exists, honouring --dry-run.
    if [ -e "$1" ] || [ -L "$1" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            say "would remove: $1"
        else
            rm -f -- "$1"
            say "removed: $1"
        fi
    fi
}

# Locate the Steam installation directory (the one containing steamapps). Uses
# STEAM_ROOT when set, otherwise the usual locations. Returns non-zero and
# prints nothing when it cannot be found.
detect_steam_root() {
    if [ -n "${STEAM_ROOT:-}" ]; then
        root=${STEAM_ROOT%/}
        case $root in
            "~") root=$HOME ;;
            "~/"*) root=$HOME/${root#\~/} ;;
        esac
        if [ -f "$root/steamapps/libraryfolders.vdf" ]; then
            printf '%s\n' "$root"
            return 0
        fi
        return 1
    fi
    for root in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
        if [ -f "$root/steamapps/libraryfolders.vdf" ]; then
            printf '%s\n' "$root"
            return 0
        fi
    done
    return 1
}

# Print every library root (a directory that contains steamapps), deduplicated.
library_roots() {
    [ -n "$STEAM_ROOT_FOUND" ] || return 0
    vdf="$STEAM_ROOT_FOUND/steamapps/libraryfolders.vdf"
    {
        printf '%s\n' "$STEAM_ROOT_FOUND"
        awk -F'"' '/"path"[[:space:]]/{print $4}' "$vdf"
    } | awk '!seen[$0]++'
}

# Clear the launch option from Steam's localconfig.vdf. The only launch option
# this patch uses is the xgameruntime override, so when it is present the whole
# field is blanked. Skipped while Steam is running because Steam rewrites the
# file on exit.
clear_launch_options() {
    [ -n "$STEAM_ROOT_FOUND" ] || return 0
    if pgrep -x steam >/dev/null 2>&1 || pgrep -x steamwebhelper >/dev/null 2>&1; then
        warn "Steam is running, so the launch option was not edited (it would be overwritten)."
        warn "Remove it by hand: $GAME_NAME -> Properties -> Launch Options -> delete"
        warn '  WINEDLLOVERRIDES="xgameruntime=n" %command%'
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || {
        warn "python3 not found; remove the launch option by hand in Steam."
        return 0
    }
    for f in "$STEAM_ROOT_FOUND"/userdata/*/config/localconfig.vdf; do
        [ -f "$f" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            say "would clear xgameruntime launch option in $f (if present)"
            continue
        fi
        python3 - "$f" "$APPID" <<'PY' || warn "could not edit $f"
import re, shutil, sys

path, appid = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    text = fh.read().decode("utf-8", "surrogateescape")
if "xgameruntime" not in text:
    sys.exit(0)

key = '"%s"' % appid
idx = 0
changed = False
while True:
    hit = text.find(key, idx)
    if hit == -1:
        break
    j = hit + len(key)
    while j < len(text) and text[j] in " \t\r\n":
        j += 1
    if j < len(text) and text[j] == "{":
        depth, i = 0, j
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        block = text[j:i + 1]
        m = re.search(r'("LaunchOptions"\s*)"((?:[^"\\]|\\.)*)"', block)
        if m and "xgameruntime" in m.group(2):
            # The override is the only launch option this patch uses, so blank
            # the whole field rather than trying to preserve parts of it.
            new_block = block[:m.start()] + m.group(1) + '""' + block[m.end():]
            text = text[:j] + new_block + text[i + 1:]
            changed = True
            break
    idx = hit + 1

if changed:
    shutil.copy2(path, path + ".bak")
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(text)
    print("Cleared xgameruntime launch option in " + path)
PY
    done
}

STEAM_ROOT_FOUND=""
if root=$(detect_steam_root); then
    STEAM_ROOT_FOUND=$root
else
    warn "Could not find Steam (looked for steamapps/libraryfolders.vdf)."
    warn "Set STEAM_ROOT to the Steam install folder (the one containing 'steamapps')."
fi

# Remove the injected files from every library.
library_roots | while IFS= read -r root; do
    [ -n "$root" ] || continue
    sa="$root/steamapps"
    game="$sa/common/$GAME_NAME"
    ship="$game/Dungeons/Binaries/Win64"
    sys32="$sa/compatdata/$APPID/pfx/drive_c/windows/system32"

    remove_path "$game/xgameruntime.dll"
    remove_path "$game/xgameruntime.path"
    remove_path "$ship/xgameruntime.dll"
    remove_path "$ship/xgameruntime.path"
    remove_path "$sys32/xgameruntime.dll"
    remove_path "$sys32/xgameruntime.path"
    # XCurl.dll is a genuine game file that install.sh overwrote; deleting it
    # lets "Verify integrity of game files" restore the correct one.
    remove_path "$ship/XCurl.dll"
done

# Cached Microsoft credentials written by xauth.py.
remove_path "$ROOT/tokens.txt"
remove_path "$ROOT/login-code.txt"
remove_path "$ROOT/login-error.txt"

clear_launch_options

say ""
say "Done. Next steps:"
say "  1. In Steam: $GAME_NAME -> Properties -> Installed Files -> Verify integrity of game files"
say "     (this restores the original XCurl.dll and any other patched game files)"
say "  2. Make sure the launch option is empty if it was not cleared automatically."
