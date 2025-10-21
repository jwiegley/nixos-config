{ config, lib, pkgs, ... }:

{
  # Increase D-Bus pending replies limit for systemd_exporter
  services.dbus.packages = [
    (pkgs.writeTextDir "share/dbus-1/system.d/systemd-exporter-limits.conf" ''
      <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <limit name="max_replies_per_connection">2048</limit>
      </busconfig>
    '')
  ];

  services.hardware.bolt.enable = false;

  time.timeZone = "America/Los_Angeles";

  i18n.defaultLocale = "en_US.UTF-8";

  console = {
    font = "Lat2-Terminus16";
    keyMap = "dvorak";
  };

  security = {
    polkit.enable = true;
    sudo.wheelNeedsPassword = false;
  };

  sops = {
    defaultSopsFile = ../../secrets.yaml;
    age = {
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      keyFile = "/var/lib/sops-nix/key.txt";
      generateKey = true;
    };
  };

  # Enable console blanking and powerdown
  systemd.services.console-blanking = {
    description = "Enable console blanking and powerdown on all TTYs";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for tty in tty1 tty2 tty3 tty4 tty5 tty6; do
        ${pkgs.util-linux}/bin/setterm --blank 1 --powerdown 2 --term linux > /dev/$tty 2>/dev/null || true
      done
    '';
  };
}
