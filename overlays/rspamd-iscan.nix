self: super: {
  rspamd-iscan = super.buildGoModule rec {
    pname = "rspamd-iscan";
    version = "0.5.0";

    src = super.fetchFromGitHub {
      owner = "fho";
      repo = "rspamd-iscan";
      rev = "v${version}";
      hash = "sha256-b+s9xZ2suY8IpsgFmftv0LNco0PisEJ3meBmPcvLhmE=";
    };

    vendorHash = null;  # vendor directory is included in the repository

    ldflags = [
      "-s"
      "-w"
      "-X main.version=${version}"
    ];

    meta = with super.lib; {
      description = "Daemon that monitors IMAP mailboxes and sends new mails to Rspamd for spam analysis and training";
      homepage = "https://github.com/fho/rspamd-iscan";
      license = licenses.eupl12;
      maintainers = [ ];
      mainProgram = "rspamd-iscan";
      platforms = platforms.unix;
    };
  };
}
