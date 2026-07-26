{
  lib,
  stdenv,
  runCommand,
  symlinkJoin,
  writeShellApplication,
  makeDesktopItem,
  openjdk,
  openjfx,
  systemd,
  systemdLibs,
  libx11,
  libxcursor,
  libxext,
  libxrandr,
  libxxf86vm,
  libGL,
  libpulseaudio,
  alsa-lib,
  jportaudio,
  # beatoraja 本体 (jar) は同梱しない。ここは jar を展開したディレクトリを指す。
  # 実行時に BEATORAJA_DIR で上書きできる。
  dataDir ? "$HOME/.local/share/beatoraja",
}:

let
  # ランチャー画面 (PlayConfigurationView) は JavaFX 製なので JavaFX 入りの JDK が要る。
  # WebKit はランチャー内の HTML 表示用。
  #
  # これを関数引数にして外から差し替え可能にしてはいけない。下の
  # LD_LIBRARY_PATH に足す ${jdk}/lib/openjdk/lib と、runtimeInputs 経由で PATH に
  # 載る java が、同一の JDK でなければならないため:
  #
  #   liblwjgl64.so  NEEDED  libjawt.so            (バージョン無し)
  #   libjawt.so     NEEDED  libjvm.so, libjava.so, libawt.so, ...
  #                  RUNPATH <その JDK>/lib/openjdk/lib
  #                         :<その JDK>/lib/openjdk/lib/server
  #
  # libjawt.so は RUNPATH で自分の出身 JDK に固定されているので、必ず出身 JDK の
  # libjvm.so を引き連れてくる。PATH 側と LD_LIBRARY_PATH 側がずれると 1 プロセスに
  # libjvm.so が 2 つ載る。Nix はこの不整合を検出できない (どちらも正当なパスなので
  # ビルドも評価も通り、実行時に初めて壊れる)。
  jdk = openjdk.override {
    enableJavaFX = true;
    openjfx_jdk = openjfx.override { withWebKit = true; };
  };

  # beatoraja.jar には LWJGL2 / libGDX のネイティブ .so が同梱されているが、
  # NixOS には FHS のライブラリパスも /etc/ld.so.cache も無いため、それらが
  # 実行時に依存ライブラリを解決できない。LD_LIBRARY_PATH で明示的に与える。
  #
  #   - libpulse / libasound : 必須。これが無いと OpenAL は pulse も alsa も
  #                            dlopen できず oss にフォールバックし、
  #                            デバイス取得が NULL になって完全な無音になる。
  #                            (実測: java -jar で直接起動すると再現する)
  #                            => 必ず この beatoraja ラッパー経由で起動すること
  #
  #   - libX11 / libstdc++   : libgdx-controllers-desktop64.so が DT_NEEDED で
  #                            要求する。ただし実際には JVM が AWT/JavaFX 用に
  #                            読み込む JDK 同梱ネイティブ (RPATH 付き) が先に
  #                            これらをプロセスへ載せるため、ここに無くても
  #                            コントローラーは動いてしまう。読み込み順に
  #                            依存しないよう明示しておく。
  #
  #   - libjawt (JDK 同梱)   : liblwjgl64.so が DT_NEEDED で要求する。
  #                            ここに足す JDK は runtimeInputs の JDK と同一で
  #                            なければならない (理由は上の jdk のコメント)
  #
  #   - jportaudio           : beatoraja の PortAudio ドライバは Linux では
  #                            System.loadLibrary("jportaudio") で
  #                            libjportaudio.so を探すが、配布物に入っている
  #                            ネイティブは Windows 用の jportaudio_x64.dll /
  #                            portaudio_x64.dll だけ (jar 内は Java バインディング
  #                            com/portaudio/*.class のみ)。
  #                            OpenAL ドライバ経路だと config の deviceBufferSize は
  #                            libGDX の audioDeviceBufferSize にしか渡らず効かないが、
  #                            PortAudio ドライバでは
  #                              suggestedLatency = deviceBufferSize / sampleRate
  #                              openStream(..., framesPerBuffer = deviceBufferSize, ...)
  #                            として直接効く。
  wrapper = writeShellApplication {
    name = "beatoraja";
    runtimeInputs = [
      jdk
      systemd
    ];
    text = ''
      export LD_LIBRARY_PATH=${
        lib.makeLibraryPath [
          libx11
          libxext
          libxcursor
          libxrandr
          libxxf86vm
          stdenv.cc.cc.lib
          libpulseaudio
          alsa-lib
          libGL
          systemdLibs
          jportaudio
        ]
      }:${jdk}/lib/openjdk/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

      # pipewire-pulse を優先し、無ければ ALSA へ
      export ALSOFT_DRIVERS="''${ALSOFT_DRIVERS:-pulse,alsa}"

      # PortAudio ドライバの後始末。
      #
      # beatoraja の PortAudioDriver は config の audio.driverName に一致する
      # デバイスが無いと、デバイス index 0 ( = 生の hw: ) へ黙ってフォールバック
      # する (PortAudioDriver.<init> の初期値が 0。Pa_GetDefaultOutputDevice は
      # 使われない)。hw: を排他 open されると、アイドル中に suspend していた
      # PipeWire がそのカードを開き直せず
      #   spa.alsa: 'front:N': playback open failed: Device or resource busy
      #   pw.node: (alsa_output.*) suspended -> error
      # とノードが壊れる。PipeWire も WirePlumber も自動復帰しないため、
      # beatoraja 終了後は全アプリが無音のままになる。
      #
      # ALSA のデバイス/ノードを作っているのは WirePlumber なので、これだけ
      # 再起動すれば作り直されて復旧する (実測で確認)。pipewire 本体は落と
      # さないので他アプリの PipeWire 接続は切れない (再生中のストリームが
      # 一瞬途切れる程度)。
      #
      # 壊れたかどうかを検出して条件付きで実行する、はやらない。実測した限り
      # 壊れ方が一定しないため:
      #   - ノードが error 状態で残る場合   (journal の suspended -> error)
      #   - ノードごと pw-dump から消える場合 (hw: を先に掴まれて生成に失敗)
      # 前者だけを見ていると後者を取りこぼす。
      # (加えて writeShellApplication は set -o pipefail なので
      #  `pw-dump | grep -q ...` は grep が先に終了して pw-dump が SIGPIPE で
      #  死に、マッチしてもしなくても常に false になる。この手の条件式は書けない)
      #
      # 根本対処は beatoraja 側で PipeWire 経由のデバイス ("pipewire" や
      # "default") を選ぶこと。これはあくまで取りこぼした場合の保険。
      restartWireplumber() {
        systemctl --user restart wireplumber || true
      }
      trap restartWireplumber EXIT

      cd "''${BEATORAJA_DIR:-${dataDir}}"
      # -DLWJGL_WM_CLASS: 下の desktopItem の startupWMClass と対応
      # trap を効かせるため exec しない
      java -DLWJGL_WM_CLASS=beatoraja -jar beatoraja.jar "$@"
    '';
  };

  # beatoraja.exe に埋め込まれていたアイコン (200x200) を取り出したもの。
  # hicolor の標準サイズではないので share/pixmaps に置く
  # (freedesktop のアイコン探索のフォールバック先で、Icon=beatoraja で引ける)。
  icon = runCommand "beatoraja-icon" { } ''
    install -Dm444 ${./beatoraja.png} $out/share/pixmaps/beatoraja.png
  '';

  # タスクバー (Plasma パネル) にピン留めするためのランチャー。
  #
  # startupWMClass は「起動中のウィンドウ」を「ピン留めしたアイコン」に
  # 紐づけるために必要。beatoraja の描画は LWJGL2 = X11 (XWayland) 経路で、
  # LinuxDisplay.createWindow が
  #   wm_class = System.getProperty("LWJGL_WM_CLASS")   # 未設定なら Display.getTitle()
  #   setClassHint(Display.getTitle(), wm_class)
  # として WM_CLASS の res_class を決める。既定のままだとタイトル
  # ("beatoraja <version>" 等) に依存してしまうので、上のラッパーで
  # -DLWJGL_WM_CLASS=beatoraja に固定し、ここでそれと一致させる。
  #
  # startupNotify は false。Java 側が startup notification を完了させないため、
  # true だとカーソルのローディング表示が起動後もしばらく残る。
  desktopItem = makeDesktopItem {
    name = "beatoraja";
    desktopName = "beatoraja";
    genericName = "BMS Player";
    exec = "${wrapper}/bin/beatoraja";
    icon = "beatoraja";
    terminal = false;
    startupNotify = false;
    startupWMClass = "beatoraja";
    categories = [ "Game" ];
  };
in

symlinkJoin {
  name = "beatoraja";

  paths = [
    wrapper
    icon
    desktopItem
  ];

  passthru = {
    inherit
      jdk
      wrapper
      icon
      desktopItem
      ;
  };

  meta = {
    description = "Launcher for beatoraja (BMS player) on NixOS";
    longDescription = ''
      beatoraja 本体は含まない。jar を展開したディレクトリ (既定では
      ~/.local/share/beatoraja) を別途用意しておく必要がある。このパッケージは
      NixOS 上でその jar を正しく起動するためのラッパー、.desktop、アイコンを提供する。
    '';
    homepage = "https://github.com/solitarywalker/beatoraja.nix";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "beatoraja";
  };
}
