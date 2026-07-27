# gluck-matrix — accounts, tokens, and the admin CLI.
#
# The whole point of the module: an account is a line of Nix, not a
# remembered incantation. Every declared user and bot gets a oneshot unit
# that, idempotently, on every activation:
#
#   1. ensures a password exists (sops file, or generated once and kept),
#   2. registers the account if the homeserver doesn't have it, using the
#      shared-secret admin registration flow (nonce + HMAC-SHA1) — never
#      putting the secret or the password on a command line,
#   3. mints an access token if the stored one no longer answers
#      /whoami, so tokens survive redeploys instead of churning,
#   4. sets the display name and joins the declared rooms.
#
# Credentials never move: they are written under <stateDir>/accounts/<n>/
# as root, and consumers receive them through systemd LoadCredential,
# which reads the file as root at unit start and hands the content to a
# DynamicUser process that could never have opened it itself.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.gluck-matrix;

  accountsDir = "${cfg.stateDir}/accounts";
  hsUrl = "http://127.0.0.1:${toString cfg.port}";

  # ── the registration shared secret ──────────────────────────────
  # Generated on the host, never in the store, never in sops: it is
  # host-local by nature and only ever used over loopback. Readable by
  # the matrix-synapse group because Synapse itself must read it.
  secretInit = pkgs.writeShellApplication {
    name = "gluck-matrix-secret-init";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      install -d -m 0750 -o root -g matrix-synapse "${cfg.stateDir}"
      install -d -m 0700 -o root -g root "${accountsDir}"

      secret="${cfg.stateDir}/registration_shared_secret"
      if [ ! -s "$secret" ]; then
        echo "generating registration shared secret"
        umask 077
        head -c 48 /dev/urandom | base64 -w0 > "$secret.tmp"
        mv "$secret.tmp" "$secret"
      fi
      chown root:matrix-synapse "$secret"
      chmod 0640 "$secret"
    '';
  };

  # ── the provisioner ─────────────────────────────────────────────
  provision = pkgs.writeShellApplication {
    name = "gluck-matrix-provision";
    runtimeInputs = with pkgs; [ curl jq openssl coreutils ];
    text = ''
      hs="${hsUrl}"
      dir="${accountsDir}/$MX_LOCALPART"
      mxid="@$MX_LOCALPART:${cfg.serverName}"

      install -d -m 0700 -o root -g root "$dir"

      # Wait for the homeserver. Synapse is Type=notify so it is usually
      # up already; this covers a slow first-boot schema migration.
      ready=0
      for _ in $(seq 1 60); do
        if curl -fsS -o /dev/null "$hs/_matrix/client/versions"; then ready=1; break; fi
        sleep 2
      done
      if [ "$ready" != "1" ]; then
        echo "homeserver did not answer at $hs" >&2
        exit 1
      fi

      # ── password ────────────────────────────────────────────────
      if [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -s "$CREDENTIALS_DIRECTORY/password" ]; then
        pass=$(cat "$CREDENTIALS_DIRECTORY/password")
      else
        if [ ! -s "$dir/password" ]; then
          ( umask 077; head -c 32 /dev/urandom | base64 -w0 > "$dir/password.tmp" )
          mv "$dir/password.tmp" "$dir/password"
        fi
        pass=$(cat "$dir/password")
      fi

      secret=$(cat "${cfg.stateDir}/registration_shared_secret")

      # ── register (idempotent) ───────────────────────────────────
      if [ "$MX_ADMIN" = "1" ]; then
        admin_word="admin"; admin_bool="true"
      else
        admin_word="notadmin"; admin_bool="false"
      fi

      nonce=$(curl -fsS "$hs/_synapse/admin/v1/register" | jq -r .nonce)
      mac=$(printf '%s\0%s\0%s\0%s' "$nonce" "$MX_LOCALPART" "$pass" "$admin_word" \
        | openssl dgst -sha1 -hmac "$secret" -hex | sed 's/^.*= *//')

      body=$(jq -n --arg n "$nonce" --arg u "$MX_LOCALPART" --arg p "$pass" \
        --argjson a "$admin_bool" --arg m "$mac" \
        '{nonce:$n, username:$u, password:$p, admin:$a, mac:$m}')

      resp=$(curl -sS -X POST -H 'Content-Type: application/json' \
        -d "$body" "$hs/_synapse/admin/v1/register" || true)

      if printf '%s' "$resp" | jq -e '.access_token' >/dev/null 2>&1; then
        echo "registered $mxid"
      else
        errcode=$(printf '%s' "$resp" | jq -r '.errcode // ""')
        if [ "$errcode" = "M_USER_IN_USE" ]; then
          echo "$mxid already exists"
        else
          echo "registration of $mxid failed: $resp" >&2
          exit 1
        fi
      fi

      if [ "$MX_ISSUE_TOKEN" != "1" ]; then
        echo "provisioned $mxid (no token requested)"
        exit 0
      fi

      # ── access token: reuse while it still answers ──────────────
      token=""
      if [ -s "$dir/access_token" ]; then
        existing=$(cat "$dir/access_token")
        if curl -fsS -o /dev/null -H "Authorization: Bearer $existing" \
             "$hs/_matrix/client/v3/account/whoami"; then
          token="$existing"
        fi
      fi

      if [ -z "$token" ]; then
        login=$(jq -n --arg u "$MX_LOCALPART" --arg p "$pass" --arg d "$MX_DEVICE_ID" \
          '{type:"m.login.password",
            identifier:{type:"m.id.user", user:$u},
            password:$p,
            device_id:$d,
            initial_device_display_name:"gluck-matrix"}')
        token=$(curl -fsS -X POST -H 'Content-Type: application/json' \
          -d "$login" "$hs/_matrix/client/v3/login" | jq -r .access_token)
        if [ -z "$token" ] || [ "$token" = "null" ]; then
          echo "login failed for $mxid — the account exists but its password is not the one on file" >&2
          exit 1
        fi
        ( umask 077; printf '%s' "$token" > "$dir/access_token.tmp" )
        mv "$dir/access_token.tmp" "$dir/access_token"
        echo "issued a fresh access token for $mxid"
      fi

      # ── profile ─────────────────────────────────────────────────
      if [ -n "''${MX_DISPLAYNAME:-}" ]; then
        curl -fsS -o /dev/null -X PUT -H "Authorization: Bearer $token" \
          -H 'Content-Type: application/json' \
          -d "$(jq -n --arg n "$MX_DISPLAYNAME" '{displayname:$n}')" \
          "$hs/_matrix/client/v3/profile/$mxid/displayname" \
          || echo "warn: could not set display name for $mxid" >&2
      fi

      # ── rooms ───────────────────────────────────────────────────
      for room in ''${MX_ROOMS:-}; do
        enc=$(jq -rn --arg s "$room" '$s|@uri')
        if curl -fsS -o /dev/null -X POST -H "Authorization: Bearer $token" \
             -H 'Content-Type: application/json' -d '{}' \
             "$hs/_matrix/client/v3/join/$enc"; then
          echo "$mxid joined $room"
        else
          echo "warn: $mxid could not join $room (invite required?)" >&2
        fi
      done

      echo "provisioned $mxid"
    '';
  };

  # ── the admin CLI ───────────────────────────────────────────────
  adminCli = pkgs.writeShellApplication {
    name = "matrix-admin";
    runtimeInputs = with pkgs; [ curl jq ];
    text = ''
      # matrix-admin METHOD PATH [JSON_BODY]
      #
      #   matrix-admin GET  /_synapse/admin/v2/users?from=0&limit=50
      #   matrix-admin POST /_synapse/admin/v1/rooms/'!abc:${cfg.serverName}'/make_room_admin \
      #        '{"user_id":"@you:${cfg.serverName}"}'
      #
      # Speaks as @${cfg.admin.user}:${cfg.serverName}, a server admin.
      # Root only — the token is the homeserver's master key.
      if [ "$#" -lt 2 ]; then
        echo "usage: matrix-admin <METHOD> <PATH> [JSON]" >&2
        exit 64
      fi

      token_file="${accountsDir}/${cfg.admin.user}/access_token"
      if [ ! -r "$token_file" ]; then
        echo "no admin token at $token_file (run as root; is gluck-matrix-account-${cfg.admin.user} happy?)" >&2
        exit 69
      fi

      method="$1"; path="$2"; shift 2
      body="''${1:-}"

      set -- -sS -X "$method" \
        -H "Authorization: Bearer $(cat "$token_file")" \
        -H 'Content-Type: application/json'
      if [ -n "$body" ]; then set -- "$@" -d "$body"; fi

      curl "$@" "${hsUrl}$path" | jq .
    '';
  };

  # Every declared account, plus the implicit admin one.
  allAccounts =
    lib.mapAttrs (n: u: {
      inherit (u) displayName admin autoJoin passwordFile;
      issueToken = u.issueToken;
      deviceId = "gluck-matrix-${n}";
    }) cfg.users
    // lib.mapAttrs (n: b: {
      inherit (b) displayName admin autoJoin passwordFile;
      issueToken = true;
      deviceId = "matrix-bot-${n}";
    }) cfg.bots
    // lib.optionalAttrs cfg.admin.enable {
      ${cfg.admin.user} = {
        displayName = "gluck-matrix provisioner";
        admin = true;
        autoJoin = [ ];
        passwordFile = null;
        issueToken = true;
        deviceId = "gluck-matrix-admin";
      };
    };

  accountUnit = name: a: {
    name = "gluck-matrix-account-${name}";
    value = {
      description = "Provision Matrix account @${name}:${cfg.serverName}";
      after = [ "matrix-synapse.service" "gluck-matrix-secret.service" ];
      requires = [ "matrix-synapse.service" "gluck-matrix-secret.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        MX_LOCALPART = name;
        MX_ADMIN = if a.admin then "1" else "0";
        MX_ISSUE_TOKEN = if a.issueToken then "1" else "0";
        MX_DEVICE_ID = a.deviceId;
        MX_DISPLAYNAME = if a.displayName == null then "" else a.displayName;
        MX_ROOMS = lib.concatStringsSep " " a.autoJoin;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Root: it reads the shared secret and writes credentials that
        # no service user may own.
        ExecStart = lib.getExe provision;
        # A homeserver that is slow to come up should not wedge the boot.
        TimeoutStartSec = "180s";
      }
      // lib.optionalAttrs (a.passwordFile != null) {
        LoadCredential = [ "password:${a.passwordFile}" ];
      };
    };
  };
in
{
  config = lib.mkIf cfg.enable {
    systemd.services = {
      gluck-matrix-secret = {
        description = "gluck-matrix — state directory and registration shared secret";
        before = [ "matrix-synapse.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe secretInit;
        };
      };
    }
    // lib.listToAttrs (lib.mapAttrsToList accountUnit allAccounts);

    environment.systemPackages = lib.optional cfg.admin.enable adminCli;
  };
}
