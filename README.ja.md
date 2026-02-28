# zigrid

[English README](README.md)

`zigrid` は Zig で書かれたターミナル向けビットマップエディタです。単一画像の編集、簡易アニメーション作成、組み込み向けの C 配列や Zig アセットへの書き出しに対応しています。

## 主な機能

- 最大 `128x64` のキャンバス
- 描画モード: ペン、直線、矩形、塗りつぶし矩形、フィル
- 最大 `16` フレームのアニメーション編集
- Undo / Redo
- キャンバスとアニメーションの保存・読込
- `PROGMEM` 形式の C 配列を書き出し
- CH32/SSD1306 向けに使いやすい Zig アセットを書き出し
- 2 種類の描画方式
  - 通常の ANSI ターミナル向けブロック描画
  - `--sixel` による Sixel 描画

## 動作要件

- Zig `0.15.1` 以降
- 対話実行できるターミナル
- デフォルト描画には ANSI 対応ターミナル
- `--sixel` 使用時のみ Sixel 対応ターミナル
- パイプや標準入出力のリダイレクト経由では実行しないこと

## ビルド

```bash
zig build
```

直接起動:

```bash
./zig-out/bin/zigrid
```

Zig の run ステップ経由:

```bash
zig build run -- [options]
```

## コマンドラインオプション

```text
./zig-out/bin/zigrid [options]
```

- `-w, --width <n>`: キャンバス幅、最大 `128`
- `-h, --height <n>`: キャンバス高さ、最大 `64`
- `--load <file>`: 起動時にキャンバスソースを読み込む
- `--load-anim <file>`: 起動時にアニメーションソースを読み込む
- `--export-zig <id>`: 現在のキャンバスを Zig アセットとして書き出して終了
- `--export-zig-anim <id>`: 現在のアニメーションを Zig アセットとして書き出して終了
- `--output <file>`: 非対話の Zig 書き出し時の出力先
- `--stats`: packed 後のサイズ情報を表示して終了
- `--sixel`: Sixel 描画を使う
- `--help`: ヘルプを表示

補足:

- `--load` と `--load-anim` は同時に使えません。
- `--export-zig` と `--export-zig-anim` は同時に使えません。
- `--export-zig` と `--export-zig-anim` には `--output` が必須です。

## キー操作

### 移動

- `h` `j` `k` `l`: カーソル移動
- 矢印キー: カーソル移動

### 編集

- `space`: 描画、または現在ツールの確定
- `m`: モード切り替え `pen -> line -> rectangle -> fill -> animation`
- `c`: 色の切り替え `black/white`
- `C`: キャンバスをクリア
- `u`: Undo
- `r`: Redo

### 矩形モード

- `space`: 1 点目と 2 点目を選択
- `f`: 選択範囲を塗りつぶし矩形で描画

### ファイル操作

- `s`: 現在のキャンバスソースを保存
- `L`: キャンバスソースを読込
- `S`: C 配列として書き出し
- `z`: 現在のキャンバス、または現在フレームを Zig アセットとして書き出し

### アニメーションモード

- `[` / `]`: 前後のフレームへ移動
- `n`: 新しい空フレームを追加
- `d`: 現在フレームを削除
- `y`: 現在フレームを複製
- `p`: 再生 / 停止
- `-` / `+`: 再生速度を調整
- `a`: アニメーションソースを保存
- `o`: アニメーションソースを読込
- `A`: フレームごとの C ヘッダとメタデータを書き出し
- `Z`: アニメーション全体を Zig アセットとして書き出し

### 終了

- `q`: 終了

## 基本的な使い方

### 画像を作る

```bash
zig build run -- -w 32 -h 16
```

アプリ内で:

1. `space` で描画
2. `s` で編集用ソースを保存
3. `S` または `z` で組み込み向けデータを書き出し

### アニメーションを作る

1. `m` で animation モードへ切り替え
2. `n` でフレーム追加
3. `[` と `]` でフレーム移動
4. `a` で編集用アニメーションを保存
5. `A`、`S`、`Z` のいずれかで書き出し

## 非対話での書き出し

キャンバス:

```bash
./zig-out/bin/zigrid --load player.zg --stats
./zig-out/bin/zigrid --load player.zg --export-zig player_idle --output /tmp/player_idle.zig
```

アニメーション:

```bash
./zig-out/bin/zigrid --load-anim player_walk.anim --stats
./zig-out/bin/zigrid --load-anim player_walk.anim --export-zig-anim player_walk --output /tmp/player_walk.zig
```

## ファイル形式

### キャンバスソース形式

プレーンテキスト形式です。

- 1 行目: `<width> <height>`
- 2 行目以降: 各行のピクセルデータ
- ピクセル値: `0 = black`, `1 = white`

例:

```text
8 4
11111111
10000001
10011001
11111111
```

### アニメーションソース形式

プレーンテキスト形式です。

- 1 行目: `ANIM <width> <height> <frame_count>`
- 各フレームは `FRAME <n>` から始まる
- 各フレームのピクセル行はキャンバス形式と同じ `0/1`

例:

```text
ANIM 8 8 2
FRAME 1
11111111
10000001
10011001
10000001
10000001
10011001
10000001
11111111
FRAME 2
11111111
10000001
10111101
10000001
10000001
10111101
10000001
11111111
```

### C 配列形式

- packed `1bpp`
- 1 バイトあたり `8` ピクセル
- MSB first
- 組み込み向けの `PROGMEM` 形式

### Zig アセット形式

生成される Zig モジュールには、幅、高さ、1 行あたりバイト数、1 フレームあたりバイト数などのメタデータが含まれます。アニメーションでは各フレームのシンボルに加えて `*_frames` も生成されます。

例:

```zig
pub const blink_width: u8 = 8;
pub const blink_height: u8 = 8;
pub const blink_bytes_per_row: usize = 1;
pub const blink_bytes_per_frame: usize = 8;
pub const blink_frame_count: u8 = 2;
pub const blink_1 = [_]u8{ 0x00, 0x7e, 0x42, 0x5a, 0x42, 0x7e, 0x00, 0x00 };
pub const blink_2 = [_]u8{ 0x00, 0x3c, 0x42, 0x5a, 0x42, 0x3c, 0x00, 0x00 };
pub const blink_frames = [_][]const u8{ blink_1[0..], blink_2[0..] };
```

## 組み込み向けの使い方

CH32/SSD1306 系のプロジェクトでは、次の流れが扱いやすいです。

1. `zigrid` で画像やアニメーションを作成
2. 編集用ソースを `.zg` または `.anim` として保存
3. `.zig` アセットへ書き出し
4. ファームウェア側からそのモジュールを import

例:

```zig
const walk = @import("player_walk.zig");

fun.ssd1306.drawImage(10, 10, &walk.player_walk_1, walk.player_walk_width, walk.player_walk_height, .normal);
```
