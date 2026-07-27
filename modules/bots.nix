# gluck-matrix — one hardened service per declared bot.
#
# A bot is a Matrix account (provision.nix) plus a process that holds its
# token. The process never learns where the token lives on disk: systemd
# reads it as root and drops it in the unit's credentials directory, so
# the bot can be a DynamicUser with no ownership of anything outside its
# own StateDirectory.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.gluck-matrix;

  hsUrl = "http://127.0.0.1:${toString cfg.port}";
  tokenOf = name: "${cfg.stateDir}/accounts/${name}/access_token";

  # Same sandbox the rest of the gluck services run under.
  hardened = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
  };

  botUnit = name: bot: {
    name = "matrix-bot-${name}";
    value = let
      py = pkgs.python3.withPackages bot.pythonPackages;
      exec =
        if bot.entrypoint != null then "${py}/bin/python ${bot.entrypoint}" else bot.execStart;
      account = "gluck-matrix-account-${name}.service";
    in
    {
      description = "Matrix bot @${name}:${cfg.serverName}";
      after = [ "network-online.target" "matrix-synapse.service" account ];
      wants = [ "network-online.target" ];
      requires = [ account ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        MATRIX_HOMESERVER = hsUrl;
        MATRIX_SERVER_NAME = cfg.serverName;
        MATRIX_USER_ID = "@${name}:${cfg.serverName}";
        MATRIX_DEVICE_ID = "matrix-bot-${name}";
        # %d is systemd's credentials directory. The bot reads the file;
        # the token is never an environment value (those leak into
        # /proc, `systemctl show`, and journal dumps).
        MATRIX_ACCESS_TOKEN_FILE = "%d/access_token";
        MATRIX_STORE_DIR = "/var/lib/${bot.stateDirectory}";
      }
      // lib.optionalAttrs (bot.runtimePackages != [ ]) {
        PATH = lib.makeBinPath bot.runtimePackages;
      }
      // bot.environment;

      serviceConfig = hardened // {
        DynamicUser = true;
        StateDirectory = bot.stateDirectory;
        ExecStart = exec;
        Restart = "on-failure";
        RestartSec = 5;
        LoadCredential = [
          "access_token:${tokenOf name}"
        ]
        ++ lib.mapAttrsToList (n: p: "${n}:${p}") bot.credentials;
      }
      // bot.extraServiceConfig;
    };
  };

  enabledBots = lib.filterAttrs (_: b: b.enable) cfg.bots;
in
{
  config = lib.mkIf cfg.enable {
    systemd.services = lib.listToAttrs (lib.mapAttrsToList botUnit enabledBots);
  };
}
