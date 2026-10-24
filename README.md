# Droidloom Flake for NixOS (experimental)

One Git/NGit-ready flake, with a declarative NixOS module and APK list. Android images are fetched from the official `0.1.0-23` release; only **Linux host** Rust programs are rebuilt to adapt `/usr/...` paths and relax the nonstandard `zwlr_output_power_manager_v1` requirement. APK installation happens when the Android service starts. No temporary NixOS configurations, overwriting `/etc/nixos`, or stand-alone test flakes are involved.

## What has / has not been checked

- Verified **statically** against upstream packaging, CLI commands, systemd units and Wayland Rust source on Oct 24 2026. Python patch unit tests run locally.
- Includes a `nix flake check` graph with NixOS module evaluation, a source-patch check, and host build; **these have not yet run on Nix**, since the preparation container has no Nix binary or working external downloads.
- This is **not** a proven working Droidloom deployment. In particular, Umbriel may lack other mandatory Wayland globals besides output-power. The module does not modify or add such compositor protocols.
- Generated files in `/etc/droidloom` are intentionally ordinary root-owned files, **not symlinks**, to satisfy upstream validation. Existing non-managed `cell.json` is saved to `cell.json.before-nixos-flake` before replacement.
- Standalone APKs can be installed/updated from `services.droidloom.applications`; deleting an APK from the Nix list does **not** uninstall the app in Android. No arbitrary APKs are bundled.
- Android app **data remains mutable** at `/var/lib/droidloom` (as intended). Nix declarativity describes the installation and desired APK set, not a reproducible mutable Android user profile.

## Publish to NGit

Put the files at the **root of one repository** (so `flake.nix` is at repository root) and commit them:

```bash
nix flake lock
nix flake check --no-build
nix build -L .#checks.x86_64-linux.module-evaluation
nix build -L .#checks.x86_64-linux.upstream-patch
nix build -L .#host

git add flake.nix flake.lock nix README.md examples tests .gitignore
git commit -m 'Initial Droidloom NixOS flake'
```

The `nix flake lock` step creates a real, pinned `flake.lock`; **there is no fabricated lockfile included**. Once committed, push to your NGit remote normally.

## NixOS integration

Add to your existing main Flake inputs (use the actual NGit clone URL):

```nix
inputs.droidloom.url = "git+https://YOUR-NGIT-CLONE-URL";
# Optional: avoid a second nixpkgs revision:
inputs.droidloom.inputs.nixpkgs.follows = "nixpkgs";
```

Add `inputs.droidloom.nixosModules.default` to the existing host's modules list, **not** to `environment.systemPackages` or a derivation registry.

Declare in an ordinary NixOS module (see `examples/nixos.nix`):

```nix
{ ... }: {
  services.droidloom = {
    enable = true;
    user = "kori";
    uid = 1000;
    manageSubIds = true;
    subIdStart = 100000;
    renderNode = "/dev/dri/renderD128";
    autoStart = false;
    applications = [ ];
  };
}
```

**Disable/remove the earlier standalone Droidloom derivation** from your `environment.systemPackages` registry to avoid two packages exporting the same binary names. This flake's module adds its host package by itself.

Before enabling `manageSubIds`, check that the proposed 100000 contiguous sub-UID/sub-GID range does not overlap another allocation. `uid` must match the real login ID (`id -u`) and `renderNode` must be valid on the target machine. Never build/activate the final config if earlier `nix flake check` or `.#host` fails.

Normal rebuild, using your existing command. Launch inside the Wayland desktop as the normal user:

```bash
systemctl --user start droidloom.service
# Or: droidloomctl start
# On success:
droidloomctl applications
droidloomctl launch com.android.settings
```

Useful failures:

```bash
journalctl --user -b -u droidloom.service -n 80 --no-pager
journalctl -b -u droidloomd.service -n 80 --no-pager
```

### Updating APKs

Add existing local standalone APK paths to `services.droidloom.applications`. Rebuild, then restart the APK-sync user service or Droidloom:

```bash
systemctl --user restart droidloom-apks.service
```

Split APK bundles `.apkm`, `.apks`, `.xapk` are not supported by upstream `droidloomctl install`.

## Repository layout

- `flake.nix` — exposed `nixosModules.default`, `packages.x86_64-linux.*`, `checks.x86_64-linux.*`.
- `nix/module.nix` — UID/GID handling, root-owned cell spec, system/user services, APK install.
- `nix/package.nix` — official release archives, pinned hashes, host build.
- `nix/patch-host.py` — source modifications fail fast if upstream code no longer matches.
- `tests/test_patcher.py` — local Python regression tests.
- `examples/nixos.nix` — example declaration.

Official Droidloom source: https://github.com/denialwm/droidloom . This flake is an independent experimental integration, not an official upstream package.
