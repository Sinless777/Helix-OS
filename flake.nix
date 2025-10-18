{
  description = "Helix OS";

  nixConfig = {
    extra-experimental-features = [ "nix-command" "flakes" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      nixosConfigurations = {
        helix = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./hosts/helix
          ];
        };
      };

      packages.${system} = {
        helix-os-base = pkgs.callPackage ./flakes/helix-os-base.nix {};
      };

      devShells.${system}.default =
        pkgs.mkShell {
          packages = with pkgs; [
            git
            nixpkgs-fmt
          ];

          shellHook = ''
            echo "Welcome to the Helix OS dev shell"
          '';
        };
    };
}
