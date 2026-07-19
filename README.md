# nixos-gamer

Flake-based NixOS configuration for the host at **`phylax@192.168.85.30`**.

Despite the name, this is not a gaming machine — the name comes from its Windows
gaming dual-boot. This NixOS side is being set up as a **headless AI processing
host**. Right now it only lays the groundwork (base system, SSH, deploy tooling);
no AI/GPU stack is enabled yet.

## Hardware

- AMD Ryzen 5 1600X, UEFI, systemd-boot
- NVIDIA GTX 1080 Ti (currently on the `nouveau` driver — no proprietary/CUDA
  stack configured yet; that's the obvious next step for AI workloads)
- Root: `ext4` on `nvme0n1`; several extra SATA/HDD disks present but unmanaged here

`hardware-configuration.nix` was captured from the live machine and carries the
real disk UUIDs — regenerate it with `nixos-generate-config --show-hardware-config`
on the box if the disk layout changes.

## Layout

| file                        | purpose                                         |
| --------------------------- | ----------------------------------------------- |
| `flake.nix`                 | inputs, `nixosConfigurations.nixos-gamer`, `deploy` app |
| `configuration.nix`         | system config (users, SSH, locale, nix, packages) |
| `hardware-configuration.nix`| generated hardware scan (real UUIDs)            |

## Deploy

```sh
nix run .#deploy
```

This pushes the current branch to `origin`, then builds locally and activates the
closure on the target over SSH (`nixos-rebuild switch --target-host root@192.168.85.30`).

### One-time bootstrap

The `deploy` app connects as **root** and needs `phylax` to be a trusted Nix user —
both are set by *this* configuration, so the very first activation is a
chicken-and-egg and must be done on the box:

1. Add a git remote named `origin` and push:
   ```sh
   git remote add origin <url>
   git push -u origin main
   ```
2. On the machine, build & switch once as root:
   ```sh
   ssh phylax@192.168.85.30
   git clone <url> ~/nixos-gamer && cd ~/nixos-gamer
   sudo nixos-rebuild switch --flake .#nixos-gamer
   ```

After that first switch, root's SSH key and `phylax`'s trusted-user status are in
place, and `nix run .#deploy` works from this repo without any password prompt.

> Note: this config sets `PasswordAuthentication = false` and installs the
> `services@olivermotz.com` key for both `phylax` and `root`. That key is already
> in `phylax`'s stateful `authorized_keys` on the box, so you will not be locked
> out by the first switch.
