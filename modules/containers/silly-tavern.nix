{ config, lib, pkgs, ... }:

{
  systemd.tmpfiles.rules = [
    "d /var/lib/silly-tavern 0755 container-data container-data -"
    "d /var/lib/silly-tavern/config 0755 container-data container-data -"
    "d /var/lib/silly-tavern/data 0755 container-data container-data -"
    "d /var/lib/silly-tavern/plugins 0755 container-data container-data -"
    "d /var/lib/silly-tavern/extensions 0755 container-data container-data -"
  ];

  virtualisation.oci-containers.containers.silly-tavern = {
    autoStart = true;
    image = "ghcr.io/sillytavern/sillytavern:latest";
    ports = [ "127.0.0.1:8083:8000/tcp" ];
    environment = {
      NODE_ENV = "production";
      FORCE_COLOR = "1";
    };
    volumes = [
      "/var/lib/silly-tavern/config:/home/node/app/config"
      "/var/lib/silly-tavern/data:/home/node/app/data"
      "/var/lib/silly-tavern/plugins:/home/node/app/plugins"
      "/var/lib/silly-tavern/extensions:/home/node/app/public/scripts/extensions/third-party"
    ];
  };
}
