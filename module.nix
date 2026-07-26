{ jportaudio }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.beatoraja;

  # ランチャー画面 (PlayConfigurationView) は JavaFX 製で、Linux では Glass
  # ツールキットの GTK3 バックエンドが描画する (クラッシュ時のスタックトレースに
  # com.sun.glass.ui.gtk.GtkApplication._runLoop が出る)。この GTK3 が起動途中で
  # GSettings を引くが、スキーマが 1 つも見つからないと GLib が
  #   g_settings_schema_source_get_default() == NULL
  #   -> g_error ("No GSettings schemas are installed on the system")
  # (gio/gsettings.c:676) を通る。g_error は GLib では致命的扱いで abort() する
  # ため、JVM ごと SIGABRT で落ちる。「操作していたら急に落ちる」の正体。
  #
  # NixOS では衝突回避のため、各パッケージが gschema を
  #   share/gsettings-schemas/<パッケージ名>/glib-2.0/schemas/
  # という隔離された場所に置き、システムプロファイルの share/glib-2.0/schemas へは
  # マージしない (実際 /run/current-system/sw にそのディレクトリは存在しない)。
  # そのため environment.systemPackages に gtk3 を足すだけでは GTK からは見えず、
  # 自前で結合してコンパイルし、GSETTINGS_SCHEMA_DIR で明示的に指す必要がある。
  #
  # gtk3 と gsettings-desktop-schemas の両方が要る。GTK が参照する
  # org.gtk.Settings.* を持っているのは gtk3 の方で、
  # gsettings-desktop-schemas には入っていない。
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
      };
      defaultText = lib.literalExpression "pkgs.callPackage ./beatoraja.nix { }";
      description = "使用する beatoraja ラッパーパッケージ。";
    };

    installJdk = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        JavaFX 入りの JDK を systemPackages にも入れるかどうか。

        beatoraja の起動自体には不要 (ラッパーが runtimeInputs で抱えている)。
        `java` をシステム全体の PATH に置きたい場合のみ true にする。
      '';
    };

    setGsettingsSchemaDir = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        GSETTINGS_SCHEMA_DIR を sessionVariables に設定するかどうか。

        これが無いと JavaFX ランチャーが GLib の g_error で abort する。
        他に GSETTINGS_SCHEMA_DIR を設定している仕組みがある場合のみ false にする。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ]
    ++ lib.optional cfg.installJdk cfg.package.jdk
    ++ [
      # ランチャーの GTK3 バックエンドが引く gschema と、gsettings CLI。
      pkgs.gsettings-desktop-schemas
      pkgs.glib
    ];

    # sessionVariables なのでログインシェル起動時にしか反映されない。
    # 変更後は再ログイン (または新しいセッション) が必要で、既存の端末から
    # そのまま起動しても効かない。
    environment.sessionVariables = lib.mkIf cfg.setGsettingsSchemaDir {
      GSETTINGS_SCHEMA_DIR = "${mergedGsettingsSchemas}/glib-2.0/schemas";
    };
  };
}
