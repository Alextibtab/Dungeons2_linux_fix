# Minecraft Dungeons II on Linux

A local stand-in for Microsoft Gaming Services so Minecraft Dungeons II (Steam app `1912410`) can start under Proton. The game loads `xgameruntime.dll`; this repository builds it. It does not modify the game or ship Microsoft's library.

Sign-in is a manual step: run `xauth.py` once with your own Microsoft account, and it caches the Xbox tokens next to the helper. The DLL only reads that cache at launch — there is no in-game sign-in window.

## Install

Proton and Python 3 are required, including its `venv` module (on Debian/Ubuntu install `python3-venv`). Quit the game before installing.

```sh
git clone https://github.com/Alextibtab/Dungeons2_linux_fix.git ~/.local/share/dungeons2-compat
cd ~/.local/share/dungeons2-compat
./install.sh
```

`install.sh`:

- creates `.venv` and installs the dependencies from `pyproject.toml` (`cryptography`, for the device-token step);
- copies `xgameruntime.dll` next to `Dungeons.exe`, next to `Dungeons-Win64-Shipping.exe`, and into the Proton prefix `drive_c/windows/system32`;
- downloads the matching `XCurl.dll` into the game's `Win64` folder.

It finds the game through Steam's `libraryfolders.vdf`; set `STEAM_ROOT` to Steam's install directory (the one containing `steamapps`) if Steam is not in `~/.local/share/Steam`. Make sure to `export` it, and note that it must point at the Steam *install* folder, not at a secondary game library.

In Steam, open the game's properties and set the launch option:

```text
WINEDLLOVERRIDES="xgameruntime=n" %command%
```

On the Compatibility tab, set the game to use **Proton Experimental** or **Proton-GE**. The DLL supplies the Gaming Services pieces, so no special Proton build is required.

## Sign in

From the clone directory:

```sh
.venv/bin/python3 xauth.py
```

A window shows a code and opens <https://www.microsoft.com/link> (the URL and code are also printed in the terminal). Enter the code and sign in with the Microsoft account that owns the Xbox profile, then leave the page on that URL. Re-run after the login expires.

Use `--force` to sign in again, `--status` to show the cached login, or `--logout` to delete it. The cache is `tokens.txt` next to `xauth.py` (mode `0600`); `install.sh` records that location for the DLL, so the helper works from any directory. Do not share the file.

## Rebuild

The bundled `src/xgameruntime.dll` is built against the exact `XCurl.dll` that `install.sh` downloads (Microsoft GDK PC 230307, `10.0.22621.3139`); rebuild it if you use a different `XCurl.dll`. Needs a MinGW-w64 posix cross compiler:

```sh
x86_64-w64-mingw32-gcc-posix -shared -O2 -Wall -Wextra -o src/xgameruntime.dll src/xgameruntime.c
./install.sh
```
