{ jportaudio }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.beatoraja;

  # The launcher screen (PlayConfigurationView) is JavaFX, and on Linux it is
  # drawn by the Glass toolkit's GTK3 backend (com.sun.glass.ui.gtk.GtkApplication
  # ._runLoop shows up in the stack trace when it crashes). That GTK3 reads
  # GSettings during startup, and if it finds no schemas at all GLib goes through
  #   g_settings_schema_source_get_default() == NULL
  #   -> g_error ("No GSettings schemas are installed on the system")
  # (gio/gsettings.c:676). g_error is fatal in GLib and calls abort(), taking the
  # JVM with it via SIGABRT. That is what "it suddenly dies while I'm using it"
  # really is.
  #
  # To avoid collisions, NixOS has each package put its gschemas in an isolated
  #   share/gsettings-schemas/<package name>/glib-2.0/schemas/
  # rather than merging them into the system profile's share/glib-2.0/schemas
  # (that directory genuinely does not exist under /run/current-system/sw). So
  # adding gtk3 to environment.systemPackages is not enough for GTK to see them:
  # they have to be merged and compiled by hand and pointed at explicitly with
  # GSETTINGS_SCHEMA_DIR.
  #
  # Both gtk3 and gsettings-desktop-schemas are needed. The org.gtk.Settings.*
  # that GTK looks up live in gtk3, not in gsettings-desktop-schemas.
  mergedGsettingsSchemas =
    pkgs.runCommand "merged-gsettings-schemas"
      {
        nativeBuildInputs = [ pkgs.glib ];
      }
      ''
        mkdir -p $out/glib-2.0/schemas
        cp ${pkgs.gtk3}/share/gsettings-schemas/gtk+3-*/glib-2.0/schemas/*.xml $out/glib-2.0/schemas/
        cp ${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/gsettings-desktop-schemas-*/glib-2.0/schemas/*.xml $out/glib-2.0/schemas/
        glib-compile-schemas $out/glib-2.0/schemas
      '';
in

{
  options.programs.beatoraja = {
    enable = lib.mkEnableOption "the beatoraja launcher";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./beatoraja.nix {
        jportaudio = jportaudio.packages.${pkgs.stdenv.hostPlatform.system}.default;
        inherit (cfg) dataDir;
      };
      defaultText = lib.literalExpression "pkgs.callPackage ./beatoraja.nix { }";
      description = "The beatoraja package to use.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/beatoraja";
      description = ''
        Directory the game reads and writes.

        The store is read-only, but beatoraja writes config.json, player/,
        songdata.db and scores into its own directory, so the distribution is
        copied here on first run and used from here afterwards. Songs and settings
        end up here too, so deleting it loses them.

        The directory is created writable by the group configured below.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = ''
        Group allowed to write dataDir. Anyone who plays must belong to it.

        setgid is set, so files created underneath inherit this group.
      '';
    };

    installJdk = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to also put the JavaFX-enabled JDK into systemPackages.

        Not needed to launch beatoraja itself — the wrapper carries its own via
        runtimeInputs. Set this only if you want `java` on the system-wide PATH.
      '';
    };

    setGsettingsSchemaDir = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to set GSETTINGS_SCHEMA_DIR in sessionVariables.

        Without it the JavaFX launcher aborts on GLib's g_error. Set to false only
        if something else already sets GSETTINGS_SCHEMA_DIR.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ]
    ++ lib.optional cfg.installJdk cfg.package.jdk
    ++ [
      # The gschemas the launcher's GTK3 backend reads, plus the gsettings CLI.
      pkgs.gsettings-desktop-schemas
      pkgs.glib
    ];

    # These are sessionVariables, so they only apply to login shells. After a
    # change you need to log in again (or start a new session) — launching from an
    # already-open terminal will not pick it up.
    environment.sessionVariables = lib.mkIf cfg.setGsettingsSchemaDir {
      GSETTINGS_SCHEMA_DIR = "${mergedGsettingsSchemas}/glib-2.0/schemas";
    };

    # Prepare dataDir as group-writable. The wrapper copies the distribution here
    # on first run, but a user cannot create directories directly under /var/lib,
    # so it has to exist beforehand.
    # 2 = setgid, so files created underneath inherit the group.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 2775 root ${cfg.group} -"
    ];
  };
}
