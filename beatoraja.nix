{
  lib,
  stdenv,
  fetchzip,
  symlinkJoin,
  writeShellApplication,
  makeDesktopItem,
  coreutils,
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
  pipewire,
  # Directory the game reads and writes at runtime. The store is read-only, so the
  # distribution is copied here first. Overridable at runtime via BEATORAJA_DIR.
  dataDir ? "/var/lib/beatoraja",
  # ALSA card to hold exclusively while beatoraja runs, named as it appears in
  # /proc/asound (the id column of /proc/asound/cards), e.g. "Macaron". null
  # disables the reservation entirely. See the comment on it in the wrapper.
  reserveAlsaCard ? null,
}:

let
  version = "0.8.8-modernchic";

  # The distribution. 671 MB once unpacked, so it takes up a fair chunk of store.
  #
  # The zip contains Shift-JIS filenames, which makes nix-prefetch-url --unpack
  # (libarchive) fail on locale conversion. fetchzip goes through unzip, which
  # handles them.
  gameFiles = fetchzip {
    name = "beatoraja-${version}-dist";
    url = "https://mocha-repository.info/download/beatoraja${version}.zip";
    hash = "sha256-TujfJ7hgjEKs5NbGvwo3/nkbJFvcZ4mefgkdp6oQHw4=";
    stripRoot = true;
  };

  # The launcher screen (PlayConfigurationView) is JavaFX, so the JDK needs it
  # built in. WebKit is for the HTML view inside that launcher.
  #
  # Do NOT turn this into a function argument to make it swappable. The
  # ${jdk}/lib/openjdk/lib entry added to LD_LIBRARY_PATH below and the java that
  # runtimeInputs puts on PATH have to be the same JDK:
  #
  #   liblwjgl64.so  NEEDED  libjawt.so            (unversioned)
  #   libjawt.so     NEEDED  libjvm.so, libjava.so, libawt.so, ...
  #                  RUNPATH <that JDK>/lib/openjdk/lib
  #                         :<that JDK>/lib/openjdk/lib/server
  #
  # libjawt.so is pinned by RUNPATH to the JDK it came from, so it always drags
  # that JDK's libjvm.so in with it. If the PATH side and the LD_LIBRARY_PATH side
  # disagree, one process ends up with two libjvm.so loaded. Nix cannot catch this
  # mismatch — both paths are legitimate, so it builds and evaluates fine and only
  # breaks at runtime.
  jdk = openjdk.override {
    enableJavaFX = true;
    openjfx_jdk = openjfx.override { withWebKit = true; };
  };

  # beatoraja.jar bundles native .so files for LWJGL2 / libGDX, but NixOS has
  # neither the FHS library paths nor /etc/ld.so.cache, so those natives cannot
  # resolve their dependencies at runtime. Hand them over via LD_LIBRARY_PATH.
  #
  #   - libpulse / libasound : Required. Without them OpenAL can dlopen neither
  #                            pulse nor alsa, falls back to oss, and the device
  #                            handle comes back NULL — completely silent.
  #                            (Measured: reproducible by running java -jar
  #                            directly.)
  #                            => always launch through this beatoraja wrapper
  #
  #   - libX11 / libstdc++   : Required by libgdx-controllers-desktop64.so via
  #                            DT_NEEDED. In practice the JDK's own natives (which
  #                            carry an RPATH), loaded by the JVM for AWT/JavaFX,
  #                            already pull these into the process first, so
  #                            controllers work even without them here. Listed
  #                            anyway so nothing depends on load order.
  #
  #   - libjawt (from JDK)   : Required by liblwjgl64.so via DT_NEEDED. The JDK
  #                            added here must be the same one as in
  #                            runtimeInputs — see the comment on jdk above.
  #
  #   - jportaudio           : On Linux beatoraja's PortAudio driver looks for
  #                            libjportaudio.so via
  #                            System.loadLibrary("jportaudio"), but the natives
  #                            shipped in the distribution are Windows-only
  #                            (jportaudio_x64.dll / portaudio_x64.dll; the jar
  #                            itself holds only the Java bindings in
  #                            com/portaudio/*.class).
  #                            On the OpenAL path, deviceBufferSize from the
  #                            config only reaches libGDX's audioDeviceBufferSize
  #                            and has no effect, whereas the PortAudio driver
  #                            applies it directly as
  #                              suggestedLatency = deviceBufferSize / sampleRate
  #                              openStream(..., framesPerBuffer = deviceBufferSize, ...)
  wrapper = writeShellApplication {
    name = "beatoraja";
    runtimeInputs = [
      jdk
      systemd
      # cp / chmod / mkdir / cat for the first-run copy. PATH can be minimal when
      # launched from the .desktop entry, so don't rely on the environment.
      coreutils
    ]
    # pw-reserve. Only pulled in when a card is actually being reserved.
    ++ lib.optional (reserveAlsaCard != null) pipewire;
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

      # Prefer pipewire-pulse, fall back to ALSA
      export ALSOFT_DRIVERS="''${ALSOFT_DRIVERS:-pulse,alsa}"
      ${lib.optionalString (reserveAlsaCard != null) ''

        # Holding one ALSA card exclusively for as long as beatoraja runs.
        #
        # PortAudio's ALSA host API builds its device list by actually opening every
        # hw: device to probe it, and silently drops the ones that come back EBUSY.
        # A card PipeWire is holding open therefore does not even appear in
        # beatoraja's device list — it cannot be picked, let alone used. A USB DAC
        # has a single subdevice and no hardware mixing, so anything streaming to it
        # without pause (an audio-reactive wallpaper, a monitor tap, ...) keeps the
        # node from ever suspending and hides the card for good.
        #
        # WirePlumber honours org.freedesktop.ReserveDevice1: while another process
        # owns AudioN it closes that card — mid-playback if need be — and recreates
        # the node once the name is released. pw-reserve is the tool that does
        # nothing but hold the name. Streams sitting on the card move to another
        # sink while it is held and come back afterwards (measured).
        #
        # This is what makes exclusive hw: use safe: PipeWire is not competing for
        # the card, so the "hw: grabbed first, node left broken" failure described
        # below cannot arise in the first place. The WirePlumber restart stays on as
        # a safety net for the case where pw-reserve dies before beatoraja does.
        #
        # N in AudioN is the ALSA card index, which moves around for USB devices, so
        # it is resolved through the /proc/asound/<card name> symlink at launch
        # instead of being baked into the wrapper.
        alsaCardIsOpen() {
          local f
          for f in /proc/asound/"$1"/pcm*p/sub*/status; do
            [[ -e "$f" ]] || continue
            [[ "$(head -n 1 "$f")" == closed ]] || return 0
          done
          return 1
        }

        acquireAlsaCard() {
          local name=$1
          local index i

          if [[ ! -e /proc/asound/$name ]]; then
            echo "beatoraja: ALSA card '$name' not found, running without reserving it" >&2
            return 0
          fi
          index=$(readlink /proc/asound/"$name")

          pw-reserve -n "Audio''${index#card}" -r -p 100 -a beatoraja &
          reservePid=$!

          # RequestRelease is asynchronous — pw-reserve is up long before
          # WirePlumber has actually let go — so wait for the card to close rather
          # than guess at a delay.
          for ((i = 0; i < 50; i++)); do
            alsaCardIsOpen "$name" || return 0
            sleep 0.2
          done
          echo "beatoraja: ALSA card '$name' did not come free within 10s, starting anyway" >&2
        }

        releaseAlsaCard() {
          [[ -n "''${reservePid:-}" ]] || return 0
          kill "$reservePid" 2>/dev/null || true
          wait "$reservePid" 2>/dev/null || true
          reservePid=""
        }
      ''}

      # Cleaning up after the PortAudio driver.
      #
      # When no device matches audio.driverName in the config, beatoraja's
      # PortAudioDriver silently falls back to device index 0 ( = a raw hw: ).
      # That 0 is just the initial value in PortAudioDriver.<init>;
      # Pa_GetDefaultOutputDevice is never called. Once hw: is opened
      # exclusively, a PipeWire that had suspended the card while idle cannot
      # reopen it:
      #   spa.alsa: 'front:N': playback open failed: Device or resource busy
      #   pw.node: (alsa_output.*) suspended -> error
      # and the node is left broken. Neither PipeWire nor WirePlumber recovers on
      # its own, so every application stays silent after beatoraja exits.
      #
      # WirePlumber is what creates the ALSA devices/nodes, so restarting just
      # that recreates them and clears it (verified in practice). PipeWire itself
      # is left running, so other applications keep their connections — a playing
      # stream cuts out for a moment at worst.
      #
      # Deliberately unconditional: no attempt to detect whether it actually
      # broke. Observed failures are not consistent —
      #   - the node stays in error state    (suspended -> error in the journal)
      #   - the node vanishes from pw-dump   (hw: was grabbed first, so it never
      #                                       got created)
      # and watching only for the former misses the latter.
      # (On top of that, writeShellApplication sets -o pipefail, so
      #  `pw-dump | grep -q ...` always evaluates false: grep exits first and
      #  pw-dump dies of SIGPIPE whether or not it matched. Conditions of this
      #  shape simply cannot be written here.)
      #
      # The real fix is to select a device beatoraja does not have to fight over —
      # either a PipeWire-backed one ("pipewire" or "default") in beatoraja's own
      # settings, or a hw: device on a card handed over via reserveAlsaCard above.
      # This is only a safety net for when neither has been done.
      #
      # Trapped on INT/TERM as well as EXIT, because bash does not run the EXIT trap
      # for a signal it has no handler for — and leaving the reservation held would
      # keep the card away from the rest of the session. Disarmed on entry so it
      # cannot run twice.
      cleanup() {
        trap - EXIT INT TERM
        ${lib.optionalString (reserveAlsaCard != null) "releaseAlsaCard"}
        systemctl --user restart wireplumber || true
      }
      trap cleanup EXIT INT TERM
      ${lib.optionalString (
        reserveAlsaCard != null
      ) "acquireAlsaCard ${lib.escapeShellArg reserveAlsaCard}"}

      # The distribution lives in the store and is read-only, but beatoraja writes
      # config.json / player/ / songdata.db / scores into its own directory. So
      # copy it once into the writable dataDir and work from there afterwards.
      dir="''${BEATORAJA_DIR:-${dataDir}}"
      stamp="$dir/.beatoraja-nix-dist"

      if [[ ! -e "$dir/beatoraja.jar" ]]; then
        echo "beatoraja: unpacking the distribution into $dir (first run only, takes a few minutes)" >&2
        mkdir -p "$dir"
        cp -r ${gameFiles}/. "$dir"/
        # Files copied out of the store are read-only; make them writable.
        chmod -R ug+w "$dir"
        echo "${gameFiles}" > "$stamp"
      elif [[ "$(cat "$stamp" 2>/dev/null || true)" != "${gameFiles}" ]]; then
        # The distribution changed but dataDir still holds the old one. Not
        # overwritten automatically — that would risk the user's data.
        echo "beatoraja: the distribution has been updated (${version})." >&2
        echo "  Using $dir as it is. To pick the update up, replace beatoraja.jar" >&2
        echo "  and friends by hand from ${gameFiles}" >&2
      fi

      cd "$dir"
      # -DLWJGL_WM_CLASS: pairs with startupWMClass in desktopItem below
      # Not exec'd, so that the trap still fires
      java -DLWJGL_WM_CLASS=beatoraja -jar beatoraja.jar "$@"
    '';
  };

  # Launcher entry, so it can be pinned to the taskbar (Plasma panel).
  #
  # No Icon is set. The official beatoraja distribution ships no icon image at all
  # — verified across the 0.8.8 and 0.8.8-modernchic zips, the contents of the
  # jar, and the GitHub releases — so there is nothing to extract. The desktop
  # environment's default icon is shown instead.
  #
  # startupWMClass is what ties "the window that opened" to "the icon you pinned".
  # beatoraja draws through LWJGL2 = X11 (XWayland), where
  # LinuxDisplay.createWindow decides the res_class of WM_CLASS as
  #   wm_class = System.getProperty("LWJGL_WM_CLASS")   # Display.getTitle() if unset
  #   setClassHint(Display.getTitle(), wm_class)
  # Left at its default that would depend on the title ("beatoraja <version>" and
  # such), so the wrapper above pins it to -DLWJGL_WM_CLASS=beatoraja and this
  # matches it.
  #
  # startupNotify is false: Java never completes the startup notification, so with
  # true the loading cursor lingers for a while after the window is already up.
  desktopItem = makeDesktopItem {
    name = "beatoraja";
    desktopName = "beatoraja";
    genericName = "BMS Player";
    exec = "${wrapper}/bin/beatoraja";
    terminal = false;
    startupNotify = false;
    startupWMClass = "beatoraja";
    categories = [ "Game" ];
  };
in

symlinkJoin {
  name = "beatoraja-${version}";

  paths = [
    wrapper
    desktopItem
  ];

  passthru = {
    inherit
      version
      gameFiles
      jdk
      wrapper
      desktopItem
      ;
  };

  meta = {
    description = "beatoraja (BMS player) for NixOS";
    longDescription = ''
      Fetches the official distribution (beatoraja${version}.zip) and provides the
      wrapper and .desktop entry needed to launch it correctly on NixOS. The store
      is read-only, so on first run it is copied into ${dataDir} and run from
      there.
    '';
    homepage = "https://github.com/solitarywalker/beatoraja.nix";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "beatoraja";
  };
}
