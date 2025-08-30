# Zigrid -> Bitmap Paint Tool

A CUI (Character User Interface) paint tool written in Zig that allows you to create and animate bitmap graphics in the terminal.

## Features

- Variable canvas size (up to 128x64)
- Multiple drawing modes:
  - Pen mode for pixel-by-pixel drawing
  - Line mode for drawing straight lines
  - Rectangle mode (filled and unfilled)
  - Fill mode for flood filling areas
- Animation mode with up to 16 frames
- Save/load functionality
- Export to C array format (PROGMEM) for embedded systems
- Double-width pixels for better aspect ratio
- Optimized rendering to reduce animation flicker

## Building

```bash
zig build
```

## Usage

```bash
./zig-out/bin/zigrid [options]
```

### Options

- `-w, --width <n>`: Set canvas width (max: 128)
- `-h, --height <n>`: Set canvas height (max: 64)
- `--help`: Show help message

### Controls

#### Navigation
- `h`/`j`/`k`/`l` or arrow keys: Move cursor

#### Drawing
- `space`: Draw/activate current tool
- `m`: Switch between modes (pen → line → rectangle → fill → animation)
- `c`: Toggle color (black/white)
- `C`: Clear canvas

#### File Operations
- `s`: Save canvas to file
- `S`: Save as C array (PROGMEM format)
- `L`: Load canvas from file

#### Animation Mode
- `[`/`]`: Navigate between frames
- `n`: Create new frame
- `p`: Play/pause animation
- `-`/`+`: Adjust animation speed

#### Rectangle Mode
- `f`: Fill rectangle (when second corner is selected)

#### Other
- `q`: Quit

## Animation Mode

The animation mode allows you to create multi-frame animations:

1. Switch to animation mode by pressing `m` until you see "Animation Mode"
2. Create new frames with `n` (up to 16 frames)
3. Navigate between frames with `[` and `]`
4. Edit each frame individually
5. Press `p` to play/pause the animation
6. Adjust speed with `-` (slower) and `+` (faster)

The tool uses double buffering during animation playback to minimize screen flicker.

## File Formats

### Standard Format
The tool saves files in a simple text format:
- First line: width and height
- Following lines: pixel data (0=black, 1=white)

### C Array Format
Exports as a C array suitable for embedded systems:
- Packed format: 8 pixels per byte
- MSB first (leftmost pixel in highest bit)
- PROGMEM attribute for Arduino/AVR compatibility

## Requirements

- Zig 0.15.1 or later
- A terminal that supports ANSI escape sequences
- Must be run in an interactive terminal (not piped or redirected)
