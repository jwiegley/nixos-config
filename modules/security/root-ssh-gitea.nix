{
  config,
  lib,
  pkgs,
  ...
}:

{
  sops.secrets.root_gitea_key = {
    owner = "root";
    group = "root";
    mode = "0600";
  };

  programs.ssh.extraConfig = ''
    Match user root host gitea
      HostName localhost
      Port 2222
      User gitea
      IdentitiesOnly yes
      IdentityFile ${config.sops.secrets.root_gitea_key.path}
      StrictHostKeyChecking accept-new
      Compression no
  '';
}
