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
              gpu = "0000:01:00.0";
              graphicsBackend = "forwarding";
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
            if builtins.elem "system_heap" moduleEval.config.boot.kernelModules
            then "ok"
            else throw "Droidloom must load the system DMA heap for forwarding backends"
          } > "$out"

          # The lifecycle units come from the host package, which must keep
          # upstream's cgroup delegation and use no /usr path.
          grep -qx 'Delegate=memory pids' ${droidloom.host}/lib/systemd/system/droidloomd.service
          grep -qx 'DelegateSubgroup=supervisor' ${droidloom.host}/lib/systemd/system/droidloomd.service
          if grep -rq '/usr/' ${droidloom.host}/lib/systemd/system \
            ${droidloom.host}/share/systemd/user; then
            echo "installed units still reference /usr paths" >&2
            exit 1
          fi
        '';
        upstream-patch = pkgs.runCommand "droidloom-upstream-patch-check" { } ''
          cp -r ${droidloom.sourceTree} extracted
          chmod -R u+w extracted
          cd extracted
          ${droidloom.substituteHostPaths {
            out = "/nix/store/placeholder-droidloom-host";
            android = "/nix/store/placeholder-droidloom-android/usr/lib/droidloom";
            runtime = "/nix/store/placeholder-droidloom-runtime/usr/share/droidloom";
            runtimeLib = "/nix/store/placeholder-droidloom-runtime/usr/lib/droidloom";
          }}
          grep -rq '/nix/store/placeholder-droidloom-runtime/usr/lib/droidloom/droidloom-package-helper' runtime graphics
          if grep -rq '@droidloomPackageHelper@' runtime graphics; then
            echo "package helper placeholder was not resolved" >&2
            exit 1
          fi
          grep -rq '/nix/store/placeholder-droidloom-android/usr/lib/droidloom/images/images/vendor.raw.img' runtime graphics
          grep -rq '${pkgs.systemd}/bin/systemd-run' runtime graphics
          grep -rq '${pkgs.util-linux}/bin/nsenter' runtime graphics
          if grep -rqE '/usr/bin/(systemd-run|nsenter|cat|sleep)|/usr/bin:/bin' runtime graphics; then
            echo "unpatched upstream host paths remain" >&2
            exit 1
          fi
          echo passed > "$out"
        '';
      };
    };
}
