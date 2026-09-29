#!/usr/bin/env python3
"""Sign in with the user's own Microsoft account and cache Xbox tokens.

The browser login uses this game's Microsoft app id. Tokens are written
for the local runtime; they are never printed.

Run this by hand before launching the game:

    .venv/bin/python3 xauth.py            # refresh or sign in if needed
    .venv/bin/python3 xauth.py --force    # sign in again from scratch
    .venv/bin/python3 xauth.py --status   # show the cached login
    .venv/bin/python3 xauth.py --logout   # forget the cached login
"""
import argparse
import base64
import hashlib
import json
import os
import shlex
import shutil
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from typing import Any, Final, Iterator, Optional

# Microsoft account (live.com) OAuth client id used by this title's Xbox Live
# sign-in, recovered from the game's own authentication request. It is a public
# first-party app id, not a secret, and pairs with SCOPE (the legacy Live
# Connect scope the game asks for). A custom Azure app id would instead use the
# "d=" RPS ticket form, which rps_ticket() already handles.
CLIENT: Final = "00000000497C1B94"
SCOPE: Final = "service::user.auth.xboxlive.com::MBI_SSL"
PLAYFAB_RP: Final = "http://playfab.xboxlive.com/"
HERE: Final = os.path.dirname(os.path.realpath(__file__))
TOKEN_PATH: Final = os.path.join(HERE, "tokens.txt")
CODE_PATH: Final = os.path.join(HERE, "login-code.txt")
ERROR_PATH: Final = os.path.join(HERE, "login-error.txt")


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def post(url: str, form: Optional[dict[str, str]] = None,
         payload: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    if payload is not None:
        data = json.dumps(payload).encode()
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
    else:
        data = urllib.parse.urlencode(form or {}).encode()
        headers = {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode(errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"error": body[:300]}
        if not isinstance(parsed, dict):
            parsed = {"error": body[:300]}
        parsed["_status"] = exc.code
        return parsed
    except (urllib.error.URLError, OSError) as exc:
        reason = getattr(exc, "reason", None) or exc
        return {"error": "network error: %s" % reason}
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return {"error": "could not parse response from %s" % url}
    if not isinstance(parsed, dict):
        return {"error": "unexpected response from %s" % url}
    return parsed


def jwt_exp(token: str) -> int:
    try:
        if ";" in token:
            token = token.rsplit(";", 1)[1]
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        data = json.loads(base64.urlsafe_b64decode(part))
        return _safe_int(data.get("exp"))
    except Exception:
        return 0


def read_tokens() -> dict[str, str]:
    values: dict[str, str] = {}
    if not os.path.isfile(TOKEN_PATH):
        return values
    with open(TOKEN_PATH, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
    return values


def repair_stored_exp() -> None:
    if not os.path.isfile(TOKEN_PATH):
        return
    lines: list[str] = []
    values: dict[str, str] = {}
    with open(TOKEN_PATH, "r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.rstrip("\n")
            lines.append(stripped)
            if "=" in stripped:
                key, value = stripped.split("=", 1)
                values[key] = value
    if _safe_int(values.get("exp")) > time.time() + 120:
        return
    exp = 0
    for key in ("xbox", "mc"):
        got = jwt_exp(values.get(key, ""))
        if got:
            exp = min(exp, got) if exp else got
    if not exp:
        return
    replaced = False
    for i, line in enumerate(lines):
        if line.startswith("exp="):
            lines[i] = "exp=%s" % exp
            replaced = True
    if not replaced:
        lines.insert(0, "exp=%s" % exp)
    fields: list[tuple[str, str]] = []
    for line in lines:
        if "=" in line:
            key, value = line.split("=", 1)
            fields.append((key, value))
    write_tokens(fields)


def token_expiry() -> int:
    return _safe_int(read_tokens().get("exp"))


def cached_ok() -> bool:
    return token_expiry() > time.time() + 120


def rps_ticket(access: str) -> str:
    if access.startswith("t=") or access.startswith("d="):
        return access
    if access.startswith("eyJ"):
        return "d=" + access
    return "t=" + access


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def device_token() -> Optional[str]:
    """Mint a Win32 device token through a signed proof-of-possession request.

    PlayFab rejects XSTS tokens that carry no device identity, so the
    PlayFab relying-party token has to include one. Returns None when the
    cryptography package is unavailable or the request fails.
    """
    try:
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.asymmetric.utils import (
            Prehashed,
            decode_dss_signature,
        )
    except ImportError:
        return None

    key = ec.generate_private_key(ec.SECP256R1())
    point = key.public_key().public_numbers()
    proof = {
        "use": "sig", "alg": "ES256", "kty": "EC", "crv": "P-256",
        "x": _b64url(point.x.to_bytes(32, "big")),
        "y": _b64url(point.y.to_bytes(32, "big")),
    }
    body = json.dumps({
        "RelyingParty": "http://auth.xboxlive.com",
        "TokenType": "JWT",
        "Properties": {
            "AuthMethod": "ProofOfPossession",
            "Id": "{%s}" % uuid.uuid4(),
            "DeviceType": "Win32",
            "SerialNumber": "{%s}" % uuid.uuid4(),
            "Version": "10.0.19041",
            "ProofKey": proof,
        },
    }).encode()

    version = struct.pack("!I", 1)
    epoch = datetime(1601, 1, 1, tzinfo=timezone.utc)
    filetime = int((datetime.now(timezone.utc) - epoch).total_seconds() * 10_000_000)
    stamp = struct.pack("!Q", filetime)
    signed = (version + b"\x00" + stamp + b"\x00" + b"POST" + b"\x00" +
              b"/device/authenticate" + b"\x00" + b"\x00" + body[:8192] + b"\x00")
    raw = key.sign(hashlib.sha256(signed).digest(), ec.ECDSA(Prehashed(hashes.SHA256())))
    r, s = decode_dss_signature(raw)
    signature = base64.b64encode(
        version + stamp + r.to_bytes(32, "big") + s.to_bytes(32, "big")
    ).decode()

    request = urllib.request.Request(
        "https://device.auth.xboxlive.com/device/authenticate",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "x-xbl-contract-version": "1",
            "Signature": signature,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode()).get("Token")
    except (urllib.error.HTTPError, urllib.error.URLError, OSError, json.JSONDecodeError):
        return None


def xbox_user(access: str) -> str:
    result = post("https://user.auth.xboxlive.com/user/authenticate", payload={
        "Properties": {
            "AuthMethod": "RPS",
            "SiteName": "user.auth.xboxlive.com",
            "RpsTicket": rps_ticket(access),
        },
        "RelyingParty": "http://auth.xboxlive.com",
        "TokenType": "JWT",
    })
    if "Token" not in result:
        raise SystemExit("Xbox user auth failed: %s" % result.get("XErr", result.get("error")))
    return result["Token"]


def xsts(user_token: str, relying: str, device: Optional[str] = None
         ) -> tuple[Optional[dict[str, Any]], Any]:
    properties: dict[str, Any] = {"SandboxId": "RETAIL", "UserTokens": [user_token]}
    if device:
        properties["DeviceToken"] = device
    result = post("https://xsts.auth.xboxlive.com/xsts/authorize", payload={
        "Properties": properties,
        "RelyingParty": relying,
        "TokenType": "JWT",
    })
    if "Token" not in result:
        return None, result.get("XErr", result.get("error"))
    return result, None


def auth_header(doc: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    claim = doc["DisplayClaims"]["xui"][0]
    return "XBL3.0 x=%s;%s" % (claim["uhs"], doc["Token"]), claim


def write_tokens(fields: list[tuple[str, str]]) -> None:
    tmp = TOKEN_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        for key, value in fields:
            handle.write("%s=%s\n" % (key, value))
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, TOKEN_PATH)


def desktop_env() -> dict[str, str]:
    """Environment for desktop helpers, without assuming a specific session."""
    env = os.environ.copy()
    if not env.get("XDG_RUNTIME_DIR") and hasattr(os, "getuid"):
        candidate = "/run/user/%d" % os.getuid()
        if os.path.isdir(candidate):
            env["XDG_RUNTIME_DIR"] = candidate
    return env


def _browser_commands(url: str) -> Iterator[list[str]]:
    """Yield candidate browser commands, most preferred first."""
    chosen = os.environ.get("BROWSER")
    if chosen:
        for entry in chosen.split(os.pathsep):
            entry = entry.strip()
            if not entry:
                continue
            if "%s" in entry:
                parts = shlex.split(entry.replace("%s", url))
            else:
                parts = shlex.split(entry) + [url]
            if parts:
                yield parts
    for parts in (
        ["xdg-open", url],
        ["gio", "open", url],
        ["sensible-browser", url],
        ["x-www-browser", url],
        ["firefox", url],
        ["chromium", url],
        ["chromium-browser", url],
        ["google-chrome", url],
        ["brave-browser", url],
        ["microsoft-edge", url],
        ["epiphany", url],
        ["konqueror", url],
        ["open", url],  # macOS
    ):
        yield parts


def open_browser(url: str, env: dict[str, str]) -> bool:
    """Try each launcher until one starts. Returns True when one is used."""
    for cmd in _browser_commands(url):
        if not shutil.which(cmd[0]):
            continue
        try:
            proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            continue
        time.sleep(1.0)
        if proc.poll() is None or proc.returncode == 0:
            return True
    return False


def notify(text: str, env: dict[str, str]) -> bool:
    """Show a desktop notification with whichever helper is installed."""
    for cmd in (
        ["zenity", "--info", "--title=Minecraft Dungeons II sign-in", "--text", text, "--width=560"],
        ["yad", "--info", "--title=Minecraft Dungeons II sign-in", "--text", text, "--width=560"],
        ["kdialog", "--title", "Minecraft Dungeons II sign-in", "--msgbox", text],
        ["xmessage", "-center", text],
    ):
        if not shutil.which(cmd[0]):
            continue
        try:
            subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except OSError:
            continue
    return False


def show_code(url: str, code: str) -> None:
    message = "Sign in with your Microsoft account.\n\nOpen %s\nCode: %s" % (url, code)
    try:
        with open(CODE_PATH, "w", encoding="utf-8") as handle:
            handle.write(url + "\n" + code + "\n")
    except OSError:
        pass
    print()
    print("Sign in with your Microsoft account")
    print("  1. Open: %s" % url)
    print("  2. Enter code: %s" % code)
    print()
    sys.stdout.flush()
    env = desktop_env()
    if not open_browser(url, env):
        print("No browser launcher was found; open the URL above yourself.")
        sys.stdout.flush()
    notify(message, env)


def poll_msa(device_code: str, interval: int, expires_in: int) -> dict[str, Any]:
    deadline = time.time() + max(30, expires_in - 5)
    while time.time() < deadline:
        time.sleep(max(int(interval), 5))
        result = post("https://login.live.com/oauth20_token.srf", form={
            "client_id": CLIENT,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": device_code,
        })
        if "access_token" in result:
            return result
        err = result.get("error", "")
        if err == "slow_down":
            interval = int(interval) + 5
            continue
        if err == "authorization_pending":
            continue
        raise SystemExit("Microsoft login failed: %s" % (result.get("error_description") or err or result.get("_status")))
    raise SystemExit("Microsoft login timed out")


def refresh_msa(refresh: str) -> Optional[dict[str, Any]]:
    result = post("https://login.live.com/oauth20_token.srf", form={
        "client_id": CLIENT,
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "scope": SCOPE,
    })
    if "access_token" not in result:
        return None
    return result


def load_refresh() -> Optional[str]:
    return read_tokens().get("refresh") or None


def finish(msa: dict[str, Any]) -> None:
    user_token = xbox_user(msa["access_token"])
    xbox, xerr = xsts(user_token, "http://xboxlive.com")
    if not xbox:
        raise SystemExit("Xbox token failed: %s" % xerr)
    minecraft, mc_err = xsts(user_token, "rp://api.minecraftservices.com/")
    playfab, pf_err = xsts(user_token, PLAYFAB_RP, device_token())
    header, claim = auth_header(xbox)
    mc_header = auth_header(minecraft)[0] if minecraft else header
    pf_header = auth_header(playfab)[0] if playfab else ""
    exp = jwt_exp(xbox["Token"])
    for extra in (minecraft, playfab):
        if extra:
            extra_exp = jwt_exp(extra["Token"])
            if extra_exp:
                exp = min(exp, extra_exp) if exp else extra_exp
    if not exp:
        exp = int(time.time()) + 4 * 3600
    write_tokens([
        ("exp", str(exp)),
        ("xuid", claim.get("xid", "0")),
        ("uhs", claim.get("uhs", "")),
        ("gamertag", claim.get("gtg", "Player")),
        ("xbox", header),
        ("mc", mc_header),
        ("playfab", pf_header),
        ("msa", msa["access_token"]),
        ("refresh", msa.get("refresh_token", "")),
        ("mc_error", "" if minecraft else str(mc_err or "")),
        ("pf_error", "" if playfab else str(pf_err or "")),
    ])


def remove_tokens() -> None:
    removed: list[str] = []
    for path in (TOKEN_PATH, TOKEN_PATH + ".tmp", CODE_PATH, ERROR_PATH):
        try:
            os.remove(path)
            removed.append(os.path.basename(path))
        except FileNotFoundError:
            pass
        except OSError as exc:
            print("Could not remove %s: %s" % (path, exc))
    if removed:
        print("Removed %s." % ", ".join(removed))
    else:
        print("No cached login to remove.")


def show_status() -> None:
    if cached_ok():
        exp = token_expiry()
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(exp)) if exp else "unknown"
        print("Signed in; tokens valid until %s." % when)
    elif os.path.isfile(TOKEN_PATH):
        print("Cached tokens are present but expired. Run xauth.py to refresh or sign in again.")
    else:
        print("Not signed in. Run xauth.py to sign in.")


def main(argv: Optional[list[str]] = None) -> None:
    parser = argparse.ArgumentParser(
        description="Sign in with your Microsoft account and cache Xbox tokens for Minecraft Dungeons II.")
    parser.add_argument("--force", "-f", action="store_true",
                        help="sign in again even if the cached tokens are still valid")
    parser.add_argument("--logout", action="store_true",
                        help="delete the cached login and exit")
    parser.add_argument("--status", action="store_true",
                        help="show the cached login and exit")
    args = parser.parse_args(argv)

    if args.logout:
        remove_tokens()
        return
    if args.status:
        show_status()
        return

    repair_stored_exp()
    if not args.force and cached_ok():
        exp = token_expiry()
        if exp:
            print("Already signed in; tokens valid until %s."
                  % time.strftime("%Y-%m-%d %H:%M", time.localtime(exp)))
        else:
            print("Already signed in; cached tokens are valid.")
        print("Use --force to sign in again.")
        return

    if not args.force:
        refresh = load_refresh()
        if refresh:
            refreshed = refresh_msa(refresh)
            if refreshed:
                finish(refreshed)
                print("Refreshed the cached login.")
                return

    started = post("https://login.live.com/oauth20_connect.srf", form={
        "client_id": CLIENT,
        "scope": SCOPE,
        "response_type": "device_code",
    })
    if "device_code" not in started:
        raise SystemExit("Could not start Microsoft login: %s" % started.get("error"))
    show_code(started.get("verification_uri") or "https://www.microsoft.com/link", started["user_code"])
    finish(poll_msa(started["device_code"], started.get("interval", 5), started.get("expires_in", 900)))
    print("Signed in. You can launch the game now.")


if __name__ == "__main__":
    try:
        main()
    except SystemExit as exc:
        if exc.code not in (0, None) and not isinstance(exc.code, int):
            try:
                with open(ERROR_PATH, "w", encoding="utf-8") as handle:
                    handle.write(str(exc.code or exc)[:400])
            except OSError:
                pass
        raise
    except KeyboardInterrupt:
        raise SystemExit("Cancelled.")
