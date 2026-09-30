#!/bin/sh
# Copy xgameruntime.dll next to both game executables and into the Proton prefix.
# Also runs xauth.py at the end to generate the login token, unless --no-login
# is passed or stdin is not a terminal.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
TEMP="$ROOT/.temp"
LOGIN=1
for arg in "$@"; do
    case "$arg" in
        --no-login) LOGIN=0 ;;
    esac
done

DLL="$ROOT/src/xgameruntime.dll"
GDK_NUPKG_FILE="$TEMP/gdk.nupkg"
APPID=1912410

PY=${PYTHON:-/usr/bin/python3}
VENV="$ROOT/.venv"
XAUTH="$ROOT/xauth.py"

# Locate the Steam installation (the directory that contains steamapps). When
# STEAM_ROOT is set we use exactly that path and fail loudly if it is wrong,
# rather than silently falling back to a default and confusing the user.
resolve_steam_root() {
    if [ -n "${STEAM_ROOT:-}" ]; then
        root=${STEAM_ROOT%/}
        case $root in
            "~") root=$HOME ;;
            "~/"*) root=$HOME/${root#\~/} ;;
        esac
        if [ ! -f "$root/steamapps/libraryfolders.vdf" ]; then
            echo "STEAM_ROOT is set to '$STEAM_ROOT', but" >&2
            echo "  $root/steamapps/libraryfolders.vdf" >&2
            echo "does not exist. Point STEAM_ROOT at the Steam install folder" >&2
            echo "(the one containing 'steamapps'), or unset it to autodetect." >&2
            exit 1
        fi
        STEAM_ROOT=$root
        return
    fi
    for root in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
        if [ -f "$root/steamapps/libraryfolders.vdf" ]; then
            STEAM_ROOT=$root
            return
        fi
    done
    echo "Could not find steamapps/libraryfolders.vdf. Looked in:" >&2
    for root in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
        echo "  $root/steamapps/libraryfolders.vdf" >&2
    done
    echo "Set STEAM_ROOT to the Steam install folder (the one containing 'steamapps')." >&2
    exit 1
}
resolve_steam_root
VDF="$STEAM_ROOT/steamapps/libraryfolders.vdf"

LIB=$(awk '
    /"path"/ {
        gsub(/"/, "", $2)
        path = $2
        manifest = path "/steamapps/appmanifest_'"$APPID"'.acf"
        if (system("test -f \"" manifest "\"") == 0) { print path; exit }
    }
' "$VDF")

GAME="$LIB/steamapps/common/Minecraft Dungeons II"
PFX="$LIB/steamapps/compatdata/$APPID/pfx/drive_c/windows/system32"
SHIP="$GAME/Dungeons/Binaries/Win64"


if [ ! -f "$DLL" ]; then
    echo "Missing $DLL. Build it first; see README.md." >&2
    exit 1
fi

if [ ! -d "$TEMP" ]; then
    echo "Making .temp directory."
    mkdir "$TEMP"
fi

# xauth.py runs under a self-contained virtual environment. Dependencies are
# declared in pyproject.toml (cryptography, for the device-token step) so the
# system Python is left untouched.
[ -x "$PY" ] || PY=python3
if ! command -v "$PY" >/dev/null 2>&1; then
    echo "Python 3 is required (xauth.py runs under it)." >&2
    exit 1
fi

if [ ! -x "$VENV/bin/python3" ]; then
    echo "Creating a Python virtual environment in $VENV"
    "$PY" -m venv "$VENV" >/dev/null 2>&1 || true
fi
if [ -x "$VENV/bin/python3" ] && ! "$VENV/bin/python3" -c "import cryptography" >/dev/null 2>&1; then
    echo "Installing dependencies from pyproject.toml into $VENV"
    "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check "$ROOT" >/dev/null 2>&1 ||
        "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check cryptography >/dev/null 2>&1 || true
fi
if [ ! -x "$VENV/bin/python3" ] || ! "$VENV/bin/python3" -c "import cryptography" >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Could not set up the virtual environment. Install Python's venv support, then
re-run install.sh:

  Debian/Ubuntu  sudo apt install python3-venv
  Fedora         sudo dnf install python3
  Arch           sudo pacman -S python
EOF
    exit 1
fi

if [ -z "$LIB" ]; then
    echo "Steam app $APPID is not in any library folder." >&2
    exit 1
fi

for dir in "$GAME" "$SHIP" "$PFX"; do
    if [ ! -d "$dir" ]; then
        echo "Missing $dir, creating..." >&2
        mkdir -p "$dir"
    fi
    cp -f "$DLL" "$dir/xgameruntime.dll"
    printf '%s\n' "$ROOT" > "$dir/xgameruntime.path"
    echo "Installed $dir/xgameruntime.dll"
done

for tool in curl unzip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required to install XCurl.dll." >&2
        exit 1
    fi
done

if [ ! -f "$GDK_NUPKG_FILE" ]; then
    echo "Downloading a working XCurl.dll dist"
    curl -fsSL -o "$GDK_NUPKG_FILE" https://api.nuget.org/v3-flatcontainer/microsoft.gdk.pc.230307/10.0.22621.3139/microsoft.gdk.pc.230307.10.0.22621.3139.nupkg
fi
unzip -j -o -d "$TEMP" "$GDK_NUPKG_FILE" 'native/230307/GRDK/ExtensionLibraries/xbox.xcurl.api/redist/commonconfiguration/neutral/XCurl.dll'
mv -f "$TEMP/XCurl.dll" "$SHIP/XCurl.dll"
echo "Installed $SHIP/XCurl.dll"

chmod +x "$XAUTH"
echo ""

if [ "$LOGIN" -eq 1 ] && [ -t 0 ]; then
    echo "============================================================"
    echo "Signing in to your Microsoft account (generates your login token)."
    echo "============================================================"
    if ! "$VENV/bin/python3" "$XAUTH"; then
        echo "Sign-in did not complete. Re-run it any time with:" >&2
        echo "  $VENV/bin/python3 $XAUTH" >&2
    fi
else
    echo "============================================================"
    echo "Setup complete. NEXT STEP: generate your login token first!"
    echo ""
    echo "Before launching the game, run xauth.py once to sign in with"
    echo "your Microsoft account and generate your login token:"
    echo "  $VENV/bin/python3 $XAUTH   # or: ./xauth.py"
    echo "============================================================"
    echo ""
fi

echo "Then set this launch option for Minecraft Dungeons II in Steam:"
echo 'WINEDLLOVERRIDES="xgameruntime=n" %command%'
echo "and set its Compatibility tool to Proton Experimental or Proton-GE."
