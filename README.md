# beatoraja.nix

English | [日本語](./README_JP.md)

A Nix flake that makes [beatoraja](https://github.com/exch-bms2/beatoraja) (a BMS
player) run correctly on NixOS.

**This does not package beatoraja itself.** The jar is not redistributed here.
You extract the official release yourself, and this flake provides the launcher
wrapper, `.desktop` entry, and icon that make it work on NixOS.

## Why a wrapper is needed

`beatoraja.jar` bundles native `.so` files for LWJGL2 / libGDX, but NixOS has
neither the FHS library paths nor `/etc/ld.so.cache`, so those natives cannot
resolve their dependencies at runtime. The wrapper supplies them via
`LD_LIBRARY_PATH`. It also handles three NixOS-specific problems:

| Problem | Symptom without the fix |
|---|---|
| `libpulse` / `libasound` not loadable | OpenAL falls back to `oss`, device handle is NULL — **completely silent** |
| No GSettings schemas visible to GTK3 | The JavaFX launcher hits GLib's `g_error` and the JVM dies with SIGABRT |
| Windows-only PortAudio natives shipped | The PortAudio driver is unusable, so `deviceBufferSize` has no effect |

The third one is why this flake depends on
[jportaudio.nix](https://github.com/solitarywalker/jportaudio.nix).

> **Always launch through the `beatoraja` wrapper.** Running `java -jar
> beatoraja.jar` directly reproduces the silent-audio failure. Controllers, on
> the other hand, work either way, which makes the problem misleading to
> diagnose — so if only the sound is missing, suspect the launch command first.

## Usage

### As a NixOS module (recommended)

```nix
{
  inputs.beatoraja.url = "github:solitarywalker/beatoraja.nix";
}
```

```nix
# in your nixosSystem modules
inputs.beatoraja.nixosModules.default
{
  programs.beatoraja.enable = true;
}
```

This installs the wrapper, the desktop entry and the icon, and sets
`GSETTINGS_SCHEMA_DIR` — which the JavaFX launcher requires.

Options:

| Option | Default | Meaning |
|---|---|---|
| `programs.beatoraja.enable` | `false` | Enable the launcher |
| `programs.beatoraja.package` | built from this flake | The wrapper package to use |
| `programs.beatoraja.installJdk` | `true` | Also put the JavaFX-enabled JDK on the system PATH. Not needed by beatoraja itself — the wrapper carries its own |
| `programs.beatoraja.setGsettingsSchemaDir` | `true` | Set `GSETTINGS_SCHEMA_DIR`. Turn off only if something else already sets it |

`environment.sessionVariables` only takes effect for login shells, so you need to
log in again after enabling this — starting beatoraja from an already-open
terminal will not pick it up.

### As a package

```nix
inputs.beatoraja.packages.${pkgs.stdenv.hostPlatform.system}.default
```

Note that using the package alone skips `GSETTINGS_SCHEMA_DIR`, so the JavaFX
launcher will still abort. Set it yourself if you go this route.

The package also exposes, via `passthru`: `jdk`, `wrapper`, `icon`,
`desktopItem`.

## Where beatoraja itself goes

The wrapper `cd`s into the game directory before running the jar:

```
$BEATORAJA_DIR, or ~/.local/share/beatoraja if unset
```

Put the extracted release there, so that `beatoraja.jar` sits directly inside it.

## Known issue: audio dying after you quit

beatoraja's `PortAudioDriver` silently falls back to device index 0 (a raw `hw:`
device) when no device matches `audio.driverName` in the config. Opening `hw:`
exclusively can leave PipeWire unable to reopen the card, and neither PipeWire
nor WirePlumber recovers on its own — every application stays silent after
beatoraja exits.

The wrapper restarts WirePlumber on exit as a safety net. The real fix is to pick
a PipeWire-backed device (`pipewire` or `default`) in beatoraja's own settings.

## Development

```sh
nix build          # result/bin/beatoraja
nix fmt            # nixfmt-tree
```

## Supported platforms

`meta.platforms` is `linux`, and this has only been exercised on x86_64-linux
with PipeWire and Hyprland (LWJGL2 is X11-only, so it runs through XWayland).

## On AI generation

The Nix expressions (`beatoraja.nix`, `module.nix`, `flake.nix`) and this README
were written with the help of [Claude Code](https://claude.com/claude-code) and
then reviewed and corrected by hand. The relevant commits carry a
`Co-Authored-By: Claude <noreply@anthropic.com>` trailer.

## License

The Nix expressions in this repository are [MIT](./LICENSE). beatoraja itself is
not included here and is under its own license.

`beatoraja.png` was extracted from the icon embedded in the official
`beatoraja.exe` and is redistributed here for the desktop entry only.
