{
  description = "nixos-gamer — AI processing host (phylax@192.168.85.30)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Encrypted secrets checked into the repo (age-encrypted, decrypted on the
    # box at activation using its SSH host key). See sops.nix / .sops.yaml.
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sops-nix }:
    let
      localSystem = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${localSystem};

      # "gamer-nixos" is an alias from ~/.ssh/config (HostName 192.168.85.30);
      # the explicit root@ overrides the alias's default user.
      host = "root@gamer-nixos";

      # Push the current branch to origin, then rebuild nixos-gamer over SSH.
      # Evaluation happens locally (cheap); the actual building + substituting
      # from binary caches happens ON the target (--build-host == --target-host),
      # which has the stronger internet connection. Nothing is copied between
      # this machine and the box beyond the derivations.
      #   nix run .#deploy
      deploy = pkgs.writeShellApplication {
        name = "deploy";
        runtimeInputs = [ pkgs.git pkgs.openssh pkgs.nixos-rebuild pkgs.nix ];
        text = ''
          branch="$(git rev-parse --abbrev-ref HEAD)"

          echo "Pushing $branch to origin…"
          git push origin "HEAD:$branch"

          echo "Rebuilding nixos-gamer on ${host}…"
          nixos-rebuild switch \
            --flake ".#nixos-gamer" \
            --build-host "${host}" \
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
          sops-nix.nixosModules.sops
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
