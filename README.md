# zigrid

[日本語README](README.ja.md)

`zigrid` is a terminal bitmap editor written in Zig. It supports single-frame drawing, simple animation editing, and export to packed C or Zig assets for embedded displays.

## Highlights

- Editable canvas sizes up to `128x64`
- Drawing modes: pen, line, rectangle, filled rectangle, fill
- Animation editing with up to `16` frames
- Undo/redo support
- Save/load for both canvas and animation sources
- PNG import for re-editing on the bitmap canvas
- Export to `PROGMEM` C arrays
- Export to Zig asset modules for CH32/SSD1306-style workflows
- Two renderers:
  - block renderer for regular ANSI terminals
  - sixel renderer with `--sixel`

## Requirements

- Zig `0.15.1` or later
- An interactive terminal
- ANSI-capable terminal for the default renderer
- Sixel-capable terminal only if you use `--sixel`
- Do not run it through pipes or redirected stdin/stdout

## Build

```bash
zig build
```

Run directly:

```bash
./zig-out/bin/zigrid
```

Or through the Zig build runner:

```bash
zig build run -- [options]
```

## Command Line Options

```text
./zig-out/bin/zigrid [options]
```

- `-w, --width <n>`: canvas width, max `128`
- `-h, --height <n>`: canvas height, max `64`
- `--load <file>`: load a canvas source file or PNG image before starting
- `--load-anim <file>`: load an animation source file before starting
- `--export-zig <id>`: export the current canvas as a Zig asset and exit
- `--export-zig-anim <id>`: export the current animation as a Zig asset and exit
- `--output <file>`: output file path for non-interactive Zig export
- `--stats`: print packed asset size information and exit
- `--sixel`: use the sixel renderer
- `--help`: show help

Notes:

- `--load` and `--load-anim` are mutually exclusive.
- `--export-zig` and `--export-zig-anim` are mutually exclusive.
- `--output` is required with `--export-zig` and `--export-zig-anim`.

## Interactive Controls

### Movement

- `h` `j` `k` `l`: move cursor
- arrow keys: move cursor

### Editing

- `space`: draw or confirm the current tool action
- `m`: cycle mode `pen -> line -> rectangle -> fill -> animation`
- `c`: toggle color `black/white`
- `C`: clear canvas
- `u`: undo
- `r`: redo

### Rectangle Mode

- `space`: choose first corner, then second corner
- `f`: draw a filled rectangle after selecting corners

### File Operations

- `s`: save current canvas source
- `L`: load canvas source
- `S`: export C array
- `z`: export current canvas or current frame as a Zig asset

### Animation Mode

- `[` / `]`: previous or next frame
- `n`: add a new blank frame
- `d`: delete current frame
- `y`: duplicate current frame
- `p`: play or pause animation
- `-` / `+`: adjust playback speed
- `a`: save animation source
- `o`: load animation source
- `A`: export a C header with per-frame arrays and metadata
- `Z`: export the full animation as a Zig asset

### Quit

- `q`: quit

## Typical Workflow

### Draw a bitmap

```bash
zig build run -- -w 32 -h 16
```

Inside the app:

1. Draw with `space`
2. Save the editable source with `s`
3. Export embedded data with `S` or `z`

### Edit an animation

1. Press `m` until animation mode is active
2. Create frames with `n`
3. Move between frames with `[` and `]`
4. Save the editable animation with `a`
5. Export the animation with `A`, `S`, or `Z`

## Non-Interactive Export

Canvas:

```bash
./zig-out/bin/zigrid --load player.zg --stats
./zig-out/bin/zigrid --load player.zg --export-zig player_idle --output /tmp/player_idle.zig
```

Animation:

```bash
./zig-out/bin/zigrid --load-anim player_walk.anim --stats
./zig-out/bin/zigrid --load-anim player_walk.anim --export-zig-anim player_walk --output /tmp/player_walk.zig
```

## File Formats

### Canvas Source Format

Plain text:

- first line: `<width> <height>`
- following lines: pixel rows
- pixel values: `0 = black`, `1 = white`

Example:

```text
8 4
11111111
10000001
10011001
11111111
```

### PNG Import

`--load` and interactive `L` also accept PNG files and convert them into the editable `1bpp` canvas.

- supported PNG input: non-interlaced `8-bit` grayscale, RGB, and RGBA
- unsupported PNG input: palette/indexed color, `16-bit` channels, APNG, interlaced PNG
- images larger than `128x64` are scaled down automatically with aspect ratio preserved
- color PNGs are binarized with a fixed luminance threshold
- fully transparent pixels are imported as white

PNG import is read-only. After editing, save back to the normal zigrid canvas or animation formats.

### Animation Source Format

Plain text:

- first line: `ANIM <width> <height> <frame_count>`
- each frame starts with `FRAME <n>`
- pixel rows use the same `0/1` format as canvas files

Example:

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

### C Array Export

- packed `1bpp`
- `8` pixels per byte
- MSB first
- `PROGMEM`-style output for embedded targets

### Zig Asset Export

Generated Zig modules include metadata such as width, height, bytes per row, and bytes per frame. Animation exports also generate per-frame symbols plus a `*_frames` slice table.

Example:

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

## Embedded Use

For CH32/SSD1306-style projects:

1. Create or edit artwork in `zigrid`
2. Save the editable source as `.zg` or `.anim`
3. Export a `.zig` asset module
4. Import that module in firmware code

Example:

```zig
const walk = @import("player_walk.zig");

fun.ssd1306.drawImage(10, 10, &walk.player_walk_1, walk.player_walk_width, walk.player_walk_height, .normal);
```
