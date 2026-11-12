{
  description = "Droidloom on NixOS: declarative module, pinned Android image and patched Wayland host";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      droidloom = pkgs.callPackage ./nix/package.nix { };
      # Small synthetic NixOS host to type-check module wiring before touching
      # the user's actual NixOS configuration.
      moduleEval = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.default
          ({ ... }: {
            networking.hostName = "droidloom-module-eval";
            boot.loader.grub.devices = [ "nodev" ];
            fileSystems."/" = {
              device = "/dev/null";
              fsType = "tmpfs";
            };
            system.stateVersion = "25.11";
            users.users.kori = {
              isNormalUser = true;
              uid = 1000;
            };
            services.droidloom = {
              enable = true;
              user = "kori";
              uid = 1000;
              manageSubIds = true;
            };
          })
        ];
      };
    in
    {
      nixosModules.default = import ./nix/module.nix;
      nixosModules.droidloom = self.nixosModules.default;

      packages.${system} = {
        default = droidloom.host;
        host = droidloom.host;
        android-artifacts = droidloom.androidArtifacts;
        runtime-metadata = droidloom.runtimeMetadata;
      };

      # `nix flake check --no-build` evaluates these derivations without
      # compiling Android or rebuilding the user's NixOS system.
      checks.${system} = {
        host = droidloom.host;
        module-evaluation = pkgs.runCommand "droidloom-module-evaluation" { } ''
          echo ${
            if moduleEval.config.systemd.services ? droidloomd
              && moduleEval.config.systemd.services.droidloomd.serviceConfig.Delegate
              && moduleEval.config.systemd.services.droidloomd.serviceConfig.DelegateSubgroup == "droidloom"
            then "ok"
            else throw "droidloomd service must delegate the droidloom cgroup subgroup"
          } > "$out"
        '';
        upstream-patch = pkgs.runCommand "droidloom-upstream-patch-check" {
          nativeBuildInputs = with pkgs; [ python3 gnutar gzip ];
        } ''
          mkdir -p extracted
          tar -xzf ${droidloom.sourceArchive} -C extracted --strip-components=1
          cd extracted
          export DL_OUT=/nix/store/placeholder-droidloom-host
          export DL_ANDROID=/nix/store/placeholder-droidloom-android/usr/lib/droidloom
          export DL_RUNTIME=/nix/store/placeholder-droidloom-runtime/usr/share/droidloom
          export DL_RUNTIME_LIB=/nix/store/placeholder-droidloom-runtime/usr/lib/droidloom
          export DL_SYSTEMCTL=/run/current-system/sw/bin/systemctl
          export DL_GETENT=/run/current-system/sw/bin/getent
          export DL_RUNUSER=/run/current-system/sw/bin/runuser
          export DL_ENV=/run/current-system/sw/bin/env
          export DL_ADB=/run/current-system/sw/bin/adb
          export DL_PKEXEC=/run/current-system/sw/bin/pkexec
          export DL_TIMEOUT=/run/current-system/sw/bin/timeout
          export DL_IP=/run/current-system/sw/bin/ip
          ${pkgs.python3}/bin/python3 ${./nix/patch-host.py}
          echo passed > "$out"
        '';
      };
    };
}
