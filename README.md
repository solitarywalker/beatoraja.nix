# beatoraja.nix

English | [日本語](./README_JP.md)

A Nix flake that makes [beatoraja](https://github.com/exch-bms2/beatoraja) (a BMS
player) run correctly on NixOS.

It fetches the official release (`beatoraja0.8.8-modernchic.zip`) and provides the
launcher wrapper and `.desktop` entry that make it work on NixOS.

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

This installs the wrapper and the desktop entry, sets `GSETTINGS_SCHEMA_DIR` —
which the JavaFX launcher requires — and prepares the writable game directory.

Options:

| Option | Default | Meaning |
|---|---|---|
| `programs.beatoraja.enable` | `false` | Enable the launcher |
| `programs.beatoraja.package` | built from this flake | The package to use |
| `programs.beatoraja.dataDir` | `/var/lib/beatoraja` | Where the game reads and writes. Songs, settings and scores live here |
| `programs.beatoraja.group` | `users` | Group allowed to write `dataDir`. Players must belong to it |
| `programs.beatoraja.reserveAlsaCard` | `null` | ALSA card to hold exclusively while beatoraja runs, e.g. `"Macaron"`. See [Playing a card exclusively](#playing-a-card-exclusively) |
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

The package also exposes, via `passthru`: `version`, `gameFiles`, `jdk`,
`wrapper`, `desktopItem`.

## Where the game files go

The release lands in the Nix store, but the store is read-only while beatoraja
writes `config.json`, `player/`, `songdata.db` and scores into its own directory.
So on first launch the wrapper copies it into `dataDir` (`/var/lib/beatoraja` by
default) and runs from there.

```
$BEATORAJA_DIR, or dataDir if unset
```

**Your songs, settings and scores all live there too.** Deleting it loses them.

Whether the copy has happened is decided by the presence of `beatoraja.jar`. A
newer release never overwrites `dataDir` automatically — that would risk your
data — so the wrapper just warns when the two differ, and you update by hand.

### About the icon

The `.desktop` entry sets no `Icon=`. The official beatoraja distribution ships
no icon image at all — verified across the `0.8.8` and `0.8.8-modernchic` zips,
the contents of `beatoraja.jar`, and the GitHub releases — so there is nothing to
extract. Your desktop environment's default icon is shown instead.

## Playing a card exclusively

If you want beatoraja to drive a DAC directly through a `hw:` device, you will
sooner or later hit this: **the card is not in beatoraja's device list at all.**

PortAudio's ALSA host API builds that list by actually opening every `hw:` device
to probe it, and silently drops the ones that come back `EBUSY`. A USB DAC has a
single subdevice and no hardware mixing, so anything that streams to it without
pause — an audio-reactive wallpaper, a monitor tap, a VoIP client sitting idle
with the mic open — keeps PipeWire from ever suspending the node, and the card
stays invisible. Nothing in beatoraja reports this; the entry is simply missing.

`reserveAlsaCard` fixes it at the source:

```nix
programs.beatoraja.reserveAlsaCard = "Macaron";
```

The name is the one in `/proc/asound` — the id column of `/proc/asound/cards`,
not the long description PipeWire shows:

```console
$ cat /proc/asound/cards
 2 [Macaron        ]: USB-Audio - Macaron
```

For as long as beatoraja runs, the wrapper holds the ALSA device reservation
(`org.freedesktop.ReserveDevice1`) on that card via `pw-reserve`. WirePlumber
honours it, closes the card even mid-playback, and moves everything else to
another sink; on exit the name is released and the node comes back, streams
included. This is also what makes exclusive `hw:` use safe in the first place —
PipeWire is not competing for the card, so it cannot end up with the broken node
described below.

`audio.driverName` in `config_sys.json` still has to name the card the way
PortAudio spells it:

```json
"driver": "PortAudio",
"driverName": "Macaron: USB Audio (hw:2,0)",
```

Beware that this is *not* the name PipeWire or OpenAL uses for the same card
(`Macaron Analog Stereo`). If it does not match, beatoraja falls back to device
index 0 without saying so — see below.

Leave the option at `null` if you select the `pipewire` or `default` device
instead. Those go through PipeWire, need no reservation, and leave the card
available to everything else while you play.

## Why the wrapper restarts WirePlumber on exit

It does, and that looks heavy-handed, so here is the reason.

beatoraja's `PortAudioDriver` silently falls back to device index 0 (a raw `hw:`
device) when no device matches `audio.driverName` in the config. Opening `hw:`
exclusively can leave PipeWire unable to reopen the card, and neither PipeWire
nor WirePlumber recovers on its own. Left alone, every application would stay
silent after beatoraja exits. Restarting WirePlumber recreates the ALSA nodes and
clears it.

Picking a device beatoraja does not have to fight over avoids the situation
altogether — either a PipeWire-backed one (`pipewire` or `default`) in
beatoraja's own settings, or a `hw:` device on a card handed over with
`reserveAlsaCard`. The restart is only a safety net for when you haven't.

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
not included in this repository — it is fetched from the official download at
build time — and is under its own license.
