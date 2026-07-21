{ config, ... }:

# Encrypted secrets, checked into the repo as ciphertext (secrets/secrets.yaml).
#
# How it works:
#   - secrets are age-encrypted to two recipients (see .sops.yaml): this box's
#     SSH *host* key (so the machine can decrypt at activation) and the admin
#     age key held in the operator's pass store (so a human can `sops edit`).
#   - only ciphertext lives in git; the private host key never leaves the box
#     and never enters the repo, so pushing this repo anywhere is safe.
#   - at nixos-rebuild switch time sops-nix decrypts each secret into
#     /run/secrets/<name> (a tmpfs, mode 0400 root by default) and the config
#     below points services at config.sops.secrets.<name>.path instead of the
#     old hand-placed /etc/nixos/secrets/... and /var/lib/whisper/... files.
#
# Editing the secrets (operator, on a workstation that holds the admin key):
#   SOPS_AGE_KEY="$(pass show admin-age-keys/universal | grep -v '^#')" \
#     sops secrets/secrets.yaml
# (run pass yourself — the Claude Code harness is blocked from invoking it.)
{
  sops.defaultSopsFile = ./secrets/secrets.yaml;

  # Decrypt using the box's SSH host key (ed25519), converted to an age
  # identity by sops-nix. This is the machine's half of the recipient pair;
  # it already exists on the box and is never copied into the repo.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # HF token for pyannote diarization. Stored as a full env-file line
  # (HF_TOKEN=hf_...), because whisper.nix's worker sources it with `.`.
  # Rendered to /run/secrets/hf-token.
  sops.secrets."hf-token" = { };

  # CIFS credentials for the NAS delivery mount (username=/password= file,
  # consumed by mount.cifs via the credentials= option in configuration.nix).
  sops.secrets."smb-secrets" = { };
}
