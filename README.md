# kmatrix

A Matrix homeserver (Synapse) for the kelliher-web stack, plus a
declarative contract for **accounts and chatbots**: a bot is a few lines
of Nix, and the module handles registration, its access token, its
dependencies and its sandbox.

```
Cloudflare tunnel ─▶ Caddy ─▶ Synapse 127.0.0.1:8008
                       │          └─ postgres (unix socket, peer auth)
                       ├─▶ chat.kelliher.info   Element (Authelia-gated)
                       └─▶ kelliher.info/.well-known/matrix/*  delegation
```

## Shape of a deployment

```nix
services.kmatrix = {
  enable = true;
  serverName = "kelliher.info";   # MXIDs read @you:kelliher.info
  element.enable = true;

  users.jack = {
    displayName = "Jack";
    admin = true;
    # passwordFile = config.sops.secrets.matrix-jack-password.path;
  };

  bots.echo = {
    displayName = "Echo";
    execStart = lib.getExe kmatrix.packages.x86_64-linux.kmatrix-echo;
  };

  bots.oracle = {
    displayName = "Oracle";
    execStart = lib.getExe pkgs.my-oracle-bot;
    credentials.openai_key = "/run/secrets/openai-key";
    environment.ORACLE_MODEL = "gpt-5";
    autoJoin = [ "#lab:kelliher.info" ];
  };
};
```

That is the whole surface. Rebuild, deploy, and `@oracle:kelliher.info`
exists, holds a token, and is running.

## What a bot receives

| Variable | Meaning |
|---|---|
| `MATRIX_HOMESERVER` | `http://127.0.0.1:8008` — loopback, no TLS, no proxy |
| `MATRIX_SERVER_NAME` | `kelliher.info` |
| `MATRIX_USER_ID` | `@echo:kelliher.info` |
| `MATRIX_DEVICE_ID` | stable across redeploys, so tokens are too |
| `MATRIX_ACCESS_TOKEN_FILE` | a path inside `$CREDENTIALS_DIRECTORY` |
| `MATRIX_STORE_DIR` | `/var/lib/kmatrix-bot-<name>`, writable |
| `$CREDENTIALS_DIRECTORY/<n>` | one file per entry in `credentials` |

Bots run `DynamicUser`, `ProtectSystem=strict`, no ambient capabilities.
They own nothing but their state directory. The access token is read by
systemd *as root* and handed to the process — the bot's own uid could
never open the file it came from.

## Writing a bot

Go, with [mautrix-go](https://github.com/mautrix/go) — the library behind
every mautrix bridge and the gomuks client.
[`bots/echo`](./bots/echo) is the reference: ~120 lines, packaged with
`buildGoModule`, dependencies pinned by `go.mod` + `vendorHash`.

```go
client, _ := mautrix.NewClient(homeserver, userID, token)
syncer := client.Syncer.(*mautrix.DefaultSyncer)
syncer.OnEventType(event.EventMessage, func(ctx context.Context, evt *event.Event) { … })
client.SyncWithContext(ctx)
```

Start a new one by copying `bots/echo`, then:

```bash
cd bots/mybot && go mod tidy && go vet ./...
nix build .#mybot            # fails once with the real vendorHash; paste it in
```

Python remains available for throwaway bots — set `entrypoint` and
`pythonPackages` instead of `execStart` and the module builds a
`python3.withPackages` environment (default: `matrix-nio`).

## How accounts get made

`/_synapse/admin/v1/register`, the shared-secret flow: a nonce, an
HMAC-SHA1 over `nonce\0user\0password\0(admin|notadmin)`, and no secret
anywhere on a command line. The shared secret is generated on the host at
first boot, lives at `/var/lib/kmatrix/registration_shared_secret`, and
is readable only by root and Synapse. Open registration stays off.

Provisioning is idempotent and runs at every activation:

- account absent → registered; present → left alone (`M_USER_IN_USE`).
- stored token still answers `/whoami` → reused; otherwise re-minted.
- display name set, `autoJoin` rooms joined (a failed join warns, never
  fails the unit).

Credentials land in `/var/lib/kmatrix/accounts/<localpart>/`
(`password`, `access_token`), root-owned, 0700.

## API access

```bash
# as a server admin, from spain
ssh spain 'sudo kmatrix-admin GET /_synapse/admin/v2/users?from=0'
ssh spain 'sudo kmatrix-admin GET /_synapse/admin/v1/rooms'

# a user's own token, if you asked for one (users.<n>.issueToken = true)
ssh spain 'sudo cat /var/lib/kmatrix/accounts/jack/access_token'
```

The `/_synapse/admin/*` prefix is refused by Caddy, so the admin API is
reachable only over loopback on spain. The client-server API
(`/_matrix/*`) is public by necessity — Synapse authenticates it itself
and is never put behind Authelia, which would break every native client.

## Federation

Off by default (`federation = false` → empty
`federation_domain_whitelist`). A private homeserver that federates
inherits the public network's spam and abuse surface for no gain.

To turn it on: set `federation = true`. Traffic rides the existing
tunnel on 443 via the `m.server` delegation document — no 8448 listener,
no firewall change. Unlike `serverName`, this is safe to flip later.

## Operating

```bash
ssh spain 'journalctl -u matrix-synapse -f'
ssh spain 'journalctl -u kmatrix-bot-echo -f'
ssh spain 'systemctl start kmatrix-account-echo'   # re-provision
ssh spain 'sudo -u postgres psql matrix-synapse -c "\dt"'
```

## The one-way door

`serverName` is baked into every MXID, room ID and event signature. It
cannot be changed after the first account exists without abandoning the
server. Everything else here is reversible.
