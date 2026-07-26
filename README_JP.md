# beatoraja.nix

[English](./README.md) | 日本語

[beatoraja](https://github.com/exch-bms2/beatoraja) (BMS プレイヤー) を NixOS で
正しく動かすための flake。

**beatoraja 本体は含まない。** jar の再配布はしていない。公式の配布物は自分で
展開しておき、この flake は NixOS 上でそれを動かすためのラッパー、`.desktop`、
アイコンを提供する。

## なぜラッパーが要るのか

`beatoraja.jar` には LWJGL2 / libGDX のネイティブ `.so` が同梱されているが、
NixOS には FHS のライブラリパスも `/etc/ld.so.cache` も無いため、それらが実行時に
依存ライブラリを解決できない。ラッパーが `LD_LIBRARY_PATH` で明示的に与える。
あわせて NixOS 固有の 3 つの問題を処理している。

| 問題 | 対処しない場合の症状 |
|---|---|
| `libpulse` / `libasound` を dlopen できない | OpenAL が `oss` にフォールバックしデバイス取得が NULL になる → **完全な無音** |
| GTK3 から見える GSettings スキーマが 1 つも無い | JavaFX ランチャーが GLib の `g_error` を踏み、JVM ごと SIGABRT で落ちる |
| 同梱の PortAudio ネイティブが Windows 用のみ | PortAudio ドライバが使えず `deviceBufferSize` が効かない |

3 つ目のために [jportaudio.nix](https://github.com/solitarywalker/jportaudio.nix)
に依存している。

> **必ず `beatoraja` ラッパー経由で起動すること。** `java -jar beatoraja.jar` で
> 直接起動すると無音の症状が再現する。一方コントローラーはラッパー無しでも動いて
> しまうため紛らわしい。「音だけ出ない」場合はまず起動コマンドを疑うこと。

## 使い方

### NixOS モジュールとして (推奨)

```nix
{
  inputs.beatoraja.url = "github:solitarywalker/beatoraja.nix";
}
```

```nix
# nixosSystem の modules に
inputs.beatoraja.nixosModules.default
{
  programs.beatoraja.enable = true;
}
```

ラッパー・デスクトップエントリ・アイコンを入れ、JavaFX ランチャーに必須の
`GSETTINGS_SCHEMA_DIR` を設定する。

オプション:

| オプション | 既定 | 意味 |
|---|---|---|
| `programs.beatoraja.enable` | `false` | ランチャーを有効にする |
| `programs.beatoraja.package` | この flake でビルドしたもの | 使用するラッパーパッケージ |
| `programs.beatoraja.installJdk` | `true` | JavaFX 入り JDK をシステムの PATH にも置く。beatoraja 自体には不要 (ラッパーが自前で抱えている) |
| `programs.beatoraja.setGsettingsSchemaDir` | `true` | `GSETTINGS_SCHEMA_DIR` を設定する。他の仕組みで設定済みの場合のみ false に |

`environment.sessionVariables` はログインシェル起動時にしか反映されないので、
有効化後は再ログインが必要。既に開いている端末から起動しても効かない。

### パッケージとして

```nix
inputs.beatoraja.packages.${pkgs.stdenv.hostPlatform.system}.default
```

ただしパッケージ単体では `GSETTINGS_SCHEMA_DIR` が設定されないので、JavaFX
ランチャーは依然として abort する。この経路を使う場合は自分で設定すること。

`passthru` として `jdk` / `wrapper` / `icon` / `desktopItem` も公開している。

## beatoraja 本体の置き場所

ラッパーは jar を実行する前にゲームのディレクトリへ `cd` する。

```
$BEATORAJA_DIR、未設定なら ~/.local/share/beatoraja
```

`beatoraja.jar` が直下に来るように展開しておくこと。

## 既知の問題: 終了後に音が出なくなる

beatoraja の `PortAudioDriver` は config の `audio.driverName` に一致するデバイスが
無いと、デバイス index 0 (生の `hw:`) へ黙ってフォールバックする。`hw:` を排他
open されると PipeWire がそのカードを開き直せなくなることがあり、PipeWire も
WirePlumber も自動復帰しないため、beatoraja 終了後に全アプリが無音のままになる。

ラッパーは保険として終了時に WirePlumber を再起動する。根本対処は beatoraja 側の
設定で PipeWire 経由のデバイス (`pipewire` や `default`) を選ぶこと。

## 開発

```sh
nix build          # result/bin/beatoraja
nix fmt            # nixfmt-tree
```

## 対応プラットフォーム

`meta.platforms` は `linux`。実際に確認したのは x86_64-linux + PipeWire +
Hyprland のみ (LWJGL2 は X11 のみなので XWayland 経由で動く)。

## 生成について

このリポジトリの Nix 式 (`beatoraja.nix`, `module.nix`, `flake.nix`) と本 README は、
[Claude Code](https://claude.com/claude-code) による自動生成を利用して書かれ、
人手でレビュー・修正したもの。該当するコミットには
`Co-Authored-By: Claude <noreply@anthropic.com>` が付いている。

## ライセンス

このリポジトリの Nix 式は [MIT](./LICENSE)。beatoraja 本体は含まれておらず、
本体は本体のライセンスに従う。

`beatoraja.png` は公式の `beatoraja.exe` に埋め込まれていたアイコンを取り出した
もので、デスクトップエントリ用にのみ同梱している。
