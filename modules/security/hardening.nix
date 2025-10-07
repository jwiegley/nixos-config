{ config, lib, pkgs, ... }:

{
  security = {
    # Audit framework
    auditd.enable = true;
    audit = {
      enable = true;
      rules = [
        # Monitor authentication events
        "-w /var/log/lastlog -p wa -k logins"
        "-w /var/log/faillog -p wa -k logins"

        # Monitor sudo usage
        "-w /etc/sudoers -p wa -k sudoers"
        "-w /etc/sudoers.d/ -p wa -k sudoers"

        # Monitor SSH configuration
        "-w /etc/ssh/sshd_config -p wa -k sshd_config"

        # Monitor Samba configuration and authentication
        "-w /etc/samba/smb.conf -p wa -k samba_config"
        "-w /var/lib/samba/ -p wa -k samba_auth"

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
}
