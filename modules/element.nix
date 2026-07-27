# gluck-matrix — Element web client.
#
# Static bundle only: a build of Element pinned to this homeserver, served
# by the platform's Caddy like any other static site. Optionally behind
# Authelia, which is belt-and-braces — Matrix authenticates the session
# itself once the app loads, and native clients bypass this host entirely.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.gluck-matrix;

  element = pkgs.element-web.override {
    conf = lib.recursiveUpdate {
      default_server_config = {
        "m.homeserver" = {
          base_url = "https://${cfg.publicHost}";
          server_name = cfg.serverName;
        };
      };
      disable_custom_urls = true;
      disable_guests = true;
      disable_3pid_login = true;
      brand = "kelliher";
      show_labs_settings = true;
    } cfg.element.conf;
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.element.enable) {
    services.kelliher-web.sites.matrix-element = {
      subdomains = [ cfg.element.subdomain ];
      inherit (cfg.element) requireAuth;
      root = element;
      extraConfig = ''
        # Single-page app: unknown paths are routes, not files.
        try_files {path} /index.html
      '';
    };
  };
}
