{ config, lib, pkgs, ... }:

{
  security = {
    # Audit framework
    auditd.enable = true;
    audit = {
      enable = true;
      rules = [
        # Rate limit audit messages to prevent log flooding and event loss
        # 500 messages/second is reasonable for most systems
        "-r 500"

        # Monitor authentication events
        "-w /var/log/lastlog -p wa -k logins"
        "-w /var/log/faillog -p wa -k logins"

        # Monitor sudo usage
        "-w /etc/sudoers -p wa -k sudoers"
        "-w /etc/sudoers.d/ -p wa -k sudoers"

        # Monitor SSH configuration
        "-w /etc/ssh/sshd_config -p wa -k sshd_config"

        # Monitor Samba configuration
        "-w /etc/samba/smb.conf -p wa -k samba_config"
        # Note: /var/lib/samba/ watch removed - too noisy during system activation
        # (triggers on every smbpasswd operation). Consider more targeted rules if needed.

        # Monitor system calls
        # "-a always,exit -F arch=b64 -S execve -k exec"
        # "-a always,exit -F arch=b64 -S socket -S connect -k network"
      ];
    };

    # AppArmor
    apparmor = {
      enable = true;
      killUnconfinedConfinables = false; # Start permissive
    };
  };

  # Create adm group for log file access
  users.groups.adm = {};

  system.activationScripts.sudoLogs = ''
    mkdir -p /var/log
    touch /var/log/sudo.log
    chown root:adm /var/log/sudo.log
    chmod 640 /var/log/sudo.log
  '';

  # Create polkit rules directory to suppress harmless error messages
  systemd.tmpfiles.rules = [
    "d /run/polkit-1/rules.d 0755 root root -"
  ];
}
