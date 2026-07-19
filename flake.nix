{
  description = "nixos-gamer — AI processing host (phylax@192.168.85.30)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      localSystem = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${localSystem};

      host = "root@192.168.85.30";

      # Push the current branch to origin, then build locally and activate the
      # closure on the target over SSH (no GitHub round-trip on the box).
      #   nix run .#deploy
      deploy = pkgs.writeShellApplication {
        name = "deploy";
        runtimeInputs = [ pkgs.git pkgs.openssh pkgs.nixos-rebuild pkgs.nix ];
        text = ''
          branch="$(git rev-parse --abbrev-ref HEAD)"

          echo "Pushing $branch to origin…"
          git push origin "HEAD:$branch"

          echo "Rebuilding nixos-gamer (${host})…"
          nixos-rebuild switch \
            --flake ".#nixos-gamer" \
            --target-host "${host}" \
            --use-substitutes

          echo "Deployment complete!"
        '';
      };
    in
    {
      nixosConfigurations.nixos-gamer = nixpkgs.lib.nixosSystem {
        system = localSystem;
        modules = [
          ./hardware-configuration.nix
          ./configuration.nix
        ];
      };

      packages.${localSystem}.deploy = deploy;

      apps.${localSystem} = {
        deploy = {
          type = "app";
          program = "${deploy}/bin/deploy";
        };
        default = self.apps.${localSystem}.deploy;
      };
    };
}
