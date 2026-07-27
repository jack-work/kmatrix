# kmatrix NixOS module — aggregator.
#
# Import this single file (it is `nixosModules.default`) and every concern
# comes along:
#
#   options.nix    — the whole option surface (services.kmatrix.*).
#   synapse.nix    — the homeserver: postgres bootstrap, Synapse itself,
#                    the Caddy site, well-known delegation.
#   provision.nix  — registration shared secret, idempotent account
#                    creation, access-token issuance, the admin CLI.
#   bots.nix       — one hardened systemd unit per declared bot.
#   element.nix    — optional Element web client, behind Authelia.
{
  imports = [
    ./options.nix
    ./synapse.nix
    ./provision.nix
    ./bots.nix
    ./element.nix
  ];
}
