{
  config,
  lib,
  pkgs,
  ...
}:

{
  security = {
    # jww (2025-10-21): The auditor can be too noisy
    # Audit framework
    auditd.enable = false;
    audit = {
      enable = false;
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

    # jww (2025-10-21): Not using AppArmor yet
    # AppArmor
    apparmor = {
      enable = false;
      killUnconfinedConfinables = false; # Start permissive
    };
  };

  # CVE-2026-31431 "CopyFail" — disable AF_ALG userspace crypto sockets.
  # The asahi 6.17.12 kernel pinned by nixos-apple-silicon has no upstream
  # backport (6.17 was skipped; fixes are in 6.18.12 / 6.19.12 / 7.0 and the
  # LTS branches). algif_aead is the actual vector; the rest of the family
  # is blocked too because nothing on this host uses AF_ALG sockets
  # directly (dm-crypt/LUKS, kTLS, IPsec, OpenSSL, SSH all use the in-kernel
  # crypto API, not the userspace AF_ALG interface). Drop this once
  # nixos-apple-silicon ships a patched kernel.
  #
  # `blacklist` alone only stops alias-based autoload, so we also use
  # `install ... /bin/false` (per CERT-EU 2026-005) to make every load path —
  # explicit modprobe, kernel request_module(), aliased autoload — fail.
  boot.blacklistedKernelModules = [
    "algif_aead"
    "algif_skcipher"
    "algif_hash"
    "algif_rng"
  ];
  boot.extraModprobeConfig = ''
    install algif_aead ${pkgs.coreutils}/bin/false
    install algif_skcipher ${pkgs.coreutils}/bin/false
    install algif_hash ${pkgs.coreutils}/bin/false
    install algif_rng ${pkgs.coreutils}/bin/false
  '';

  # Create adm group for log file access
  users.groups.adm = { };

  system.activationScripts.sudoLogs = ''
    mkdir -p /var/log
    touch /var/log/sudo.log
    chown root:adm /var/log/sudo.log
    chmod 640 /var/log/sudo.log
  '';

  # Create polkit rules directories to suppress harmless error messages
  # polkitd is hardcoded to check /usr/local/share/polkit-1/rules.d which doesn't
  # exist on NixOS since it doesn't follow FHS conventions
  systemd.tmpfiles.rules = [
    "d /run/polkit-1/rules.d 0755 root root -"
    "d /usr/local/share/polkit-1/rules.d 0755 root root -"
  ];
}
