{ lib, rustPlatform, fetchurl, runCommand, zstd, gnutar,
  python3, pkg-config, clang, llvmPackages, libdrm, libgbm, mesa, wayland,
  libxkbcommon, pipewire, systemd, glibc, util-linux, coreutils,
  android-tools, polkit, nftables, iproute2, iptables, e2fsprogs,
  libGL, libffi, zlib, vulkan-loader, makeWrapper }:
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
    nativeBuildInputs = [ pkg-config clang llvmPackages.libclang python3 makeWrapper ];
    LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";
    buildInputs = [
      libdrm libgbm mesa wayland libxkbcommon pipewire libGL libffi zlib
      vulkan-loader
    ];
    doCheck = false;
    # Patch Rust source paths, not embedded Android code. NixOS does not
    # supply /usr/bin/droidloom-* or /usr/lib/droidloom.
    postPatch = ''
      export DL_OUT="$out"
      export DL_ANDROID="${androidArtifacts}/usr/lib/droidloom"
      export DL_RUNTIME="${runtimeMetadata}/usr/share/droidloom"
      export DL_RUNTIME_LIB="${runtimeMetadata}/usr/lib/droidloom"
      export DL_SYSTEMCTL="${systemd}/bin/systemctl"
      export DL_GETENT="${glibc.bin}/bin/getent"
      export DL_RUNUSER="${util-linux}/bin/runuser"
      export DL_ENV="${coreutils}/bin/env"
      export DL_ADB="${android-tools}/bin/adb"
      export DL_PKEXEC="${polkit}/bin/pkexec"
      export DL_TIMEOUT="${coreutils}/bin/timeout"
      export DL_IP="${iproute2}/bin/ip"
      ${python3}/bin/python3 ${./patch-host.py}
    '';

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
  inherit host androidArtifacts runtimeMetadata sourceArchive;
}
