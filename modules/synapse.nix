# gluck-matrix — the homeserver itself.
#
# Postgres (a dedicated database with C collation, which Synapse insists
# on), Synapse bound to loopback, and the Caddy site that fronts it.
#
# Trust model, in the platform's terms: Synapse is *not* behind Authelia.
# It cannot be — Matrix clients speak the client-server API with their own
# access tokens and know nothing about forward-auth. So the homeserver
# authenticates its own callers, registration is closed (accounts come
# from this module, see provision.nix), and the `/_synapse/admin` surface
# is refused at the edge so it is reachable only over loopback on spain.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.gluck-matrix;

  dbName = "matrix-synapse";

  # Synapse spells sizes "100M"; Caddy wants "100MB".
  caddyBodySize =
    let
      s = cfg.maxUploadSize;
      last = lib.substring (lib.stringLength s - 1) 1 s;
    in
    if lib.elem last [ "K" "M" "G" ] then "${s}B" else s;

  wellKnownServer = builtins.toJSON { "m.server" = "${cfg.publicHost}:443"; };
  wellKnownClient = builtins.toJSON {
    "m.homeserver" = { base_url = "https://${cfg.publicHost}"; };
  };

  # Idempotent database bootstrap. Deliberately *not*
  # services.postgresql.ensureDatabases: Synapse refuses to start unless
  # its database was created with LC_COLLATE=C / LC_CTYPE=C, and the
  # ensure* options give no way to say that without imposing C collation
  # on the whole cluster (and every future consumer of it).
  dbInit = pkgs.writeShellApplication {
    name = "matrix-synapse-db-init";
    runtimeInputs = [ config.services.postgresql.package ];
    text = ''
      has_role=$(psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${dbName}'")
      if [ "$has_role" != "1" ]; then
        echo "creating role ${dbName}"
        createuser --no-createdb --no-superuser --no-createrole "${dbName}"
      fi

      has_db=$(psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${dbName}'")
      if [ "$has_db" != "1" ]; then
        echo "creating database ${dbName} (C collation, as Synapse requires)"
        createdb --owner="${dbName}" --encoding=UTF8 --template=template0 \
          --lc-collate=C --lc-ctype=C "${dbName}"
      fi
    '';
  };
in
{
  config = lib.mkIf cfg.enable {

    # ── database ────────────────────────────────────────────────────
    services.postgresql.enable = true;

    systemd.services.matrix-synapse-db-init = {
      description = "Create the Synapse role and database if absent";
      after = [ "postgresql.target" ];
      requires = [ "postgresql.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        ExecStart = lib.getExe dbInit;
      };
    };

    # ── the homeserver ──────────────────────────────────────────────
    services.matrix-synapse = {
      enable = true;
      dataDir = cfg.dataDir;

      settings = lib.recursiveUpdate {
        server_name = cfg.serverName;
        public_baseurl = "https://${cfg.publicHost}/";
        report_stats = false;

        listeners = [
          {
            port = cfg.port;
            bind_addresses = [ "127.0.0.1" ];
            type = "http";
            tls = false;
            # Caddy is the only thing that can reach this port, and the
            # platform declares it a trusted proxy, so X-Forwarded-For
            # is the real client address.
            x_forwarded = true;
            resources = [
              {
                names = [ "client" ] ++ lib.optional cfg.federation "federation";
                compress = false;
              }
            ];
          }
        ];

        database = {
          name = "psycopg2";
          args = {
            # No host → unix socket → peer auth as the matrix-synapse
            # system user. No password to manage.
            user = dbName;
            database = dbName;
            cp_min = 5;
            cp_max = 10;
          };
        };

        # Accounts are declarative (see provision.nix); nobody signs up.
        enable_registration = false;
        registration_shared_secret_path = "${cfg.stateDir}/registration_shared_secret";

        max_upload_size = cfg.maxUploadSize;

        # spain is a router. Do not hand a remote user an SSRF primitive
        # aimed at the LAN it gateways.
        url_preview_enabled = false;

        # Serve /.well-known/matrix/server from Synapse only when the
        # server_name *is* the public host; otherwise Caddy serves the
        # delegation documents on the apex (see below).
        serve_server_wellknown = !cfg.serveWellKnown;
      }
      (
        lib.optionalAttrs (!cfg.federation) {
          # The empty whitelist is Synapse's "federate with nobody".
          federation_domain_whitelist = [ ];
          trusted_key_servers = [ ];
          suppress_key_server_warning = true;
        }
        // cfg.extraSettings
      );
    };

    systemd.services.matrix-synapse = {
      after = [ "matrix-synapse-db-init.service" "gluck-matrix-secret.service" ];
      requires = [ "matrix-synapse-db-init.service" "gluck-matrix-secret.service" ];
    };

    # ── the public face ─────────────────────────────────────────────
    services.kelliher-web.sites.matrix = {
      subdomains = [ cfg.subdomain ];
      # Never requireAuth: Matrix clients carry their own access tokens
      # and would be bounced by forward-auth. Synapse is the authority
      # for its own API.
      requireAuth = false;
      proxyTo = cfg.port;
      extraConfig = ''
        # The Synapse admin API is root-of-the-homeserver. It stays on
        # loopback — reachable from spain itself (see `matrix-admin`),
        # never from the tunnel.
        handle /_synapse/admin/* {
          respond "not available here" 403
        }

        request_body {
          max_size ${caddyBodySize}
        }
      ''
      + lib.optionalString (!cfg.serveWellKnown) ''
        header /.well-known/matrix/* Access-Control-Allow-Origin *
      '';
    };

    # Delegation: server_name lives at the apex, the homeserver lives on
    # a subdomain, and these two documents are the bridge. Everything
    # else on the apex bounces to the personal site.
    services.kelliher-web.sites.matrix-wellknown = lib.mkIf cfg.serveWellKnown {
      hostnames = [ cfg.serverName ];
      requireAuth = false;
      # The platform needs *a* root or a proxy target; this site answers
      # entirely from `respond`/`redir` handlers, so point it at nothing.
      rootPath = "/var/empty";
      extraConfig = ''
        handle /.well-known/matrix/server {
          header Content-Type application/json
          header Access-Control-Allow-Origin *
          respond `${wellKnownServer}` 200
        }

        handle /.well-known/matrix/client {
          header Content-Type application/json
          header Access-Control-Allow-Origin *
          respond `${wellKnownClient}` 200
        }

        handle {
          redir ${cfg.wellKnownFallback}{uri} permanent
        }
      '';
    };
  };
}
