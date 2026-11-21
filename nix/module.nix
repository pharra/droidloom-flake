{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.services.droidloom;
  packages = pkgs.callPackage ./package.nix { };
  host = packages.host;
  artifacts = packages.androidArtifacts;
  metadata = packages.runtimeMetadata;
  uid = toString cfg.uid;
  userName = cfg.user;
  apkInstallScript = pkgs.writeShellScript "droidloom-declarative-apks" ''
    set -eu
    ${packages.host}/bin/droidloomctl wait
    ${lib.concatMapStringsSep "\n" (apk: ''
      ${packages.host}/bin/droidloomctl install --user 0 ${lib.escapeShellArg (toString apk)}
    '') cfg.applications}
  '';
  dataDir = "/var/lib/droidloom/users/${uid}/data";

  # Upstream's installer writes these to /usr/lib/environment.d; the package
  # points the units at /etc/droidloom/runtime.env so one file carries this
  # host's user, render node and GPU choice.
  runtimeEnv = pkgs.writeText "droidloom-runtime.env" (''
    DROIDLOOM_HOST_PEER_PID=0
    DROIDLOOM_HOST_PEER_UID=${uid}
    DROIDLOOM_HOST_PEER_GID=${uid}
    DROIDLOOM_RENDER_NODE=${cfg.renderNode}
  '' + lib.optionalString (cfg.gpu != null) "DROIDLOOM_GPU=${cfg.gpu}\n");

  # Build the cell spec from the exact matching upstream package template.
  # Keep the Android binary payload entirely in the Nix store.
  cellSpec = pkgs.runCommand "droidloom-nixos-cell-${uid}.json" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    export DL_IMAGE_ROOT="${artifacts}/usr/lib/droidloom"
    export DL_UID="${uid}"
    export DL_RENDER_NODE="${cfg.renderNode}"
    export DL_GPU="${if cfg.gpu == null then "" else cfg.gpu}"
    export DL_GRAPHICS_BACKEND="${cfg.graphicsBackend}"
    export DL_DATA_DIR="${dataDir}"
    export DL_SUB_ID_START="${toString cfg.subIdStart}"
    ${pkgs.python3}/bin/python3 - <<'PY'
import json
import os
from pathlib import Path

source = Path("${metadata}/usr/share/droidloom/cell-template.json")
spec = json.loads(source.read_text())
root = os.environ["DL_IMAGE_ROOT"]

def rewrite(value):
    if isinstance(value, str) and value.startswith("/usr/lib/droidloom/"):
        return root + value[len("/usr/lib/droidloom"):]
    if isinstance(value, list):
        return [rewrite(item) for item in value]
    if isinstance(value, dict):
        return {key: rewrite(item) for key, item in value.items()}
    return value

spec = rewrite(spec)
uid = int(os.environ["DL_UID"])
spec.update({
    "host_uid": uid,
    "render_node": os.environ["DL_RENDER_NODE"],
    "data_dir": os.environ["DL_DATA_DIR"],
    "runtime_dir": f"/run/droidloom/cells/u{uid}",
    "denial_socket": f"/run/user/{uid}/droidloom/native-bridge.sock",
    "shared_storage_directories": [],
    "subordinate_uids": {"start": int(os.environ["DL_SUB_ID_START"]), "count": 100000},
    "subordinate_gids": {"start": int(os.environ["DL_SUB_ID_START"]), "count": 100000},
})
if os.environ["DL_GPU"]:
    spec["gpu"] = os.environ["DL_GPU"]
else:
    spec.pop("gpu", None)
spec["graphics_backend"] = os.environ["DL_GRAPHICS_BACKEND"]
Path(os.environ["out"]).write_text(json.dumps(spec, indent=2) + "\n")
PY
  '';
in
{
  options.services.droidloom = {
    enable = mkEnableOption "experimental native Droidloom Android runtime";
    user = mkOption {
      type = types.str;
      default = "";
      example = "kori";
      description = "Existing host login used to run the Wayland session.";
    };
    uid = mkOption {
      type = types.ints.positive;
      default = 1000;
      description = "Numeric UID of the existing Wayland user. Must match id -u.";
    };
    renderNode = mkOption {
      type = types.str;
      default = "/dev/dri/renderD128";
      description = "DRM render node exposed to Android. Check /sys/class/drm before enabling.";
    };
    gpu = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "0000:03:00.0";
      description = "GPU vendor or PCI address used by Android Vulkan applications.";
    };
    graphicsBackend = mkOption {
      type = types.enum [ "drm" "drm_dma_heap" "kgsl_dma_heap" "forwarding" ];
      default = "drm";
      description = "Android graphics backend; use forwarding for NVIDIA GPUs without an Android driver.";
    };
    applications = mkOption {
      type = types.listOf (types.either types.path types.package);
      default = [];
      example = lib.literalExpression ''[ ./apks/example.apk ]'';
      description = ''Standalone APKs to install or update after Android starts.
        Files added or changed here are stored under /nix/store. Removing an
        APK from this list does not uninstall it from the Android user profile.'';
    };
    autoStart = mkOption {
      type = types.bool;
      default = false;
      description = "Start Droidloom automatically upon entering the graphical session";
    };
    manageSubIds = mkOption {
      type = types.bool;
      default = false;
      description = "Declare a contiguous subordinate UID/GID range for the Droidloom user";
    };
    subIdStart = mkOption {
      type = types.ints.positive;
      default = 100000;
      description = "Start of the 100000-id subordinate ranges (check collisions first)";
    };
    enableIpv4Forwarding = mkOption {
      type = types.bool;
      default = false;
      description = "Opt in to host IPv4 forwarding; may interact with firewall or VPN policies.";
    };
  };

  config = mkIf cfg.enable {
    # Only edit the declared user's subordinate ID maps when explicitly enabled.
    users.users.${userName} = lib.mkIf cfg.manageSubIds {
      autoSubUidGidRange = lib.mkForce false;
      subUidRanges = lib.mkForce [ { startUid = cfg.subIdStart; count = 100000; } ];
      subGidRanges = lib.mkForce [ { startGid = cfg.subIdStart; count = 100000; } ];
    };
    assertions = [
      {
        assertion = cfg.user != "";
        message = "services.droidloom.user must be an existing Linux login";
      }
      {
        assertion = lib.hasPrefix "/dev/dri/renderD" cfg.renderNode;
        message = "services.droidloom.renderNode must be an absolute DRM render node";
      }
    ];

    environment.systemPackages = [ host pkgs.android-tools ];
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            subject.user === ${builtins.toJSON cfg.user} &&
            action.lookup("unit") === "droidloomd.service" &&
            (action.lookup("verb") === "start" || action.lookup("verb") === "stop")) {
          return polkit.Result.YES;
        }
      });
    '';

    boot.kernelModules =
      [ "binder_linux" "fuse" ]
      ++ lib.optionals (cfg.graphicsBackend != "drm") [ "system_heap" ];
    boot.kernel.sysctl = mkIf cfg.enableIpv4Forwarding {
      "net.ipv4.ip_forward" = 1;
    };

    # The daemon validates ownership of the spec and refuses a symlink.
    # Keep /etc/droidloom/cell.json a regular root-owned file.
    system.activationScripts.droidloom = {
      deps = [ "etc" ];
      text = ''
        if [ -L /etc/droidloom ]; then
          echo 'Droidloom: refusing a symlinked /etc/droidloom directory' >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/install -d -m 0755 /etc/droidloom
        ${pkgs.coreutils}/bin/install -m 0644 ${runtimeEnv} /etc/droidloom/runtime.env
        if [ -e /etc/droidloom/cell.json ] && [ ! -e /etc/droidloom/.nixos-port-managed ]; then
          # Preserve configuration created by a previous non-NixOS installation.
          ${pkgs.coreutils}/bin/cp -a /etc/droidloom/cell.json /etc/droidloom/cell.json.before-nixos-flake
        fi
        ${pkgs.coreutils}/bin/install -m 0644 ${cellSpec} /etc/droidloom/cell.json.nix-new
        ${pkgs.coreutils}/bin/mv -f /etc/droidloom/cell.json.nix-new /etc/droidloom/cell.json
        ${pkgs.coreutils}/bin/touch /etc/droidloom/.nixos-port-managed

      '';
    };

    # The host package installs upstream's lifecycle units under
    # lib/systemd/{system,user}. NixOS links them into /etc/systemd, so this
    # module only supplies what upstream cannot know: the runner's PATH, the
    # storage it creates before Android starts, and the session user.
    systemd.packages = [ host ];

    systemd.services.droidloomd = {
      path = with pkgs; [
        coreutils util-linux iproute2 nftables iptables android-tools
        e2fsprogs gnutar zstd rsync systemd procps findutils gnugrep gnused
      ];
      preStart = ''
        # Only create missing directories. Never reset ownership/mode of data
        # that Android has already initialized.
        for dir in /var/lib/droidloom /var/lib/droidloom/users \
          /var/lib/droidloom/users/${uid} ${dataDir} \
          ${dataDir}/data ${dataDir}/metadata; do
          if [ -L "$dir" ]; then
            echo "Refusing symlinked Android storage directory: $dir" >&2
            exit 1
          fi
          if [ ! -e "$dir" ]; then
            mkdir "$dir"
            if [ "$dir" = "${dataDir}" ] || [ "$dir" = "${dataDir}/data" ] || [ "$dir" = "${dataDir}/metadata" ]; then
              chmod 0700 "$dir"
            else
              chmod 0755 "$dir"
            fi
          fi
        done
      '';
      # Not enabled at boot: the user unit starts it on demand.
    };

    systemd.user.services.droidloom = {
      unitConfig.ConditionUser = cfg.user;
      wantedBy = lib.optionals cfg.autoStart [ "graphical-session.target" ];
    };

    systemd.user.services.droidloom-apks = lib.mkIf (cfg.applications != []) {
      description = "Install declared Droidloom APKs after Android boots";
      after = [ "droidloom.service" ];
      wantedBy = [ "droidloom.service" ];
      unitConfig.ConditionUser = cfg.user;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = apkInstallScript;
        TimeoutStartSec = "360s";
      };
    };

  };
}
