# Droidloom Flake for NixOS (experimental)

One Git-ready flake, with a declarative NixOS module and APK list. Android images are fetched from the official `0.1.0-33` release; **Linux host** Rust programs are rebuilt to adapt upstream `/usr/...` paths for NixOS. The Wayland host still requires the upstream `zwlr_output_power_manager_v1` protocol. APK installation happens when the Android service starts. No temporary NixOS configurations, overwriting `/etc/nixos`, or stand-alone test flakes are involved.

## What has / has not been checked

- Checked against the official `0.1.0-33` source and package metadata, including its new device and GPU brokers. The flake currently targets `x86_64-linux`; the upstream installer also supports `aarch64`, which this flake does not yet package.
- `nix flake check --no-build`, the upstream patch derivation, and Python patcher tests pass. A successful build still does not prove a working deployment; Android cells and compositor compatibility require on-device validation.
- This is **not** a proven working Droidloom deployment. Compositor compatibility and Android cells still require on-device validation. The module does not add or modify compositor protocols.
- Generated files in `/etc/droidloom` are intentionally ordinary root-owned files, **not symlinks**, to satisfy upstream validation. Existing non-managed `cell.json` is saved to `cell.json.before-nixos-flake` before replacement.
- The system daemon delegates a `droidloom` cgroup subgroup to Android. This keeps Android's cgroup namespace root below the systemd unit root so `netd` can attach its egress BPF program.
- The generated cell spec replaces Android's Advanced Protection config with a store-backed copy from the matching system image, removing `featureFlag` attributes that crash the release 33 framework when its Aconfig package is unavailable.
- Standalone APKs can be installed/updated from `services.droidloom.applications`; deleting an APK from the Nix list does **not** uninstall the app in Android. No arbitrary APKs are bundled.
- Android app **data remains mutable** at `/var/lib/droidloom` (as intended). Nix declarativity describes the installation and desired APK set, not a reproducible mutable Android user profile.

## Publish to GitHub

This flake lives at the repository root. To publish changes to the GitHub
repository:

```bash
nix flake check --no-build
nix build -L .#checks.x86_64-linux.module-evaluation
nix build -L .#checks.x86_64-linux.upstream-patch

git remote add github git@github.com:pharra/droidloom-flake.git
git push -u github main
```

If the `github` remote is already configured, skip `git remote add`.

## NixOS integration

Add this input to your existing NixOS flake:

```nix
inputs.droidloom.url = "github:pharra/droidloom-flake";
# Optional: avoid a second nixpkgs revision:
inputs.droidloom.inputs.nixpkgs.follows = "nixpkgs";
```

Add `inputs.droidloom.nixosModules.default` to the existing host's modules list, **not** to `environment.systemPackages` or a derivation registry.

Declare this in an ordinary NixOS module:

```nix
{ ... }: {
  services.droidloom = {
    enable = true;
    user = "kori";
    uid = 1000;
    manageSubIds = true;
    subIdStart = 100000;
    renderNode = "/dev/dri/renderD128";
    # Select "forwarding" for NVIDIA GPUs without an Android Vulkan driver.
    graphicsBackend = "drm";
    # Optional PCI address for Android Vulkan, e.g. "0000:03:00.0".
    gpu = null;
    autoStart = false;
    applications = [ ];
  };
}
```

The current upstream release includes host device and Vulkan brokers in
addition to the original audio broker. The module provides their socket-
activated user services; set `services.droidloom.gpu` to the GPU's PCI address
to select it for Android Vulkan. NVIDIA users should also set
`services.droidloom.graphicsBackend = "forwarding"`; this enables the system
DMA heap required by the forwarding backend.

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
- `nix/Cargo.lock` — Cargo dependencies pinned to the same official source release.
- `nix/patch-host.py` — adapts upstream paths to Nix store locations, including the runtime package helper; Wayland protocol behavior is left unchanged.
- `tests/test_patcher.py` — local Python regression tests.

Official Droidloom source: https://github.com/denialwm/droidloom . This flake is an independent experimental integration, not an official upstream package.
