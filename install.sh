#!/bin/sh
# Copy xgameruntime.dll next to both game executables and into the Proton prefix.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
TEMP="$ROOT/.temp"

STEAM_ROOT=${STEAM_ROOT:-$HOME/.local/share/Steam}
VDF="$STEAM_ROOT/steamapps/libraryfolders.vdf"
DLL="$ROOT/src/xgameruntime.dll"
GDK_NUPKG_FILE="$TEMP/gdk.nupkg"
APPID=1912410

PY=${PYTHON:-/usr/bin/python3}
VENV="$ROOT/.venv"
XAUTH="$ROOT/xauth.py"

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

if [ ! -f "$STEAM_ROOT/steamapps/libraryfolders.vdf" ] && [ -f "$HOME/.steam/steam/steamapps/libraryfolders.vdf" ]; then
    STEAM_ROOT=$HOME/.steam/steam
fi
if [ ! -f "$VDF" ]; then
    echo "Could not find libraryfolders.vdf. Set STEAM_ROOT." >&2
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
echo "============================================================"
echo "Setup complete. NEXT STEP: generate your login token first!"
echo ""
echo "Before launching the game, run xauth.py once to sign in with"
echo "your Microsoft account and generate your login token:"
echo "  $VENV/bin/python3 $XAUTH   # or: ./xauth.py"
echo "============================================================"
echo ""
echo "Then set this launch option for Minecraft Dungeons II in Steam:"
echo 'WINEDLLOVERRIDES="xgameruntime=n" %command%'
echo "and set its Compatibility tool to Proton Experimental or Proton-GE."
