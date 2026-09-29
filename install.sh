#!/bin/sh
# Copy xgameruntime.dll next to both game executables and into the Proton prefix.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TEMP="$ROOT/.temp"

STEAM_ROOT=${STEAM_ROOT:-$HOME/.local/share/Steam}
VDF="$STEAM_ROOT/steamapps/libraryfolders.vdf"
DLL="$ROOT/src/xgameruntime.dll"
GDK_PROTON_TAR="$TEMP/gdk-proton.tar.gz"
GDK_NUPKG_FILE="$TEMP/gdk.nupkg"
COMPATIBILITY_TOOLS_DIR="$HOME/.steam/root/compatibilitytools.d"
GDK_PROTON_DIR="$COMPATIBILITY_TOOLS_DIR/GDK-Proton11-7"
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

# xauth.py runs under a self-contained virtual environment so the device-token
# step gets the third-party cryptography package without touching system Python.
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
    echo "Installing cryptography into $VENV"
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
    echo "Installed $dir/xgameruntime.dll"
done

echo "Downloading a working XCurl.dll dist"
curl -fsSL -o "$GDK_NUPKG_FILE" https://api.nuget.org/v3-flatcontainer/microsoft.gdk.pc.230307/10.0.22621.3139/microsoft.gdk.pc.230307.10.0.22621.3139.nupkg
unzip -j "$GDK_NUPKG_FILE" 'native/230307/GRDK/ExtensionLibraries/xbox.xcurl.api/redist/commonconfiguration/neutral/XCurl.dll'
mv XCurl.dll "$SHIP/XCurl.dll"
echo "Installed $SHIP/XCurl.dll"

echo "Resetting login cache"
if [ -f "tokens.txt" ]; then
    echo "Deleting old tokens.txt"
    rm tokens.txt
fi
if [ -f "login-code.txt" ]; then
    echo "Deleting old login-code.txt"
    rm login-code.txt
fi

echo "Launching xauth.py, sign in to the Microsoft account you want to use."
chmod +x "$XAUTH"
python3 "$XAUTH"

echo "Installing Proton GDK"
curl -fsSL -o "$GDK_PROTON_TAR" \
  "https://github.com/LukasPAH/GDK-Proton-Custom/releases/download/release-11-7/GDK-Proton11-7-x86_64.tar.gz"
tar -xf "$GDK_PROTON_TAR" -C "$COMPATIBILITY_TOOLS_DIR/"
echo "Patching Proton GDK"
echo "1789528888 GDK-Proton11-7" >"$GDK_PROTON_DIR/version"
tee "$GDK_PROTON_DIR/compatibilitytool.vdf" > /dev/null <<'EOF'
"compatibilitytools"
{
  "compat_tools"
  {
    "GDK-Proton11-7-x86_64" // Internal name of this tool
    {
      // Can register this tool with Steam in two ways:
      //
      // - The tool can be placed as a subdirectory in compatibilitytools.d, in which case this
      //   should be '.'
      //
      // - This manifest can be placed directly in compatibilitytools.d, in which case this should
      //   be the relative or absolute path to the tool's dist directory.
      "install_path" "."

      // For this template, we're going to substitute the display_name key in here, e.g.:
      "display_name" "GDK-Proton11-7-x86_64"

      "from_oslist"  "windows"
      "to_oslist"    "linux"
    }
  }
}
EOF

echo ""
echo "In Steam, set this launch option for Minecraft Dungeons II:"
echo 'WINEDLLOVERRIDES="xgameruntime=n" %command%'
echo "Additionally, set the proton version in the game's compatibility options to GDK-Proton11-7-x86_64"
