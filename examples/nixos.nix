# Import this from a regular NixOS module; do NOT put it in systemPackages.
{ inputs, ... }:
{
  imports = [ inputs.droidloom.nixosModules.default ];

  services.droidloom = {
    enable = true;
    user = "kori";
    uid = 1000; # run `id -u` to verify
    renderNode = "/dev/dri/renderD128";
    manageSubIds = true;
    subIdStart = 100000;
    autoStart = false;
    applications = [
      # ./apk/your-app.apk
    ];
  };
}
