#!/usr/bin/env python3
"""Patch host-only Droidloom source for Nix store paths and optional wlr output power.

Fails closed if upstream presenter layout changes. Used by Nix postPatch.
"""

from pathlib import Path
import os
import re
import sys


def replace_exact(text: str, before: str, after: str, label: str) -> str:
    n = text.count(before)
    if n != 1:
        raise RuntimeError(f"{label}: expected exactly one upstream match, got {n}")
    return text.replace(before, after, 1)


def patch_presenter(src: str) -> str:
    src = replace_exact(
        src,
        "output_power_manager: ZwlrOutputPowerManagerV1,",
        "output_power_manager: Option<ZwlrOutputPowerManagerV1>,",
        "App output-power member",
    )
    src = replace_exact(
        src,
        """        let control = self
            .output_power_manager
            .get_output_power(&output, qh, output.clone());
        self.output_power.push(OutputPowerState {
            output,
            control: Some(control),
            powered: None,
        });""",
        """        let control = self.output_power_manager.as_ref().map(|manager| {
            manager.get_output_power(&output, qh, output.clone())
        });
        let powered = if control.is_some() { None } else { Some(true) };
        self.output_power.push(OutputPowerState {
            output,
            control,
            powered,
        });
        if self.output_power_manager.is_none() {
            if let Err(error) = self.recompute_display_power() {
                self.fail(&error);
            }
        }""",
        "new_output optional power manager",
    )
    src = replace_exact(
        src,
        "let output_power_manager: ZwlrOutputPowerManagerV1 = globals.bind(&qh, 1..=1, ())?;",
        """let output_power_manager: Option<ZwlrOutputPowerManagerV1> =
        globals.bind(&qh, 1..=1, ()).ok();
    if output_power_manager.is_none() {
        eprintln!("Droidloom: optional zwlr_output_power_manager_v1 unavailable");
    }""",
        "Wayland output-power binding",
    )
    # Required globals stay required. Distinguish the failure mode in logs.
    for protocol, original in [
        ("wp_viewporter", "let viewporter: WpViewporter = globals.bind(&qh, 1..=1, ())?;"),
        ("wp_fractional_scale_manager_v1", "let fractional_scale_manager: WpFractionalScaleManagerV1 = globals.bind(&qh, 1..=1, ())?;"),
        ("wp_linux_drm_syncobj_manager_v1", "let sync_manager: WpLinuxDrmSyncobjManagerV1 = globals.bind(&qh, 1..=1, ())?;"),
    ]:
        replacement = original.replace(
            "globals.bind(&qh, 1..=1, ())?;",
            'globals.bind(&qh, 1..=1, ()).inspect_err(|e| eprintln!("Droidloom: missing required ' + protocol + ': {e}"))?;',
        )
        src = replace_exact(src, original, replacement, protocol)
    return src


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
        "DL_RUNUSER", "DL_ENV", "DL_ADB", "DL_PKEXEC", "DL_TIMEOUT", "DL_IP",
    )
    missing = [key for key in needed if not os.environ.get(key)]
    if missing:
        raise RuntimeError("missing Nix output paths: " + ", ".join(missing))

    path = Path("graphics/droidloom-wayland/src/main.rs")
    if not path.is_file():
        raise RuntimeError("expected upstream graphics/droidloom-wayland/src/main.rs")

    # Validate all presenter patches before making any changes on disk.
    updated = patch_presenter(path.read_text())
    paths = {key: os.environ[key] for key in needed}
    replacements = path_replacements(paths)
    # Do not modify Android binaries: only the Rust host source tree.
    for folder in (Path("runtime"), Path("graphics")):
        if not folder.is_dir():
            raise RuntimeError(f"missing upstream host source folder: {folder}")
        for rust in folder.rglob("*.rs"):
            old = updated if rust == path else rust.read_text()
            old = patch_paths(old, replacements)
            if rust == path or old != rust.read_text():
                rust.write_text(old)
    print("Droidloom NixOS: host path and output-power patches applied", file=sys.stderr)


if __name__ == "__main__":
    main()
