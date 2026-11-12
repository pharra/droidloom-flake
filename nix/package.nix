{ lib, rustPlatform, fetchurl, runCommand, zstd, gnutar,
  python3, pkg-config, clang, llvmPackages, libdrm, libgbm, mesa, wayland,
  libxkbcommon, pipewire, systemd, glibc, util-linux, coreutils,
  android-tools, polkit, nftables, iproute2, iptables, e2fsprogs, rsync,
  libGL, libffi, zlib, vulkan-loader, glslang, makeWrapper, erofs-utils }:
let
  upstreamVersion = "0.1.0-33";
  upstream = "https://github.com/denialwm/droidloom/releases/download/packages";

  sourceArchive = fetchurl {
    url = "${upstream}/droidloom-source-${upstreamVersion}.tar.gz";
    hash = "sha256-1Tk0hpLMFFbaM6RuFBUDG2uUZlnGWwFsrsYhRBW8w4I=";
  };
  runtimeArchive = fetchurl {
    url = "${upstream}/droidloom-runtime-${upstreamVersion}-x86_64.pkg.tar.zst";
    hash = "sha256-c26gG69RetZUdEI2v+NaSz+rQVCp4RJORNdzJeb7T5E=";
  };
  imageArchive = fetchurl {
    url = "${upstream}/droidloom-image-${upstreamVersion}-x86_64.pkg.tar.zst";
    hash = "sha256-aE+jMQPofDTLwN1bmJwB7rDH7zTEkKaMZ+7w4BwdCmo=";
  };

  unpackPackage = kind: archive:
    runCommand "droidloom-${kind}-payload-${upstreamVersion}" {
      nativeBuildInputs = [ zstd gnutar ];
    } ''
      mkdir -p "$out"
      tar --use-compress-program=unzstd --no-same-owner -xf ${archive} -C "$out" usr
    '';

  # Both packages are from the same upstream release. The Android files are
  # kept bit-for-bit unchanged: patching host ELF files in this tree is unsafe.
  androidArtifacts = unpackPackage "android" imageArchive;
  runtimeMetadata = unpackPackage "runtime" runtimeArchive;

  # Runtime PATH for code paths that fall back to an FHS bin directory or exec
  # bare tool names.
  hostBinPath = lib.makeBinPath [
    coreutils util-linux systemd glibc.bin android-tools iproute2
    nftables iptables e2fsprogs gnutar zstd rsync polkit
  ];

  # Upstream host sources hard-code Arch/FHS paths. `substituteInPlace`
  # applies replacements in order and re-scans earlier results, so the package
  # helper is parked on a placeholder before the generic `/usr/lib/droidloom`
  # rule would rewrite the runtime path it is about to receive.
  substituteHostPaths = { out, android, runtime, runtimeLib }:
    ''
      substituteInPlace $(find runtime graphics -name '*.rs') \
        --replace-quiet "/usr/share/droidloom/package.json" "/var/empty/droidloom-nixos-not-pacman" \
        --replace-quiet "/usr/share/droidloom" "${runtime}" \
        --replace-quiet "/usr/lib/droidloom/droidloom-package-helper" "@droidloomPackageHelper@" \
        --replace-quiet "/usr/lib/droidloom" "${android}" \
        --replace-quiet "@droidloomPackageHelper@" "${runtimeLib}/droidloom-package-helper" \
        --replace-quiet "/usr/bin:/bin" "${hostBinPath}" \
        --replace-quiet "/usr/bin/droidloom-" "${out}/bin/droidloom-" \
        --replace-quiet "/usr/bin/droidloomctl" "${out}/bin/droidloomctl" \
        --replace-quiet "/usr/bin/droidloomd" "${out}/bin/droidloomd" \
        --replace-quiet "/usr/bin/adb" "${android-tools}/bin/adb" \
        --replace-quiet "/usr/bin/systemctl" "${systemd}/bin/systemctl" \
        --replace-quiet "/usr/bin/systemd-run" "${systemd}/bin/systemd-run" \
        --replace-quiet "/usr/bin/getent" "${glibc.bin}/bin/getent" \
        --replace-quiet "/usr/bin/runuser" "${util-linux}/bin/runuser" \
        --replace-quiet "/usr/bin/nsenter" "${util-linux}/bin/nsenter" \
        --replace-quiet "/usr/bin/pkexec" "${polkit}/bin/pkexec" \
        --replace-quiet "/usr/bin/timeout" "${coreutils}/bin/timeout" \
        --replace-quiet "/usr/bin/sleep" "${coreutils}/bin/sleep" \
        --replace-quiet "/usr/bin/cat" "${coreutils}/bin/cat" \
        --replace-quiet "/usr/bin/ip" "${iproute2}/bin/ip" \
        --replace-quiet "/usr/bin/env" "${coreutils}/bin/env"
    '';

  advancedProtectionConfig = runCommand "droidloom-advanced-protection-config-${upstreamVersion}" {
    nativeBuildInputs = [ erofs-utils python3 ];
  } ''
    ${erofs-utils}/bin/fsck.erofs \
      --extract="$TMPDIR/advanced-protection-config.xml" \
      --path=/system/etc/advanced-protection-config/advanced-protection-config.xml \
      ${androidArtifacts}/usr/lib/droidloom/images/images/system.img
    ${python3}/bin/python3 - "$TMPDIR/advanced-protection-config.xml" "$out" <<'PY'
import sys
from xml.etree import ElementTree as ET

source, destination = sys.argv[1:]
parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
tree = ET.parse(source, parser=parser)
for element in tree.iter("protection"):
    element.attrib.pop("featureFlag", None)
tree.write(destination, encoding="utf-8", xml_declaration=True)
PY
  '';

  host = rustPlatform.buildRustPackage {
    pname = "droidloom-nixos-host";
    version = upstreamVersion;
    src = sourceArchive;
    cargoLock.lockFile = ./Cargo.lock;
    cargoBuildFlags = [
      "-p" "droidloom-supervisor"
      "-p" "droidloom-wayland"
      "-p" "droidloom-applications"
      "-p" "droidloom-audio"
      "-p" "droidloom-devices"
      "-p" "droidloom-doctor"
      "-p" "droidloom-gpu-server"
    ];
    nativeBuildInputs = [ pkg-config clang llvmPackages.libclang python3 glslang makeWrapper ];
    LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";
    buildInputs = [
      libdrm libgbm mesa wayland libxkbcommon pipewire libGL libffi zlib
      vulkan-loader
    ];
    doCheck = false;
    # Patch Rust source paths, not embedded Android code. NixOS does not
    # supply /usr/bin/droidloom-* or /usr/lib/droidloom.
    postPatch = substituteHostPaths {
      out = "$out";
      android = "${androidArtifacts}/usr/lib/droidloom";
      runtime = "${runtimeMetadata}/usr/share/droidloom";
      runtimeLib = "${runtimeMetadata}/usr/lib/droidloom";
    };

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      for name in droidloomd droidloomctl droidloom-supervisor droidloom-wayland droidloom-applications droidloom-audio droidloom-devices droidloom-doctor droidloom-gpu-server; do
        install -m755 "target/x86_64-unknown-linux-gnu/release/$name" "$out/bin/$name"
      done
      wrapProgram "$out/bin/droidloom-gpu-server" \
        --prefix LD_LIBRARY_PATH : "${vulkan-loader}/lib"
      runHook postInstall
    '';
    # Host tools were compiled against the matching upstream release. An
    # Android cell boot still requires on-device validation and kernel support.
    meta = {
      description = "Experimental Droidloom Linux host programs for NixOS";
      homepage = "https://github.com/denialwm/droidloom";
      license = lib.licenses.gpl3Plus;
      platforms = [ "x86_64-linux" ];
    };
  };
in {
  inherit host androidArtifacts runtimeMetadata advancedProtectionConfig sourceArchive
    substituteHostPaths;
}
