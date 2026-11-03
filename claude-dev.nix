{ config, pkgs, claude-code-nix, ... }:

# Claude Code as a development environment on the box, mirroring the laptop.
#
# The laptop keeps its Claude Code configuration in the nix-configs repo
# (github:euporos/nix-configs, checked out at /home/phylax/config) and
# home-manager symlinks ~/.claude/{settings.json,CLAUDE.md,skills} to
# home/.claude/ there. The box has no home-manager, so the same three
# symlinks are created by systemd-tmpfiles. Sharing happens through git:
# clone nix-configs to /home/phylax/config once (see README), then `git pull`
# there whenever the laptop's settings move. settings.json's Stop hook
# auto-commits in-place edits of those files, so pushes from the box keep
# both sides in sync (needs the box's GitHub SSH key as a deploy key or
# user key with push rights).
#
# Not shared (per-machine by design): ~/.claude.json (login, MCP servers —
# the laptop's emacs/playwright servers do not exist here), plugins (installed
# per machine from the marketplace on first use), project memories.
#
# The game itself is built from its own flake (github:euporos/7kaa_epr,
# branch ai-ml); its devShell loads via direnv in the clone.

let
  claude = claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
  cfgDir = "/home/phylax/config/home/.claude";
in
{
  environment.systemPackages = with pkgs; [
    claude
    uv                            # ml/ venv (cu126 torch, see CLAUDE.md)
    parallel                      # scripts/sim-batch
    perf
    gh
  ];

  # Same as the laptop: /bin and /usr/bin are served from PATH by envfs, so
  # scripts with "#!/bin/bash" (the game's autogen.sh, many build helpers)
  # run; NixOS itself provides only /bin/sh and /usr/bin/env.
  services.envfs.enable = true;

  # Same as the laptop: direnv + nix-direnv so a repo's flake devShell loads
  # on cd (the 7kaa_epr clone has an .envrc).
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # ~/.claude/{settings.json,CLAUDE.md,skills} -> the nix-configs checkout.
  # L+ replaces whatever Claude Code created there first; the links dangle
  # until /home/phylax/config is cloned.
  systemd.tmpfiles.rules = [
    "d  /home/phylax/.claude 0700 phylax users -"
    "L+ /home/phylax/.claude/settings.json - - - - ${cfgDir}/settings.json"
    "L+ /home/phylax/.claude/CLAUDE.md - - - - ${cfgDir}/CLAUDE.md"
    "L+ /home/phylax/.claude/skills - - - - ${cfgDir}/skills"
  ];
}
