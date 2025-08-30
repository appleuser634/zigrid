const std = @import("std");

const MAX_WIDTH = 128;
const MAX_HEIGHT = 64;

const Color = enum(u8) {
    black = 0,
    white = 1,
};

const Canvas = struct {
    width: usize,
    height: usize,
    pixels: [][]Color,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Canvas {
        if (width > MAX_WIDTH or height > MAX_HEIGHT) {
            return error.CanvasTooLarge;
        }

        var pixels = try allocator.alloc([]Color, height);
        errdefer allocator.free(pixels);

        for (pixels, 0..) |*row, i| {
            errdefer {
                for (pixels[0..i]) |r| {
                    allocator.free(r);
                }
            }
            row.* = try allocator.alloc(Color, width);
            @memset(row.*, Color.white);
        }

        return Canvas{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Canvas) void {
        for (self.pixels) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.pixels);
    }

    fn copy(self: Canvas, allocator: std.mem.Allocator) !Canvas {
        var new_canvas = try Canvas.init(allocator, self.width, self.height);
        for (self.pixels, 0..) |row, y| {
            for (row, 0..) |pixel, x| {
                new_canvas.pixels[y][x] = pixel;
            }
        }
        return new_canvas;
    }

    fn setPixel(self: *Canvas, x: usize, y: usize, color: Color) void {
        if (x < self.width and y < self.height) {
            self.pixels[y][x] = color;
        }
    }

    fn getPixel(self: Canvas, x: usize, y: usize) ?Color {
        if (x < self.width and y < self.height) {
            return self.pixels[y][x];
        }
        return null;
    }

    fn clear(self: *Canvas) void {
        for (self.pixels) |row| {
            @memset(row, Color.white);
        }
    }

    fn render(self: Canvas, stdout: std.fs.File) !void {
        try stdout.writeAll("\x1B[2J\x1B[H"); // Clear screen and move cursor to top

        // Top border
        try stdout.writeAll("┌");
        for (0..self.width * 2) |_| {
            try stdout.writeAll("─");
        }
        try stdout.writeAll("┐\n");

        // Canvas content
        for (self.pixels) |row| {
            try stdout.writeAll("│");
            for (row) |pixel| {
                const chars = switch (pixel) {
                    .black => "██",
                    .white => "  ",
                };
                try stdout.writeAll(chars);
            }
            try stdout.writeAll("│\n");
        }

        // Bottom border
        try stdout.writeAll("└");
        for (0..self.width * 2) |_| {
            try stdout.writeAll("─");
        }
        try stdout.writeAll("┘\n");
    }

    fn renderOptimized(self: Canvas, stdout: std.fs.File, allocator: std.mem.Allocator) !void {
        _ = allocator; // Not needed with fixed buffer

        // Use a fixed buffer for better performance
        var buffer: [30000]u8 = undefined; // Large enough for max canvas with UTF-8
        var idx: usize = 0;

        // Move cursor to top without clearing screen
        const header = "\x1B[H";
        @memcpy(buffer[idx .. idx + header.len], header);
        idx += header.len;

        // Top border
        const top_left = "┌";
        @memcpy(buffer[idx .. idx + top_left.len], top_left);
        idx += top_left.len;

        for (0..self.width * 2) |_| {
            const h_line = "─";
            @memcpy(buffer[idx .. idx + h_line.len], h_line);
            idx += h_line.len;
        }

        const top_right = "┐\n";
        @memcpy(buffer[idx .. idx + top_right.len], top_right);
        idx += top_right.len;

        // Canvas content
        for (self.pixels) |row| {
            const v_line = "│";
            @memcpy(buffer[idx .. idx + v_line.len], v_line);
            idx += v_line.len;

            for (row) |pixel| {
                const chars = switch (pixel) {
                    .black => "██",
                    .white => "  ",
                };
                @memcpy(buffer[idx .. idx + chars.len], chars);
                idx += chars.len;
            }

            @memcpy(buffer[idx .. idx + v_line.len], v_line);
            idx += v_line.len;
            buffer[idx] = '\n';
            idx += 1;
        }

        // Bottom border
        const bottom_left = "└";
        @memcpy(buffer[idx .. idx + bottom_left.len], bottom_left);
        idx += bottom_left.len;

        for (0..self.width * 2) |_| {
            const h_line = "─";
            @memcpy(buffer[idx .. idx + h_line.len], h_line);
            idx += h_line.len;
        }

        const bottom_right = "┘\n";
        @memcpy(buffer[idx .. idx + bottom_right.len], bottom_right);
        idx += bottom_right.len;

        // Write entire buffer at once
        try stdout.writeAll(buffer[0..idx]);
    }

    fn drawLine(self: *Canvas, x0: isize, y0: isize, x1: isize, y1: isize, color: Color) void {
        var x = x0;
        var y = y0;
        const dx = @abs(x1 - x0);
        const dy = @abs(y1 - y0);
        const sx: isize = if (x0 < x1) 1 else -1;
        const sy: isize = if (y0 < y1) 1 else -1;
        var err = dx - dy;

        while (true) {
            if (x >= 0 and y >= 0) {
                self.setPixel(@intCast(x), @intCast(y), color);
            }
            if (x == x1 and y == y1) break;
            const e2 = 2 * err;
            if (e2 > -@as(isize, @intCast(dy))) {
                err -= dy;
                x += sx;
            }
            if (e2 < dx) {
                err += dx;
                y += sy;
            }
        }
    }

    fn drawRectangle(self: *Canvas, x: usize, y: usize, w: usize, h: usize, color: Color, filled: bool) void {
        if (filled) {
            var dy: usize = 0;
            while (dy < h) : (dy += 1) {
                var dx: usize = 0;
                while (dx < w) : (dx += 1) {
                    self.setPixel(x + dx, y + dy, color);
                }
            }
        } else {
            // Top and bottom edges
            var dx: usize = 0;
            while (dx < w) : (dx += 1) {
                self.setPixel(x + dx, y, color);
                if (h > 1) self.setPixel(x + dx, y + h - 1, color);
            }
            // Left and right edges
            var dy: usize = 1;
            while (dy < h - 1) : (dy += 1) {
                self.setPixel(x, y + dy, color);
                if (w > 1) self.setPixel(x + w - 1, y + dy, color);
            }
        }
    }

    fn floodFill(self: *Canvas, x: usize, y: usize, new_color: Color, allocator: std.mem.Allocator) !void {
        _ = allocator;
        if (x >= self.width or y >= self.height) return;

        const old_color = self.pixels[y][x];
        if (old_color == new_color) return;

        const Point = struct { x: usize, y: usize };
        var queue_buffer: [10000]Point = undefined;
        var queue_start: usize = 0;
        var queue_end: usize = 0;

        // Add first point
        queue_buffer[queue_end] = .{ .x = x, .y = y };
        queue_end += 1;

        while (queue_start < queue_end) {
            const point = queue_buffer[queue_start];
            queue_start += 1;

            if (point.x >= self.width or point.y >= self.height) continue;
            if (self.pixels[point.y][point.x] != old_color) continue;

            self.pixels[point.y][point.x] = new_color;

            // Add adjacent points (if we have room in queue)
            if (queue_end < queue_buffer.len - 4) {
                if (point.x > 0) {
                    queue_buffer[queue_end] = .{ .x = point.x - 1, .y = point.y };
                    queue_end += 1;
                }
                if (point.x < self.width - 1) {
                    queue_buffer[queue_end] = .{ .x = point.x + 1, .y = point.y };
                    queue_end += 1;
                }
                if (point.y > 0) {
                    queue_buffer[queue_end] = .{ .x = point.x, .y = point.y - 1 };
                    queue_end += 1;
                }
                if (point.y < self.height - 1) {
                    queue_buffer[queue_end] = .{ .x = point.x, .y = point.y + 1 };
                    queue_end += 1;
                }
            }
        }
    }

    fn save(self: Canvas, filename: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        var buf: [1024]u8 = undefined;
        const header = try std.fmt.bufPrint(&buf, "{d} {d}\n", .{ self.width, self.height });
        try file.writeAll(header);

        for (self.pixels) |row| {
            for (row) |pixel| {
                try file.writeAll(&[_]u8{@intFromEnum(pixel) + '0'});
            }
            try file.writeAll("\n");
        }
    }

    fn saveCArray(self: Canvas, filename: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        // Write array header
        try file.writeAll("const unsigned char bitmap[] PROGMEM = {\n");

        // Write bitmap data
        var written_bytes: usize = 0;
        var first_byte = true;

        for (self.pixels) |row| {
            var x: usize = 0;
            while (x < self.width) {
                var byte: u8 = 0;
                var bit_count: usize = 0;

                // Pack up to 8 pixels into one byte
                while (bit_count < 8 and x < self.width) : ({
                    x += 1;
                    bit_count += 1;
                }) {
                    if (row[x] == .black) {
                        byte |= @as(u8, 1) << @intCast(7 - bit_count);
                    }
                }

                // Write the byte
                if (!first_byte) {
                    try file.writeAll(", ");
                    if (written_bytes % 12 == 0) {
                        try file.writeAll("\n    ");
                    }
                } else {
                    try file.writeAll("    ");
                    first_byte = false;
                }

                var buf: [16]u8 = undefined;
                const byte_str = try std.fmt.bufPrint(&buf, "0x{x:0>2}", .{byte});
                try file.writeAll(byte_str);

                written_bytes += 1;
            }
        }

        try file.writeAll("\n};\n");
    }

    fn load(allocator: std.mem.Allocator, filename: []const u8) !Canvas {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const contents = try allocator.alloc(u8, file_size);
        defer allocator.free(contents);

        _ = try file.read(contents);

        // Parse dimensions
        var it = std.mem.tokenizeSequence(u8, contents, "\n");
        const header = it.next() orelse return error.InvalidFormat;
        var dim_it = std.mem.tokenizeSequence(u8, header, " ");
        const width = try std.fmt.parseInt(usize, dim_it.next() orelse return error.InvalidFormat, 10);
        const height = try std.fmt.parseInt(usize, dim_it.next() orelse return error.InvalidFormat, 10);

        var canvas = try Canvas.init(allocator, width, height);
        errdefer canvas.deinit();

        // Read pixel data
        var y: usize = 0;
        while (it.next()) |line| {
            if (y >= height) break;
            for (line, 0..) |char, x| {
                if (x < width and char >= '0' and char <= '1') {
                    canvas.pixels[y][x] = @enumFromInt(char - '0');
                }
            }
            y += 1;
        }

        return canvas;
    }
};

const Mode = enum {
    pen,
    line,
    rectangle,
    fill,
    animation,
    quit,
};

const MAX_FRAMES = 16;

const AnimationState = struct {
    frames: []Canvas,
    frame_count: usize = 1,
    current_frame: usize = 0,
    playing: bool = false,
    frame_delay_ms: u32 = 100,

    fn init(allocator: std.mem.Allocator) !AnimationState {
        const frames = try allocator.alloc(Canvas, MAX_FRAMES);
        return AnimationState{
            .frames = frames,
        };
    }

    fn deinit(self: *AnimationState, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
    }

    fn saveCArray(self: AnimationState, filename: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        // Write array header with frame count comment
        var header_buf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "// Animation with {d} frames, {d}x{d} pixels each\n", .{ self.frame_count, self.frames[0].width, self.frames[0].height });
        try file.writeAll(header);
        try file.writeAll("const unsigned char animation[] PROGMEM = {\n");

        var written_bytes: usize = 0;
        var first_byte = true;

        // Process each frame
        for (0..self.frame_count) |frame_idx| {
            const frame = &self.frames[frame_idx];

            // Add frame comment
            if (frame_idx > 0) {
                try file.writeAll("\n    // Frame ");
                var frame_buf: [32]u8 = undefined;
                const frame_str = try std.fmt.bufPrint(&frame_buf, "{d}\n", .{frame_idx + 1});
                try file.writeAll(frame_str);
            }

            // Write frame data
            for (frame.pixels) |row| {
                var x: usize = 0;
                while (x < frame.width) {
                    var byte: u8 = 0;
                    var bit_count: usize = 0;

                    // Pack up to 8 pixels into one byte
                    while (bit_count < 8 and x < frame.width) : ({
                        x += 1;
                        bit_count += 1;
                    }) {
                        if (row[x] == .black) {
                            byte |= @as(u8, 1) << @intCast(7 - bit_count);
                        }
                    }

                    // Write the byte
                    if (!first_byte) {
                        try file.writeAll(", ");
                        if (written_bytes % 12 == 0) {
                            try file.writeAll("\n    ");
                        }
                    } else {
                        try file.writeAll("    ");
                        first_byte = false;
                    }

                    var buf: [16]u8 = undefined;
                    const byte_str = try std.fmt.bufPrint(&buf, "0x{x:0>2}", .{byte});
                    try file.writeAll(byte_str);

                    written_bytes += 1;
                }
            }
        }

        try file.writeAll("\n};\n");

        // Write frame size constants
        const bytes_per_row = (self.frames[0].width + 7) / 8;
        const bytes_per_frame = bytes_per_row * self.frames[0].height;

        var const_buf: [512]u8 = undefined;
        const constants = try std.fmt.bufPrint(&const_buf,
            \\
            \\const unsigned int FRAME_WIDTH = {d};
            \\const unsigned int FRAME_HEIGHT = {d};
            \\const unsigned int FRAME_COUNT = {d};
            \\const unsigned int BYTES_PER_FRAME = {d};
            \\
        , .{ self.frames[0].width, self.frames[0].height, self.frame_count, bytes_per_frame });
        try file.writeAll(constants);
    }
};

const AppState = struct {
    canvas: Canvas,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    mode: Mode = .pen,
    color: Color = .black,
    line_start_x: ?usize = null,
    line_start_y: ?usize = null,
    rect_start_x: ?usize = null,
    rect_start_y: ?usize = null,
    original_termios: std.posix.termios,
    animation: AnimationState,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var width: usize = 32;
    var height: usize = 16;

    // Parse command line arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-w") or std.mem.eql(u8, args[i], "--width")) {
            i += 1;
            if (i < args.len) {
                width = try std.fmt.parseInt(usize, args[i], 10);
            }
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--height")) {
            i += 1;
            if (i < args.len) {
                height = try std.fmt.parseInt(usize, args[i], 10);
            }
        } else if (std.mem.eql(u8, args[i], "--help")) {
            std.debug.print(
                \\Usage: bitmap_paint [options]
                \\Options:
                \\  -w, --width <n>    Set canvas width (max: 128)
                \\  -h, --height <n>   Set canvas height (max: 64)
                \\  --help             Show this help message
                \\
            , .{});
            return;
        }
    }

    var canvas = try Canvas.init(allocator, width, height);
    defer canvas.deinit();

    // Initialize animation state
    var animation = try AnimationState.init(allocator);
    defer animation.deinit(allocator);

    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };

    // Check if we're running in a terminal
    if (!std.posix.isatty(stdin.handle)) {
        std.debug.print("This program must be run in an interactive terminal.\n", .{});
        return;
    }

    // Set terminal to raw mode
    const termios = try std.posix.tcgetattr(stdin.handle);

    // Initialize first frame with copy of canvas
    animation.frames[0] = try canvas.copy(allocator);

    var state = AppState{
        .canvas = canvas,
        .original_termios = termios,
        .animation = animation,
    };

    defer {
        for (0..state.animation.frame_count) |frame_idx| {
            state.animation.frames[frame_idx].deinit();
        }
    }

    var raw = termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    try std.posix.tcsetattr(stdin.handle, .NOW, raw);
    defer std.posix.tcsetattr(stdin.handle, .NOW, termios) catch {};

    try stdout_file.writeAll("\x1B[?25l"); // Hide cursor
    defer stdout_file.writeAll("\x1B[?25h") catch {}; // Show cursor on exit

    // Main loop
    var last_frame_time = std.time.milliTimestamp();

    while (state.mode != .quit) {
        try renderUI(&state, stdout_file, allocator);

        // Handle animation playback
        if (state.mode == .animation and state.animation.playing and state.animation.frame_count > 1) {
            const current_time = std.time.milliTimestamp();
            if (current_time - last_frame_time >= state.animation.frame_delay_ms) {
                // Save current canvas to current frame
                state.animation.frames[state.animation.current_frame].deinit();
                state.animation.frames[state.animation.current_frame] = try state.canvas.copy(allocator);

                // Advance to next frame
                state.animation.current_frame = (state.animation.current_frame + 1) % state.animation.frame_count;

                // Load next frame
                state.canvas.deinit();
                state.canvas = try state.animation.frames[state.animation.current_frame].copy(allocator);

                last_frame_time = current_time;
                continue; // Skip input handling during playback
            }
        }

        // Check for input with timeout during animation
        if (state.mode == .animation and state.animation.playing) {
            var pollfd = [_]std.posix.pollfd{
                .{ .fd = stdin.handle, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const poll_result = try std.posix.poll(&pollfd, 10); // 10ms timeout

            if (poll_result == 0) continue; // No input available
        }

        var buf: [1]u8 = undefined;
        _ = try stdin.read(&buf);

        try handleInput(&state, buf[0], allocator, stdin, stdout_file);
    }
}

fn renderUI(state: *AppState, stdout: std.fs.File, allocator: std.mem.Allocator) !void {
    // Use optimized rendering during animation playback
    if (state.mode == .animation and state.animation.playing) {
        try state.canvas.renderOptimized(stdout, allocator);
    } else {
        try state.canvas.render(stdout);
    }

    // Fixed status display area at bottom
    const status_start_row = state.canvas.height + 3;

    // Move to status area and clear it
    var clear_buf: [64]u8 = undefined;
    const clear_str = try std.fmt.bufPrint(&clear_buf, "\x1B[{d};1H\x1B[J", .{status_start_row});
    try stdout.writeAll(clear_str);

    // Status line
    var status_buf: [256]u8 = undefined;
    if (state.mode == .animation) {
        const status_str = try std.fmt.bufPrint(&status_buf, "Animation Mode | Frame: {d}/{d} | Speed: {d}ms | {s}\n", .{
            state.animation.current_frame + 1,
            state.animation.frame_count,
            state.animation.frame_delay_ms,
            if (state.animation.playing) "PLAYING" else "EDITING",
        });
        try stdout.writeAll(status_str);
    } else {
        const status_str = try std.fmt.bufPrint(&status_buf, "Mode: {s} | Color: {s} | Position: ({d}, {d})\n", .{
            @tagName(state.mode),
            @tagName(state.color),
            state.cursor_x,
            state.cursor_y,
        });
        try stdout.writeAll(status_str);
    }

    // Help text
    if (state.mode == .animation) {
        try stdout.writeAll("Animation: [/]=prev/next frame, n=new frame, d=delete frame, p=play/pause, -/+=speed\n");
    } else {
        try stdout.writeAll("Controls: hjkl/arrows=move, space=draw, m=mode, x=color, s=save, S=save C array, L=load, C=clear, q=quit\n");
    }

    if (state.mode == .line and state.line_start_x != null) {
        var line_buf: [128]u8 = undefined;
        const line_str = try std.fmt.bufPrint(&line_buf, "Line from ({d}, {d}) - press space to complete\n", .{
            state.line_start_x.?,
            state.line_start_y.?,
        });
        try stdout.writeAll(line_str);
    } else if (state.mode == .rectangle and state.rect_start_x != null) {
        var rect_buf: [128]u8 = undefined;
        const rect_str = try std.fmt.bufPrint(&rect_buf, "Rectangle from ({d}, {d}) - press space to complete, f for filled\n", .{
            state.rect_start_x.?,
            state.rect_start_y.?,
        });
        try stdout.writeAll(rect_str);
    } else {
        try stdout.writeAll("\n"); // Empty line to keep layout consistent
    }

    // Show cursor position with overlay character
    const cursor_chars = if (state.canvas.getPixel(state.cursor_x, state.cursor_y)) |pixel|
        switch (pixel) {
            .black => "▓▓",
            .white => "▒▒",
        }
    else
        "??";

    var cursor_buf: [64]u8 = undefined;
    const cursor_str = try std.fmt.bufPrint(&cursor_buf, "\x1B[{d};{d}H{s}", .{ state.cursor_y + 2, state.cursor_x * 2 + 2, cursor_chars });
    try stdout.writeAll(cursor_str);
}

fn readLine(stdin: std.fs.File, buf: []u8) !?[]u8 {
    var i: usize = 0;
    while (i < buf.len - 1) {
        var char_buf: [1]u8 = undefined;
        const n = try stdin.read(&char_buf);
        if (n == 0) break;

        if (char_buf[0] == '\n') {
            return buf[0..i];
        }

        buf[i] = char_buf[0];
        i += 1;
    }

    if (i > 0) return buf[0..i];
    return null;
}

fn handleInput(state: *AppState, key: u8, allocator: std.mem.Allocator, stdin: std.fs.File, stdout_file: std.fs.File) !void {
    // Handle escape sequences for arrow keys
    if (key == 0x1B) { // ESC
        var seq: [3]u8 = undefined;
        const n = stdin.read(seq[0..2]) catch 0;
        if (n == 2 and seq[0] == '[') {
            switch (seq[1]) {
                'A' => {
                    if (state.cursor_y > 0) state.cursor_y -= 1;
                }, // Up
                'B' => {
                    if (state.cursor_y < state.canvas.height - 1) state.cursor_y += 1;
                }, // Down
                'C' => {
                    if (state.cursor_x < state.canvas.width - 1) state.cursor_x += 1;
                }, // Right
                'D' => {
                    if (state.cursor_x > 0) state.cursor_x -= 1;
                }, // Left
                else => {},
            }
            return;
        }
    }

    switch (key) {
        // Movement (vi keys)
        'h' => {
            if (state.cursor_x > 0) state.cursor_x -= 1;
        },
        'j' => {
            if (state.cursor_y < state.canvas.height - 1) state.cursor_y += 1;
        },
        'k' => {
            if (state.cursor_y > 0) state.cursor_y -= 1;
        },
        'l' => {
            if (state.cursor_x < state.canvas.width - 1) state.cursor_x += 1;
        },

        // Drawing
        ' ' => {
            switch (state.mode) {
                .pen => state.canvas.setPixel(state.cursor_x, state.cursor_y, state.color),
                .line => {
                    if (state.line_start_x == null) {
                        state.line_start_x = state.cursor_x;
                        state.line_start_y = state.cursor_y;
                    } else {
                        state.canvas.drawLine(
                            @intCast(state.line_start_x.?),
                            @intCast(state.line_start_y.?),
                            @intCast(state.cursor_x),
                            @intCast(state.cursor_y),
                            state.color,
                        );
                        state.line_start_x = null;
                        state.line_start_y = null;
                    }
                },
                .rectangle => {
                    if (state.rect_start_x == null) {
                        state.rect_start_x = state.cursor_x;
                        state.rect_start_y = state.cursor_y;
                    } else {
                        const x = @min(state.rect_start_x.?, state.cursor_x);
                        const y = @min(state.rect_start_y.?, state.cursor_y);
                        const w = @abs(@as(isize, @intCast(state.cursor_x)) - @as(isize, @intCast(state.rect_start_x.?))) + 1;
                        const h = @abs(@as(isize, @intCast(state.cursor_y)) - @as(isize, @intCast(state.rect_start_y.?))) + 1;
                        state.canvas.drawRectangle(x, y, @intCast(w), @intCast(h), state.color, false);
                        state.rect_start_x = null;
                        state.rect_start_y = null;
                    }
                },
                .fill => try state.canvas.floodFill(state.cursor_x, state.cursor_y, state.color, allocator),
                .animation => state.canvas.setPixel(state.cursor_x, state.cursor_y, state.color), // Allow drawing in animation mode
                .quit => {},
            }
        },

        'f' => {
            if (state.mode == .rectangle and state.rect_start_x != null) {
                const x = @min(state.rect_start_x.?, state.cursor_x);
                const y = @min(state.rect_start_y.?, state.cursor_y);
                const w = @abs(@as(isize, @intCast(state.cursor_x)) - @as(isize, @intCast(state.rect_start_x.?))) + 1;
                const h = @abs(@as(isize, @intCast(state.cursor_y)) - @as(isize, @intCast(state.rect_start_y.?))) + 1;
                state.canvas.drawRectangle(x, y, @intCast(w), @intCast(h), state.color, true);
                state.rect_start_x = null;
                state.rect_start_y = null;
            }
        },

        // Mode switching
        'm' => {
            state.mode = switch (state.mode) {
                .pen => .line,
                .line => .rectangle,
                .rectangle => .fill,
                .fill => .animation,
                .animation => .pen,
                .quit => .pen,
            };
            // Reset any in-progress operations
            state.line_start_x = null;
            state.line_start_y = null;
            state.rect_start_x = null;
            state.rect_start_y = null;
        },

        // Color switching
        'x' => {
            state.color = switch (state.color) {
                .black => .white,
                .white => .black,
            };
        },

        // Clear canvas
        'C' => state.canvas.clear(),

        // Save/Load
        's' => {
            try stdout_file.writeAll("\nEnter filename: ");

            // Temporarily restore terminal for input
            const raw = try std.posix.tcgetattr(stdin.handle);
            try std.posix.tcsetattr(stdin.handle, .NOW, state.original_termios);
            defer std.posix.tcsetattr(stdin.handle, .NOW, raw) catch {};

            var buf: [256]u8 = undefined;
            if (try readLine(stdin, &buf)) |filename| {
                state.canvas.save(filename) catch |err| {
                    var err_buf: [256]u8 = undefined;
                    const err_str = try std.fmt.bufPrint(&err_buf, "Error saving: {any}\n", .{err});
                    try stdout_file.writeAll(err_str);
                };
            }
        },

        'S' => {
            if (state.mode == .animation) {
                // Save current frame first
                state.animation.frames[state.animation.current_frame].deinit();
                state.animation.frames[state.animation.current_frame] = try state.canvas.copy(allocator);

                try stdout_file.writeAll("\nEnter C array filename for animation: ");
            } else {
                try stdout_file.writeAll("\nEnter C array filename: ");
            }

            // Temporarily restore terminal for input
            const raw = try std.posix.tcgetattr(stdin.handle);
            try std.posix.tcsetattr(stdin.handle, .NOW, state.original_termios);
            defer std.posix.tcsetattr(stdin.handle, .NOW, raw) catch {};

            var buf: [256]u8 = undefined;
            if (try readLine(stdin, &buf)) |filename| {
                if (state.mode == .animation) {
                    state.animation.saveCArray(filename) catch |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_str = try std.fmt.bufPrint(&err_buf, "Error saving animation C array: {any}\n", .{err});
                        try stdout_file.writeAll(err_str);
                    };
                } else {
                    state.canvas.saveCArray(filename) catch |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_str = try std.fmt.bufPrint(&err_buf, "Error saving C array: {any}\n", .{err});
                        try stdout_file.writeAll(err_str);
                    };
                }
            }
        },

        'L' => {
            try stdout_file.writeAll("\nEnter filename: ");

            // Temporarily restore terminal for input
            const raw = try std.posix.tcgetattr(stdin.handle);
            try std.posix.tcsetattr(stdin.handle, .NOW, state.original_termios);
            defer std.posix.tcsetattr(stdin.handle, .NOW, raw) catch {};

            var buf: [256]u8 = undefined;
            if (try readLine(stdin, &buf)) |filename| {
                const loaded = Canvas.load(allocator, filename) catch |err| {
                    var err_buf: [256]u8 = undefined;
                    const err_str = try std.fmt.bufPrint(&err_buf, "Error loading: {any}\n", .{err});
                    try stdout_file.writeAll(err_str);
                    return;
                };
                state.canvas.deinit();
                state.canvas = loaded;
                state.cursor_x = 0;
                state.cursor_y = 0;
            }
        },

        // Quit
        'q' => state.mode = .quit,

        // Animation controls
        '[' => {
            if (state.mode == .animation and state.animation.current_frame > 0) {
                // Save current canvas to current frame
                state.animation.frames[state.animation.current_frame].deinit();
                state.animation.frames[state.animation.current_frame] = try state.canvas.copy(allocator);

                // Switch to previous frame
                state.animation.current_frame -= 1;
                state.canvas.deinit();
                state.canvas = try state.animation.frames[state.animation.current_frame].copy(allocator);
            }
        },

        ']' => {
            if (state.mode == .animation and state.animation.current_frame < state.animation.frame_count - 1) {
                // Save current canvas to current frame
                state.animation.frames[state.animation.current_frame].deinit();
                state.animation.frames[state.animation.current_frame] = try state.canvas.copy(allocator);

                // Switch to next frame
                state.animation.current_frame += 1;
                state.canvas.deinit();
                state.canvas = try state.animation.frames[state.animation.current_frame].copy(allocator);
            }
        },

        'n' => {
            if (state.mode == .animation and state.animation.frame_count < MAX_FRAMES) {
                // Save current canvas to current frame
                state.animation.frames[state.animation.current_frame].deinit();
                state.animation.frames[state.animation.current_frame] = try state.canvas.copy(allocator);

                // Create new frame
                state.animation.frame_count += 1;
                state.animation.current_frame = state.animation.frame_count - 1;
                state.animation.frames[state.animation.current_frame] = try Canvas.init(allocator, state.canvas.width, state.canvas.height);

                // Switch to new frame
                state.canvas.deinit();
                state.canvas = try state.animation.frames[state.animation.current_frame].copy(allocator);
            }
        },

        'c' => {
            if (state.mode == .animation and state.animation.frame_count < MAX_FRAMES) {
                // Save current canvas to current frame
                state.animation.frames[state.animation.current_frame].deinit();
                state.animation.frames[state.animation.current_frame] = try state.canvas.copy(allocator);

                // Create new frame
                state.animation.frame_count += 1;
                state.animation.current_frame = state.animation.frame_count - 1;
                state.animation.frames[state.animation.current_frame] = try Canvas.init(allocator, state.canvas.width, state.canvas.height);
            }
        },

        'p' => {
            if (state.mode == .animation) {
                state.animation.playing = !state.animation.playing;
            }
        },

        '-' => {
            if (state.mode == .animation and state.animation.frame_delay_ms < 1000) {
                state.animation.frame_delay_ms += 50;
            }
        },

        '+', '=' => {
            if (state.mode == .animation and state.animation.frame_delay_ms > 50) {
                state.animation.frame_delay_ms -= 50;
            }
        },

        else => {},
    }
}

