#!/usr/bin/env python3
"""Patch host-only Droidloom source paths for NixOS. Used by Nix postPatch."""

from pathlib import Path
import os
import re
import sys


def path_replacements(paths: dict[str, str]) -> list[tuple[str, str]]:
    return [
        ("/usr/share/droidloom/package.json", "/var/empty/droidloom-nixos-not-pacman"),
        (
            "/usr/lib/droidloom/droidloom-package-helper",
            paths["DL_RUNTIME_LIB"] + "/droidloom-package-helper",
        ),
        ("/usr/lib/droidloom", paths["DL_ANDROID"]),
        ("/usr/share/droidloom", paths["DL_RUNTIME"]),
        ("/usr/bin/droidloom-", paths["DL_OUT"] + "/bin/droidloom-"),
        ("/usr/bin/droidloomctl", paths["DL_OUT"] + "/bin/droidloomctl"),
        ("/usr/bin/droidloomd", paths["DL_OUT"] + "/bin/droidloomd"),
        ("/usr/bin/adb", paths["DL_ADB"]),
        ("/usr/bin/systemctl", paths["DL_SYSTEMCTL"]),
        ("/usr/bin/systemd-run", paths["DL_SYSTEMD_RUN"]),
        ("/usr/bin/getent", paths["DL_GETENT"]),
        ("/usr/bin/runuser", paths["DL_RUNUSER"]),
        ("/usr/bin/pkexec", paths["DL_PKEXEC"]),
        ("/usr/bin/timeout", paths["DL_TIMEOUT"]),
        ("/usr/bin/ip", paths["DL_IP"]),
        ("/usr/bin/env", paths["DL_ENV"]),
    ]


def patch_paths(src: str, replacements: list[tuple[str, str]]) -> str:
    by_path = dict(replacements)
    pattern = re.compile("|".join(
        re.escape(path) for path in sorted(by_path, key=len, reverse=True)
    ))
    return pattern.sub(lambda match: by_path[match.group()], src)


def main():
    needed = (
        "DL_OUT", "DL_ANDROID", "DL_RUNTIME", "DL_RUNTIME_LIB", "DL_SYSTEMCTL", "DL_GETENT",
        "DL_RUNUSER", "DL_ENV", "DL_ADB", "DL_SYSTEMD_RUN", "DL_PKEXEC", "DL_TIMEOUT", "DL_IP",
    )
    missing = [key for key in needed if not os.environ.get(key)]
    if missing:
        raise RuntimeError("missing Nix output paths: " + ", ".join(missing))

    path = Path("graphics/droidloom-wayland/src/main.rs")
    if not path.is_file():
        raise RuntimeError("expected upstream graphics/droidloom-wayland/src/main.rs")

    paths = {key: os.environ[key] for key in needed}
    replacements = path_replacements(paths)
    # Do not modify Android binaries: only the Rust host source tree.
    for folder in (Path("runtime"), Path("graphics")):
        if not folder.is_dir():
            raise RuntimeError(f"missing upstream host source folder: {folder}")
        for rust in folder.rglob("*.rs"):
            old = rust.read_text()
            updated = patch_paths(old, replacements)
            if updated != old:
                rust.write_text(updated)
    print("Droidloom NixOS: host path patches applied", file=sys.stderr)


if __name__ == "__main__":
    main()
