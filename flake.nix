{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { nixpkgs, ... }:

    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

    in
    {
      packages = forEachSystem (system:

        let
          pkgs = import nixpkgs { inherit system; };

        in
        {
          default = pkgs.writeShellApplication {
            name = "universal-build";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnutar
              pkgs.gzip
              pkgs.nixVersions.nix_2_31
            ];
            inheritPath = false;
            text = builtins.readFile ./src/main.sh;
          };
        }

      );
    };
}
