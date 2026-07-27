# kmatrix — the option surface.
#
# Everything a host config touches lives here. The shape mirrors the rest
# of the stack: the site names a *subdomain*, never the zone; the platform
# (services.kelliher-web.baseDomains) supplies the zone.
{ config, lib, ... }:
let
  cfg = config.services.kmatrix;

  baseDomain = lib.head (config.services.kelliher-web.baseDomains ++ [ "invalid" ]);

  accountCommon = {
    displayName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Echo Bot";
      description = ''
        Matrix display name, set on every provision run. Null leaves
        whatever the account already has.
      '';
    };

    admin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Grant Synapse *server admin* rights — full access to the
        `/_synapse/admin` API (create users, list rooms, deactivate
        accounts). Only meaningful for accounts you trust with the
        whole homeserver.
      '';
    };

    autoJoin = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "#lab:kelliher.info" ];
      description = ''
        Room aliases or IDs to join at provision time. Joining an
        invite-only room the account was never invited to logs a
        warning and continues — provisioning never fails on this.
      '';
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/matrix-jack-password";
      description = ''
        Path to a file holding this account's password (sops-nix,
        typically). When null, a random password is generated once at
        first provision and kept in the account's state directory —
        read it with
        `ssh spain 'sudo cat /var/lib/kmatrix/accounts/<name>/password'`.

        Note: the password is only used at *registration* time (and to
        mint an access token). Changing this file later does not reset
        the password of an account that already exists — do that with
        `kmatrix-admin` or from a client.
      '';
    };
  };
in
{
  options.services.kmatrix = {
    enable = lib.mkEnableOption "kmatrix — Synapse homeserver on kelliher-web";

    serverName = lib.mkOption {
      type = lib.types.str;
      default = baseDomain;
      example = "kelliher.info";
      description = ''
        The homeserver's `server_name` — the part after the colon in
        every MXID (`@jack:kelliher.info`). **Effectively immutable
        once accounts exist**: changing it orphans every user, room and
        piece of media. Choose before the first deploy.

        Defaults to the platform's first base domain, which means MXIDs
        read `@you:kelliher.info` while the server itself lives at
        `<subdomain>.kelliher.info`. That split requires the well-known
        delegation documents this module serves at the apex (see
        `serveWellKnown`). Set this to the same value as the public
        host (e.g. "matrix.kelliher.info") if you would rather not
        touch the apex at all.
      '';
    };

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "matrix";
      description = ''
        Label for the homeserver's own public host —
        `<subdomain>.<baseDomain>`. This is what clients actually
        connect to, and what the well-known documents point at.
      '';
    };

    serveWellKnown = lib.mkOption {
      type = lib.types.bool;
      default = cfg.serverName != "${cfg.subdomain}.${baseDomain}";
      defaultText = lib.literalExpression "serverName != \"<subdomain>.<baseDomain>\"";
      description = ''
        Register an extra Caddy site on `serverName` itself that serves
        `/.well-known/matrix/server` and `/.well-known/matrix/client`,
        pointing at the real homeserver host. Required whenever
        `serverName` differs from the public host — which is the
        default (apex MXIDs, homeserver on a subdomain).

        Everything else on that hostname redirects to
        `wellKnownFallback`. Note this puts the apex record under
        Terraform's management the next time you regenerate
        `hostnames.auto.tfvars.json`.
      '';
    };

    wellKnownFallback = lib.mkOption {
      type = lib.types.str;
      default = "https://jack.${baseDomain}";
      description = "Where non-well-known requests to `serverName` are redirected.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8008;
      description = "Loopback port Synapse's client listener binds.";
    };

    federation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Speak to the wider Matrix network. Off by default: a private
        homeserver that federates inherits the public network's spam,
        abuse-report and key-server surface for no benefit if every
        account is yours.

        On, federation traffic rides the same Cloudflare tunnel on 443
        via the `m.server` delegation document — no extra ports, no
        8448 listener. Flipping this later is safe (unlike
        `serverName`).
      '';
    };

    maxUploadSize = lib.mkOption {
      type = lib.types.str;
      default = "100M";
      description = "Synapse `max_upload_size`; the Caddy site is sized to match.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/matrix-synapse";
      description = "Synapse state (signing key, media store).";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/kmatrix";
      description = ''
        Where this module keeps the registration shared secret and the
        per-account passwords/access tokens it provisions. Root-owned,
        0700; services receive individual files via systemd
        `LoadCredential`, never by reading this directory themselves.
      '';
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = lib.literalExpression ''{ presence.enabled = false; }'';
      description = "Merged into `services.matrix-synapse.settings` last — the escape hatch.";
    };

    # ── admin API access ────────────────────────────────────────────
    admin = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Provision a server-admin account (`adminUser`) and keep a live
          access token for it on disk, plus a `kmatrix-admin` CLI on the
          host that speaks the Synapse admin API with it:

            ssh spain 'sudo kmatrix-admin GET /_synapse/admin/v2/users?from=0'
            ssh spain 'sudo kmatrix-admin POST /_synapse/admin/v1/rooms/<id>/make_room_admin'

          This is the machine-facing key to the homeserver. It never
          leaves spain and is only readable by root.
        '';
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "provisioner";
        description = "Localpart of the admin account.";
      };
    };

    # ── login delegation ────────────────────────────────────────────
    oidc = {
      enable = lib.mkEnableOption ''
        login delegation to Authelia over OIDC. Instead of a Matrix
        password, clients get a "Continue with <idpName>" button that
        walks the usual portal: lldap identity, 2FA, one session.

        Matrix passwords stay enabled alongside it (see `passwordLogin`)
        — bots authenticate locally and never touch the portal, and a
        password login is the way back in if Authelia is down
      '';

      issuer = lib.mkOption {
        type = lib.types.str;
        default = "https://auth.${baseDomain}";
        description = "Authelia's OIDC issuer URL.";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "kmatrix";
        description = "Must match the `client_id` of the Authelia client in identity.nix.";
      };

      clientSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/secrets/matrix-oidc-client-secret";
        description = ''
          File holding the *plaintext* client secret (a sops secret,
          owned by `matrix-synapse`). Authelia holds only its PBKDF2
          digest, which is why that side can live in plain Nix.
        '';
      };

      idpName = lib.mkOption {
        type = lib.types.str;
        default = baseDomain;
        description = "Label on the SSO button in the client.";
      };

      requiredGroup = lib.mkOption {
        type = lib.types.str;
        default = "matrix-user";
        description = ''
          lldap group that gates the OIDC client. Declared to the
          platform through the site's `requiredGroups`, so
          `lldap-bootstrap` creates it without an identity.nix edit;
          enforcement itself is Authelia's, via a per-client
          authorization policy. Set to "" to gate on nothing.
        '';
      };

      allowExistingUsers = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Let an OIDC login attach to an account that already exists
          with the same localpart — which is exactly the case for the
          accounts this module declares. With this off, signing in as
          `jack` through Authelia would try to mint a *second* MXID.
        '';
      };

      passwordLogin = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Keep `m.login.password` enabled. Required for bots: their
          first token comes from a password login over loopback. Turn
          it off only if every bot already holds a valid token and you
          never intend to re-provision one.
        '';
      };
    };

    # ── Element web client ──────────────────────────────────────────
    element = {
      enable = lib.mkEnableOption "Element web client for this homeserver";

      subdomain = lib.mkOption {
        type = lib.types.str;
        default = "chat";
        description = "Label for Element — `<subdomain>.<baseDomain>`.";
      };

      requireAuth = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Gate the Element *static bundle* behind Authelia 2FA. Purely
          defence in depth — Matrix still authenticates you separately
          once the app loads, and native clients talk to the homeserver
          host directly, which is never Authelia-gated.
        '';
      };

      conf = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Merged over Element's default `config.json`.";
      };
    };

    # ── declarative accounts ────────────────────────────────────────
    users = lib.mkOption {
      default = { };
      description = ''
        Human accounts. Created if absent at every activation, never
        deleted. The attribute name is the MXID localpart.
      '';
      example = lib.literalExpression ''
        {
          jack = {
            displayName = "Jack";
            admin = true;
            passwordFile = config.sops.secrets.matrix-jack-password.path;
          };
        }
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = accountCommon // {
            issueToken = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Also mint and store a long-lived access token for this
                account under `<stateDir>/accounts/<name>/access_token`.
                Handy for scripting against the client-server API as a
                human user; off by default because a human's token is a
                credential you have to think about.
              '';
            };
          };
        }
      );
    };

    bots = lib.mkOption {
      default = { };
      description = ''
        Chatbots. Each one gets, in order: a Matrix account, a stable
        access token, and a hardened systemd service that receives the
        token through `LoadCredential` and its dependencies through the
        Nix store. The attribute name is the MXID localpart and the
        unit name suffix (`kmatrix-bot-<name>.service`).

        Supply either `execStart` (a built binary — the usual case; see
        the packaged Go reference bot in `bots/echo`) or `entrypoint` (a
        Python file, run with `pythonPackages`).
      '';
      example = lib.literalExpression ''
        {
          echo = {
            displayName = "Echo";
            autoJoin = [ "#lab:kelliher.info" ];
            execStart = lib.getExe kmatrix.packages.''${system}.kmatrix-echo;
          };
        }
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = accountCommon // {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Run this bot. Set false to park it without deleting the account.";
              };

              entrypoint = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = ''
                  Python file to exec, for bots small enough not to
                  deserve a derivation. Mutually exclusive with
                  `execStart`.
                '';
              };

              pythonPackages = lib.mkOption {
                type = lib.types.functionTo (lib.types.listOf lib.types.package);
                default = ps: with ps; [ matrix-nio aiohttp ];
                defaultText = lib.literalExpression "ps: with ps; [ matrix-nio aiohttp ]";
                description = ''
                  Dependencies for `entrypoint`, in the usual
                  `python3.withPackages` shape. Ignored when `execStart`
                  is used — a compiled bot carries its own dependencies
                  (Go's come from go.mod via `vendorHash`).
                '';
              };

              execStart = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = lib.literalExpression ''lib.getExe pkgs.kmatrix-echo'';
                description = ''
                  Command line for a packaged bot — the usual case.
                  `lib.getExe <pkg>` is the idiomatic value.
                  Mutually exclusive with `entrypoint`.
                '';
              };

              environment = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
                description = ''
                  Extra environment. The module always supplies
                  MATRIX_HOMESERVER, MATRIX_SERVER_NAME, MATRIX_USER_ID,
                  MATRIX_DEVICE_ID, MATRIX_ACCESS_TOKEN_FILE and
                  MATRIX_STORE_DIR.
                '';
              };

              credentials = lib.mkOption {
                type = lib.types.attrsOf lib.types.path;
                default = { };
                example = lib.literalExpression ''{ openai_key = "/run/secrets/openai-key"; }'';
                description = ''
                  Extra secrets, exposed as
                  `$CREDENTIALS_DIRECTORY/<name>` via systemd
                  LoadCredential. systemd reads these as root before
                  dropping privileges, so a DynamicUser bot can hold a
                  root-owned sops secret without ever owning the file.
                '';
              };

              runtimePackages = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [ ];
                description = "Packages placed on the bot's PATH.";
              };

              stateDirectory = lib.mkOption {
                type = lib.types.str;
                default = "kmatrix-bot-${name}";
                description = "`/var/lib/<this>` — the bot's own writable scratch (nio store, sqlite, …).";
              };

              extraServiceConfig = lib.mkOption {
                type = lib.types.attrs;
                default = { };
                description = "Merged last into the unit's serviceConfig.";
              };
            };
          }
        )
      );
    };

    # ── computed views (read-only by convention) ────────────────────
    publicHost = lib.mkOption {
      type = lib.types.str;
      internal = true;
      description = "Read-only: the homeserver's public hostname.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.kmatrix.publicHost = "${cfg.subdomain}.${baseDomain}";

    assertions = [
      {
        assertion = config.services.kelliher-web.baseDomains != [ ];
        message = "kmatrix: services.kelliher-web.baseDomains is empty — the module has no zone to live in.";
      }
      {
        assertion = cfg.oidc.enable -> cfg.oidc.clientSecretFile != null;
        message = "kmatrix: oidc.enable requires oidc.clientSecretFile (the plaintext secret Authelia holds the digest of).";
      }
      {
        assertion =
          (cfg.oidc.enable && !cfg.oidc.passwordLogin)
          -> (cfg.bots == { } && !cfg.admin.enable && !(lib.any (u: u.issueToken) (lib.attrValues cfg.users)));
        message =
          "kmatrix: oidc.passwordLogin = false, but something here needs a token minted by password login "
          + "(a bot, an issueToken user, or the admin account). Leave password login on.";
      }
    ]
    ++ lib.mapAttrsToList (n: b: {
      assertion = (b.entrypoint == null) != (b.execStart == null);
      message = "kmatrix: bot '${n}' must set exactly one of `entrypoint` or `execStart`.";
    }) cfg.bots
    ++ lib.mapAttrsToList (n: _: {
      assertion = !(cfg.users ? ${n});
      message = "kmatrix: '${n}' is declared as both a bot and a user — one MXID, one owner.";
    }) cfg.bots;
  };
}
