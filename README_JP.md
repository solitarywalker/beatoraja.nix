# beatoraja.nix

[English](./README.md) | 日本語

[beatoraja](https://github.com/exch-bms2/beatoraja) (BMS プレイヤー) を NixOS で
正しく動かすための flake。

公式配布物 (`beatoraja0.8.8-modernchic.zip`) を取得し、NixOS 上で正しく起動する
ためのラッパーと `.desktop` を提供する。

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

ラッパーとデスクトップエントリを入れ、JavaFX ランチャーに必須の
`GSETTINGS_SCHEMA_DIR` を設定する。書き込み用ディレクトリも用意する。

オプション:

| オプション | 既定 | 意味 |
|---|---|---|
| `programs.beatoraja.enable` | `false` | ランチャーを有効にする |
| `programs.beatoraja.package` | この flake でビルドしたもの | 使用するパッケージ |
| `programs.beatoraja.dataDir` | `/var/lib/beatoraja` | ゲームが読み書きするディレクトリ。楽曲・設定・スコアもここ |
| `programs.beatoraja.group` | `users` | dataDir を書き込めるグループ。プレイするユーザーが属している必要がある |
| `programs.beatoraja.reserveAlsaCard` | `null` | beatoraja 実行中だけ排他で確保する ALSA カード名 (例 `"Macaron"`)。[カードを排他で使う](#カードを排他で使う) を参照 |
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

`passthru` として `version` / `gameFiles` / `jdk` / `wrapper` / `desktopItem` も公開している。

## ゲームファイルの置き場所

配布物は store に入るが、store は読み取り専用で、beatoraja は自分のディレクトリへ
`config.json` / `player/` / `songdata.db` / スコアなどを書く。そのため初回起動時に
`dataDir` (既定 `/var/lib/beatoraja`) へ複製し、以降はそこで動かす。

```
$BEATORAJA_DIR、未設定なら dataDir
```

**楽曲データ・設定・スコアもすべてここに入る。** 消すと失われる。

複製済みかどうかは `beatoraja.jar` の有無で判定する。配布物が更新されても
`dataDir` は自動では上書きしない (ユーザーデータを壊さないため)。差分がある場合は
起動時に警告を出すので、必要なら手で差し替えること。

### アイコンについて

`.desktop` に `Icon=` は指定していない。beatoraja の公式配布物にはアイコン画像が
一切含まれていないため (`0.8.8` / `0.8.8-modernchic` の zip、`beatoraja.jar` の中身、
GitHub の releases をすべて確認済み)。デスクトップ環境の既定アイコンが表示される。

## カードを排他で使う

DAC を `hw:` デバイスで直接鳴らそうとすると、遅かれ早かれこれに当たる:
**そのカードが beatoraja のデバイス一覧に出てこない。**

PortAudio の ALSA ホスト API は、一覧を作るときに各 `hw:` デバイスを実際に open
して能力を調べ、`EBUSY` が返ったものを黙って落とす。USB DAC はサブデバイスが 1 つ
でハード側ミキシングも無いので、途切れずに流し込むもの (音に反応する壁紙、モニター
タップ、マイクを掴んだまま待機している VoIP クライアントなど) が 1 つでもあると
PipeWire のノードが永久に suspend せず、カードは見えないままになる。beatoraja は
何も言わない。ただ項目が無いだけ。

`reserveAlsaCard` はこれを元から潰す:

```nix
programs.beatoraja.reserveAlsaCard = "Macaron";
```

指定する名前は `/proc/asound` に出るもの、つまり `/proc/asound/cards` の id 列で
あって、PipeWire が表示する長い説明ではない:

```console
$ cat /proc/asound/cards
 2 [Macaron        ]: USB-Audio - Macaron
```

beatoraja 実行中、ラッパーは `pw-reserve` でそのカードの ALSA デバイス予約
(`org.freedesktop.ReserveDevice1`) を握り続ける。WirePlumber はこれを尊重して
再生中でもカードを閉じ、他のストリームを別のシンクへ退避させる。終了時に名前を
解放するとノードが作り直され、ストリームも戻ってくる。排他 `hw:` 利用が安全に
なるのはこれのおかげでもある。PipeWire がカードを取り合わないので、後述のノードが
壊れる状況自体が起こり得ない。

`config_sys.json` の `audio.driverName` は、PortAudio 側の綴りで書く必要がある:

```json
"driver": "PortAudio",
"driverName": "Macaron: USB Audio (hw:2,0)",
```

同じカードでも PipeWire や OpenAL が使う名前 (`Macaron Analog Stereo`) とは別物な
ので注意。一致しないと beatoraja は何も言わずデバイス index 0 へフォールバックする
(後述)。

`pipewire` や `default` デバイスを選ぶ場合は `null` のままでよい。PipeWire 経由な
ので予約は不要で、プレイ中も他のアプリがそのカードを使える。

## 終了時に WirePlumber を再起動している理由

乱暴に見えるので理由を書いておく。

beatoraja の `PortAudioDriver` は config の `audio.driverName` に一致するデバイスが
無いと、デバイス index 0 (生の `hw:`) へ黙ってフォールバックする。`hw:` を排他
open されると PipeWire がそのカードを開き直せなくなることがあり、PipeWire も
WirePlumber も自動復帰しない。放置すれば beatoraja 終了後に全アプリが無音のままに
なるが、WirePlumber を再起動すると ALSA のノードが作り直されて復旧する。

beatoraja が奪い合わずに済むデバイスを選んでおけば、この状況自体が起きない。
beatoraja 側の設定で PipeWire 経由のデバイス (`pipewire` や `default`) を選ぶか、
`reserveAlsaCard` で明け渡させたカードの `hw:` を選ぶか。再起動はそうしていない
場合の保険。

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

このリポジトリの Nix 式は [MIT](./LICENSE)。beatoraja 本体はこのリポジトリには
含まれず、ビルド時に公式配布元から取得される。本体は本体のライセンスに従う。
