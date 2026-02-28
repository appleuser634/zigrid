const std = @import("std");

const MAX_WIDTH = 128;
const MAX_HEIGHT = 64;

const Color = enum(u8) {
    black = 0,
    white = 1,
};

const RenderMode = enum {
    block,
    sixel,
};

const PNG_SIGNATURE = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

const PngColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    rgba = 6,
};

fn bytesPerRow(width: usize) usize {
    return (width + 7) / 8;
}

fn bytesPerFrame(width: usize, height: usize) usize {
    return bytesPerRow(width) * height;
}

fn isIdentifierChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

fn sanitizeIdentifier(input: []const u8, buffer: []u8) []const u8 {
    var idx: usize = 0;

    if (input.len == 0) {
        buffer[0] = 'a';
        buffer[1] = 's';
        buffer[2] = 's';
        buffer[3] = 'e';
        buffer[4] = 't';
        return buffer[0..5];
    }

    for (input) |char| {
        if (idx >= buffer.len) break;
        const normalized = if (isIdentifierChar(char)) char else '_';
        if (idx == 0 and std.ascii.isDigit(normalized)) {
            if (idx < buffer.len) {
                buffer[idx] = '_';
                idx += 1;
            }
            if (idx >= buffer.len) break;
        }
        buffer[idx] = normalized;
        idx += 1;
    }

    if (idx == 0) {
        buffer[0] = 'a';
        buffer[1] = 's';
        buffer[2] = 's';
        buffer[3] = 'e';
        buffer[4] = 't';
        return buffer[0..5];
    }

    return buffer[0..idx];
}

fn assetNameFromPath(path: []const u8, buffer: []u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    const stem = if (ext.len > 0) base[0 .. base.len - ext.len] else base;
    return sanitizeIdentifier(stem, buffer);
}

fn hasPngSignature(bytes: []const u8) bool {
    return bytes.len >= PNG_SIGNATURE.len and std.mem.eql(u8, bytes[0..PNG_SIGNATURE.len], &PNG_SIGNATURE);
}

fn readFileAlloc(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn readBigEndianU32(bytes: []const u8, offset: usize) !u32 {
    if (offset + 4 > bytes.len) return error.UnexpectedEndOfFile;
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        @as(u32, bytes[offset + 3]);
}

fn writeBigEndianU32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

fn writeLittleEndianU16(bytes: []u8, value: u16) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
}

fn pngBytesPerPixel(color_type: PngColorType) usize {
    return switch (color_type) {
        .grayscale => 1,
        .rgb => 3,
        .rgba => 4,
    };
}

fn scaledCanvasDimensions(width: usize, height: usize) struct { width: usize, height: usize } {
    if (width <= MAX_WIDTH and height <= MAX_HEIGHT) {
        return .{ .width = width, .height = height };
    }

    const width_product = @as(u64, width) * MAX_HEIGHT;
    const height_product = @as(u64, MAX_WIDTH) * height;

    if (width_product > height_product) {
        return .{
            .width = MAX_WIDTH,
            .height = @max(@as(usize, 1), (height * MAX_WIDTH) / width),
        };
    }

    return .{
        .width = @max(@as(usize, 1), (width * MAX_HEIGHT) / height),
        .height = MAX_HEIGHT,
    };
}

fn paethPredictor(left: u8, up: u8, up_left: u8) u8 {
    const p = @as(i32, left) + @as(i32, up) - @as(i32, up_left);
    const pa = @abs(p - @as(i32, left));
    const pb = @abs(p - @as(i32, up));
    const pc = @abs(p - @as(i32, up_left));

    if (pa <= pb and pa <= pc) return left;
    if (pb <= pc) return up;
    return up_left;
}

fn unfilterPngScanlines(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    bytes_per_pixel: usize,
    filtered_scanlines: []const u8,
) ![]u8 {
    const row_bytes = try std.math.mul(usize, width, bytes_per_pixel);
    const expected_len = try std.math.mul(usize, height, row_bytes + 1);
    if (filtered_scanlines.len != expected_len) return error.InvalidPngData;

    const pixel_len = try std.math.mul(usize, height, row_bytes);
    const pixels = try allocator.alloc(u8, pixel_len);
    errdefer allocator.free(pixels);

    var src_offset: usize = 0;
    var dst_offset: usize = 0;
    var previous_row: []const u8 = &.{};

    for (0..height) |_| {
        const filter_type = filtered_scanlines[src_offset];
        src_offset += 1;

        const current_row = pixels[dst_offset .. dst_offset + row_bytes];
        const filtered_row = filtered_scanlines[src_offset .. src_offset + row_bytes];

        for (filtered_row, 0..) |value, x| {
            const left = if (x >= bytes_per_pixel) current_row[x - bytes_per_pixel] else 0;
            const up = if (previous_row.len == row_bytes) previous_row[x] else 0;
            const up_left = if (previous_row.len == row_bytes and x >= bytes_per_pixel) previous_row[x - bytes_per_pixel] else 0;

            current_row[x] = switch (filter_type) {
                0 => value,
                1 => value +% left,
                2 => value +% up,
                3 => value +% @as(u8, @intCast((@as(u16, left) + @as(u16, up)) / 2)),
                4 => value +% paethPredictor(left, up, up_left),
                else => return error.InvalidPngFilter,
            };
        }

        previous_row = current_row;
        src_offset += row_bytes;
        dst_offset += row_bytes;
    }

    return pixels;
}

fn pngPixelToColor(
    pixels: []const u8,
    width: usize,
    color_type: PngColorType,
    x: usize,
    y: usize,
) Color {
    const bytes_per_pixel = pngBytesPerPixel(color_type);
    const offset = (y * width + x) * bytes_per_pixel;

    switch (color_type) {
        .grayscale => {
            return if (pixels[offset] < 128) .black else .white;
        },
        .rgb => {
            const r = @as(u32, pixels[offset]);
            const g = @as(u32, pixels[offset + 1]);
            const b = @as(u32, pixels[offset + 2]);
            const luma = (@as(u32, 299) * r + @as(u32, 587) * g + @as(u32, 114) * b) / 1000;
            return if (luma < 128) .black else .white;
        },
        .rgba => {
            const alpha = pixels[offset + 3];
            if (alpha == 0) return .white;

            const r = @as(u32, pixels[offset]);
            const g = @as(u32, pixels[offset + 1]);
            const b = @as(u32, pixels[offset + 2]);
            const luma = (@as(u32, 299) * r + @as(u32, 587) * g + @as(u32, 114) * b) / 1000;
            return if (luma < 128) .black else .white;
        },
    }
}

fn canvasFromPngRaster(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: usize,
    height: usize,
    color_type: PngColorType,
) !Canvas {
    const dimensions = scaledCanvasDimensions(width, height);
    var canvas = try Canvas.init(allocator, dimensions.width, dimensions.height);
    errdefer canvas.deinit();

    for (0..dimensions.height) |y| {
        const source_y = (y * height) / dimensions.height;
        for (0..dimensions.width) |x| {
            const source_x = (x * width) / dimensions.width;
            canvas.pixels[y][x] = pngPixelToColor(pixels, width, color_type, source_x, source_y);
        }
    }

    return canvas;
}

fn writePackedByte(writer: anytype, byte: u8, written_bytes: *usize, first_byte: *bool) !void {
    if (!first_byte.*) {
        try writer.writeAll(", ");
        if (written_bytes.* % 12 == 0) {
            try writer.writeAll("\n    ");
        }
    } else {
        try writer.writeAll("    ");
        first_byte.* = false;
    }

    var buf: [16]u8 = undefined;
    const byte_str = try std.fmt.bufPrint(&buf, "0x{x:0>2}", .{byte});
    try writer.writeAll(byte_str);
    written_bytes.* += 1;
}

fn writePackedCanvasBytes(writer: anytype, canvas: Canvas) !void {
    var written_bytes: usize = 0;
    var first_byte = true;

    for (canvas.pixels) |row| {
        var x: usize = 0;
        while (x < canvas.width) {
            var byte: u8 = 0;
            var bit_count: usize = 0;

            while (bit_count < 8 and x < canvas.width) : ({
                x += 1;
                bit_count += 1;
            }) {
                if (row[x] == .black) {
                    byte |= @as(u8, 1) << @intCast(7 - bit_count);
                }
            }

            try writePackedByte(writer, byte, &written_bytes, &first_byte);
        }
    }

    try writer.writeAll("\n");
}

fn writeZigAssetMetadata(writer: anytype, asset_name: []const u8, width: usize, height: usize, frame_count: usize) !void {
    try writer.print("pub const {s}_width: u8 = {};\n", .{ asset_name, width });
    try writer.print("pub const {s}_height: u8 = {};\n", .{ asset_name, height });
    try writer.print("pub const {s}_bytes_per_row: usize = {};\n", .{ asset_name, bytesPerRow(width) });
    try writer.print("pub const {s}_bytes_per_frame: usize = {};\n", .{ asset_name, bytesPerFrame(width, height) });
    if (frame_count > 1) {
        try writer.print("pub const {s}_frame_count: u8 = {};\n", .{ asset_name, frame_count });
    }
}

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

    fn appendBytes(buffer: []u8, idx: *usize, data: []const u8) void {
        @memcpy(buffer[idx.* .. idx.* + data.len], data);
        idx.* += data.len;
    }

    fn renderSixel(self: Canvas, stdout: std.fs.File, cursor_x: usize, cursor_y: usize) !void {
        try stdout.writeAll("\x1B[2J\x1B[H"); // Clear screen and move cursor to top

        var buffer: [60000]u8 = undefined;
        var idx: usize = 0;

        const header = "\x1BPq";
        appendBytes(buffer[0..], &idx, header);
        appendBytes(buffer[0..], &idx, "#0;2;100;100;100"); // white
        appendBytes(buffer[0..], &idx, "#1;2;0;0;0"); // black
        appendBytes(buffer[0..], &idx, "#2;2;100;0;0"); // cursor (red)

        var y: usize = 0;
        while (y < self.height) : (y += 6) {
            const band_height = @min(@as(usize, 6), self.height - y);
            const white_bits: u8 = @intCast((@as(u8, 1) << @intCast(band_height)) - 1);

            appendBytes(buffer[0..], &idx, "#0");
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                buffer[idx] = @intCast(0x3F + white_bits);
                idx += 1;
            }

            appendBytes(buffer[0..], &idx, "$");
            appendBytes(buffer[0..], &idx, "#1");

            x = 0;
            while (x < self.width) : (x += 1) {
                var bits: u8 = 0;
                var bit_idx: usize = 0;
                while (bit_idx < band_height) : (bit_idx += 1) {
                    if (self.pixels[y + bit_idx][x] == .black) {
                        bits |= @as(u8, 1) << @intCast(bit_idx);
                    }
                }
                buffer[idx] = @intCast(0x3F + bits);
                idx += 1;
            }

            if (cursor_y >= y and cursor_y < y + band_height) {
                appendBytes(buffer[0..], &idx, "$");
                appendBytes(buffer[0..], &idx, "#2");

                x = 0;
                while (x < self.width) : (x += 1) {
                    const bits: u8 = if (x == cursor_x)
                        @as(u8, 1) << @intCast(cursor_y - y)
                    else
                        0;
                    buffer[idx] = @intCast(0x3F + bits);
                    idx += 1;
                }
            }

            if (y + 6 < self.height) {
                appendBytes(buffer[0..], &idx, "-");
            }
        }

        appendBytes(buffer[0..], &idx, "\x1B\\");
        try stdout.writeAll(buffer[0..idx]);
    }

    fn renderBlock(self: Canvas, stdout: std.fs.File, cursor_x: usize, cursor_y: usize) !void {
        try stdout.writeAll("\x1B[2J\x1B[H"); // Clear screen and move cursor to top

        var line_buffer: [1024]u8 = undefined;
        var idx: usize = 0;
        appendBytes(line_buffer[0..], &idx, "┌");
        for (0..self.width) |_| {
            appendBytes(line_buffer[0..], &idx, "──");
        }
        appendBytes(line_buffer[0..], &idx, "┐\n");
        try stdout.writeAll(line_buffer[0..idx]);

        for (self.pixels, 0..) |row, y| {
            idx = 0;
            appendBytes(line_buffer[0..], &idx, "│");
            for (row, 0..) |pixel, x| {
                const cell = if (x == cursor_x and y == cursor_y)
                    switch (pixel) {
                        .black => "▓▓",
                        .white => "▒▒",
                    }
                else switch (pixel) {
                    .black => "██",
                    .white => "  ",
                };
                appendBytes(line_buffer[0..], &idx, cell);
            }
            appendBytes(line_buffer[0..], &idx, "│\n");
            try stdout.writeAll(line_buffer[0..idx]);
        }

        idx = 0;
        appendBytes(line_buffer[0..], &idx, "└");
        for (0..self.width) |_| {
            appendBytes(line_buffer[0..], &idx, "──");
        }
        appendBytes(line_buffer[0..], &idx, "┘\n");
        try stdout.writeAll(line_buffer[0..idx]);
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
        var write_buffer: [4096]u8 = undefined;
        var writer: std.fs.File.Writer = .init(file, &write_buffer);

        // Write array header
        try writer.interface.writeAll("const unsigned char bitmap[] PROGMEM = {\n");
        try writePackedCanvasBytes(&writer.interface, self);
        try writer.interface.writeAll("};\n");
        try writer.interface.flush();
    }

    fn saveZigAsset(self: Canvas, filename: []const u8, asset_name: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        var write_buffer: [4096]u8 = undefined;
        var writer: std.fs.File.Writer = .init(file, &write_buffer);

        try writer.interface.print("// zigrid asset: {s}\n", .{asset_name});
        try writeZigAssetMetadata(&writer.interface, asset_name, self.width, self.height, 1);
        try writer.interface.print("pub const {s} = [_]u8{{\n", .{asset_name});
        try writePackedCanvasBytes(&writer.interface, self);
        try writer.interface.writeAll("};\n");
        try writer.interface.flush();
    }
    fn loadTextBytes(allocator: std.mem.Allocator, contents: []const u8) !Canvas {
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

    fn loadPngBytes(allocator: std.mem.Allocator, contents: []const u8) !Canvas {
        if (!hasPngSignature(contents)) return error.InvalidPngSignature;

        var offset: usize = PNG_SIGNATURE.len;
        var seen_ihdr = false;
        var seen_iend = false;
        var width: usize = 0;
        var height: usize = 0;
        var color_type: PngColorType = .grayscale;
        var idat_data: std.ArrayList(u8) = .empty;
        defer idat_data.deinit(allocator);

        while (!seen_iend) {
            if (offset + 12 > contents.len) return error.InvalidPngData;

            const chunk_len_u32 = try readBigEndianU32(contents, offset);
            offset += 4;

            const chunk_type = contents[offset .. offset + 4];
            offset += 4;

            const chunk_len = std.math.cast(usize, chunk_len_u32) orelse return error.InvalidPngData;
            if (offset + chunk_len + 4 > contents.len) return error.InvalidPngData;

            const chunk_data = contents[offset .. offset + chunk_len];
            const expected_crc = try readBigEndianU32(contents, offset + chunk_len);

            var crc = std.hash.Crc32.init();
            crc.update(chunk_type);
            crc.update(chunk_data);
            if (crc.final() != expected_crc) return error.InvalidPngChunkCrc;

            if (std.mem.eql(u8, chunk_type, "IHDR")) {
                if (seen_ihdr or chunk_len != 13) return error.InvalidPngHeader;

                const parsed_width = try readBigEndianU32(chunk_data, 0);
                const parsed_height = try readBigEndianU32(chunk_data, 4);
                if (parsed_width == 0 or parsed_height == 0) return error.InvalidPngDimensions;

                width = std.math.cast(usize, parsed_width) orelse return error.InvalidPngDimensions;
                height = std.math.cast(usize, parsed_height) orelse return error.InvalidPngDimensions;

                if (chunk_data[8] != 8) return error.UnsupportedPngBitDepth;
                color_type = std.meta.intToEnum(PngColorType, chunk_data[9]) catch return error.UnsupportedPngColorType;
                if (chunk_data[10] != 0) return error.InvalidPngHeader;
                if (chunk_data[11] != 0) return error.InvalidPngHeader;
                if (chunk_data[12] != 0) return error.UnsupportedPngInterlace;

                seen_ihdr = true;
            } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
                if (!seen_ihdr) return error.InvalidPngHeader;
                try idat_data.appendSlice(allocator, chunk_data);
            } else if (std.mem.eql(u8, chunk_type, "IEND")) {
                if (!seen_ihdr or chunk_len != 0) return error.InvalidPngData;
                seen_iend = true;
            }

            offset += chunk_len + 4;
        }

        if (!seen_ihdr or idat_data.items.len == 0) return error.InvalidPngData;

        var compressed_reader: std.Io.Reader = .fixed(idat_data.items);
        var inflate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor: std.compress.flate.Decompress = .init(&compressed_reader, .zlib, &inflate_buffer);
        var filtered_scanlines: std.ArrayList(u8) = .empty;
        defer filtered_scanlines.deinit(allocator);
        try decompressor.reader.appendRemainingUnlimited(allocator, &filtered_scanlines);

        const unfiltered = try unfilterPngScanlines(
            allocator,
            width,
            height,
            pngBytesPerPixel(color_type),
            filtered_scanlines.items,
        );
        defer allocator.free(unfiltered);

        return canvasFromPngRaster(allocator, unfiltered, width, height, color_type);
    }

    fn loadAutoBytes(allocator: std.mem.Allocator, contents: []const u8) !Canvas {
        if (hasPngSignature(contents)) {
            return Canvas.loadPngBytes(allocator, contents);
        }
        return Canvas.loadTextBytes(allocator, contents);
    }

    fn load(allocator: std.mem.Allocator, filename: []const u8) !Canvas {
        const contents = try readFileAlloc(allocator, filename);
        defer allocator.free(contents);
        return Canvas.loadAutoBytes(allocator, contents);
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
const MAX_HISTORY = 32;

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
        var write_buffer: [4096]u8 = undefined;
        var writer: std.fs.File.Writer = .init(file, &write_buffer);

        // Write array header with frame count comment
        var header_buf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "// Animation with {d} frames, {d}x{d} pixels each\n", .{ self.frame_count, self.frames[0].width, self.frames[0].height });
        try writer.interface.writeAll(header);
        try writer.interface.writeAll("const unsigned char animation[] PROGMEM = {\n");

        // Process each frame
        for (0..self.frame_count) |frame_idx| {
            const frame = &self.frames[frame_idx];

            // Add frame comment
            if (frame_idx > 0) {
                try writer.interface.writeAll("\n    // Frame ");
                var frame_buf: [32]u8 = undefined;
                const frame_str = try std.fmt.bufPrint(&frame_buf, "{d}\n", .{frame_idx + 1});
                try writer.interface.writeAll(frame_str);
            }

            try writePackedCanvasBytes(&writer.interface, frame.*);
        }

        try writer.interface.writeAll("};\n");

        // Write frame size constants
        const packed_bytes_per_frame = bytesPerFrame(self.frames[0].width, self.frames[0].height);

        var const_buf: [512]u8 = undefined;
        const constants = try std.fmt.bufPrint(&const_buf,
            \\
            \\const unsigned int FRAME_WIDTH = {d};
            \\const unsigned int FRAME_HEIGHT = {d};
            \\const unsigned int FRAME_COUNT = {d};
            \\const unsigned int BYTES_PER_FRAME = {d};
            \\
        , .{ self.frames[0].width, self.frames[0].height, self.frame_count, packed_bytes_per_frame });
        try writer.interface.writeAll(constants);
        try writer.interface.flush();
    }

    fn writeFrameCArray(frame: *const Canvas, writer: anytype) !void {
        try writePackedCanvasBytes(writer, frame.*);
        try writer.writeAll("};\n\n");
    }

    fn saveFrameHeader(self: AnimationState, filename: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        var write_buffer: [4096]u8 = undefined;
        var writer: std.fs.File.Writer = .init(file, &write_buffer);

        var header_buf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "// Frames: {d}, Size: {d}x{d}\n\n", .{
            self.frame_count,
            self.frames[0].width,
            self.frames[0].height,
        });
        try writer.interface.writeAll(header);

        for (0..self.frame_count) |frame_idx| {
            const frame = &self.frames[frame_idx];
            var name_buf: [32]u8 = undefined;
            const frame_name = try std.fmt.bufPrint(&name_buf, "frame_{d:0>2}", .{frame_idx + 1});

            try writer.interface.writeAll("const unsigned char ");
            try writer.interface.writeAll(frame_name);
            try writer.interface.writeAll("[] PROGMEM = {\n");
            try writeFrameCArray(frame, &writer.interface);
        }

        try writer.interface.writeAll("const unsigned char* const animation_frames[] PROGMEM = {\n");
        for (0..self.frame_count) |frame_idx| {
            var name_buf: [32]u8 = undefined;
            const frame_name = try std.fmt.bufPrint(&name_buf, "frame_{d:0>2}", .{frame_idx + 1});
            try writer.interface.writeAll("    ");
            try writer.interface.writeAll(frame_name);
            if (frame_idx + 1 < self.frame_count) {
                try writer.interface.writeAll(",\n");
            } else {
                try writer.interface.writeAll("\n");
            }
        }
        try writer.interface.writeAll("};\n");

        const packed_bytes_per_frame = bytesPerFrame(self.frames[0].width, self.frames[0].height);

        var const_buf: [512]u8 = undefined;
        const constants = try std.fmt.bufPrint(&const_buf,
            \\
            \\const unsigned int FRAME_WIDTH = {d};
            \\const unsigned int FRAME_HEIGHT = {d};
            \\const unsigned int FRAME_COUNT = {d};
            \\const unsigned int BYTES_PER_FRAME = {d};
            \\
        , .{ self.frames[0].width, self.frames[0].height, self.frame_count, packed_bytes_per_frame });
        try writer.interface.writeAll(constants);
        try writer.interface.flush();
    }

    fn saveZigAsset(self: AnimationState, filename: []const u8, asset_name: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        var write_buffer: [4096]u8 = undefined;
        var writer: std.fs.File.Writer = .init(file, &write_buffer);

        try writer.interface.print("// zigrid animated asset: {s}\n", .{asset_name});
        try writeZigAssetMetadata(&writer.interface, asset_name, self.frames[0].width, self.frames[0].height, self.frame_count);

        for (0..self.frame_count) |frame_idx| {
            var frame_name_buf: [128]u8 = undefined;
            const frame_name = try std.fmt.bufPrint(&frame_name_buf, "{s}_{d}", .{ asset_name, frame_idx + 1 });
            try writer.interface.print("pub const {s} = [_]u8{{\n", .{frame_name});
            try writePackedCanvasBytes(&writer.interface, self.frames[frame_idx]);
            try writer.interface.writeAll("};\n");
        }

        try writer.interface.print("pub const {s}_frames = [_][]const u8{{\n", .{asset_name});
        for (0..self.frame_count) |frame_idx| {
            var frame_name_buf: [128]u8 = undefined;
            const frame_name = try std.fmt.bufPrint(&frame_name_buf, "{s}_{d}", .{ asset_name, frame_idx + 1 });
            try writer.interface.print("    {s}[0..]", .{frame_name});
            if (frame_idx + 1 < self.frame_count) {
                try writer.interface.writeAll(",\n");
            } else {
                try writer.interface.writeAll("\n");
            }
        }
        try writer.interface.writeAll("};\n");
        try writer.interface.flush();
    }
    fn saveAnimation(self: AnimationState, filename: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        var header_buf: [128]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "ANIM {d} {d} {d}\n", .{
            self.frames[0].width,
            self.frames[0].height,
            self.frame_count,
        });
        try file.writeAll(header);

        var line_buf: [MAX_WIDTH + 1]u8 = undefined;
        for (0..self.frame_count) |frame_idx| {
            var frame_header_buf: [32]u8 = undefined;
            const frame_header = try std.fmt.bufPrint(&frame_header_buf, "FRAME {d}\n", .{frame_idx + 1});
            try file.writeAll(frame_header);

            const frame = &self.frames[frame_idx];
            for (frame.pixels) |row| {
                for (row, 0..) |pixel, x| {
                    line_buf[x] = if (pixel == .black) '0' else '1';
                }
                try file.writeAll(line_buf[0..frame.width]);
                try file.writeAll("\n");
            }
        }
    }

    fn loadAnimation(self: *AnimationState, allocator: std.mem.Allocator, filename: []const u8) !void {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const contents = try allocator.alloc(u8, file_size);
        defer allocator.free(contents);
        _ = try file.read(contents);

        var it = std.mem.tokenizeSequence(u8, contents, "\n");
        const header = it.next() orelse return error.InvalidFormat;
        var header_it = std.mem.tokenizeSequence(u8, header, " ");
        const magic = header_it.next() orelse return error.InvalidFormat;
        if (!std.mem.eql(u8, magic, "ANIM")) return error.InvalidFormat;

        const width = try std.fmt.parseInt(usize, header_it.next() orelse return error.InvalidFormat, 10);
        const height = try std.fmt.parseInt(usize, header_it.next() orelse return error.InvalidFormat, 10);
        const frame_count = try std.fmt.parseInt(usize, header_it.next() orelse return error.InvalidFormat, 10);

        if (frame_count == 0 or frame_count > MAX_FRAMES) return error.InvalidFormat;
        if (width > MAX_WIDTH or height > MAX_HEIGHT) return error.CanvasTooLarge;

        self.frame_count = frame_count;
        self.current_frame = 0;
        self.playing = false;

        var frame_idx: usize = 0;
        while (frame_idx < frame_count) : (frame_idx += 1) {
            const frame_header = it.next() orelse return error.InvalidFormat;
            if (!std.mem.startsWith(u8, frame_header, "FRAME")) return error.InvalidFormat;

            var canvas = try Canvas.init(allocator, width, height);
            errdefer canvas.deinit();

            var y: usize = 0;
            while (y < height) : (y += 1) {
                const line = it.next() orelse return error.InvalidFormat;
                for (line, 0..) |char, x| {
                    if (x < width and (char == '0' or char == '1')) {
                        canvas.pixels[y][x] = @enumFromInt(char - '0');
                    }
                }
            }

            self.frames[frame_idx] = canvas;
        }
    }
};

const AppState = struct {
    canvas: Canvas,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    render_mode: RenderMode = .block,
    mode: Mode = .pen,
    color: Color = .black,
    line_start_x: ?usize = null,
    line_start_y: ?usize = null,
    rect_start_x: ?usize = null,
    rect_start_y: ?usize = null,
    original_termios: std.posix.termios,
    animation: AnimationState,
    undo_stack: []Canvas,
    undo_count: usize = 0,
    redo_stack: []Canvas,
    redo_count: usize = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var width: usize = 32;
    var height: usize = 16;
    var render_mode: RenderMode = .block;
    var stats_only = false;
    var export_zig_name: ?[]const u8 = null;
    var export_zig_anim_name: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var load_path: ?[]const u8 = null;
    var load_anim_path: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, args[i], "--load")) {
            i += 1;
            if (i < args.len) {
                load_path = args[i];
            } else {
                return error.MissingArgument;
            }
        } else if (std.mem.eql(u8, args[i], "--load-anim")) {
            i += 1;
            if (i < args.len) {
                load_anim_path = args[i];
            } else {
                return error.MissingArgument;
            }
        } else if (std.mem.eql(u8, args[i], "--export-zig")) {
            i += 1;
            if (i < args.len) {
                export_zig_name = args[i];
            } else {
                return error.MissingArgument;
            }
        } else if (std.mem.eql(u8, args[i], "--export-zig-anim")) {
            i += 1;
            if (i < args.len) {
                export_zig_anim_name = args[i];
            } else {
                return error.MissingArgument;
            }
        } else if (std.mem.eql(u8, args[i], "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            } else {
                return error.MissingArgument;
            }
        } else if (std.mem.eql(u8, args[i], "--stats")) {
            stats_only = true;
        } else if (std.mem.eql(u8, args[i], "--sixel")) {
            render_mode = .sixel;
        } else if (std.mem.eql(u8, args[i], "--help")) {
            std.debug.print(
                \\Usage: zigrid [options]
                \\Options:
                \\  -w, --width <n>    Set canvas width (max: 128)
                \\  -h, --height <n>   Set canvas height (max: 64)
                \\  --load <file>      Load a zigrid canvas file or PNG image before starting
                \\  --load-anim <file> Load a zigrid animation file before starting
                \\  --export-zig <id>  Export current canvas as a Zig asset module and exit
                \\  --export-zig-anim <id>
                \\                     Export current animation as a Zig asset module and exit
                \\  --output <file>    Output path for non-interactive export
                \\  --stats            Print packed asset size stats and exit
                \\  --sixel            Use sixel rendering instead of default block rendering
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

    const undo_stack = try allocator.alloc(Canvas, MAX_HISTORY);
    const redo_stack = try allocator.alloc(Canvas, MAX_HISTORY);
    defer allocator.free(undo_stack);
    defer allocator.free(redo_stack);

    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };

    // Initialize first frame with copy of canvas
    animation.frames[0] = try canvas.copy(allocator);
    var cleanup_animation_frames = true;
    defer {
        if (cleanup_animation_frames) {
            for (0..animation.frame_count) |frame_idx| {
                animation.frames[frame_idx].deinit();
            }
        }
    }

    if (load_path != null and load_anim_path != null) {
        std.debug.print("Use either --load or --load-anim, not both.\n", .{});
        return;
    }
    if (export_zig_name != null and export_zig_anim_name != null) {
        std.debug.print("Use either --export-zig or --export-zig-anim, not both.\n", .{});
        return;
    }

    if (load_path) |path| {
        const loaded = try Canvas.load(allocator, path);
        canvas.deinit();
        canvas = loaded;
        animation.frames[0].deinit();
        animation.frames[0] = try canvas.copy(allocator);
    } else if (load_anim_path) |path| {
        animation.frames[0].deinit();
        try animation.loadAnimation(allocator, path);
        canvas.deinit();
        canvas = try animation.frames[animation.current_frame].copy(allocator);
        width = canvas.width;
        height = canvas.height;
    }

    if (stats_only or export_zig_name != null or export_zig_anim_name != null) {
        if ((export_zig_name != null or export_zig_anim_name != null) and output_path == null) {
            std.debug.print("--output is required for Zig asset export.\n", .{});
            return;
        }

        if (load_anim_path != null or export_zig_anim_name != null) {
            const label = if (export_zig_anim_name) |name| name else "animation";
            std.debug.print(
                "{s}: {d}x{d} px | {d} bytes/row | {d} bytes/frame | {d} frame(s) | {d} total bytes\n",
                .{
                    label,
                    animation.frames[0].width,
                    animation.frames[0].height,
                    bytesPerRow(animation.frames[0].width),
                    bytesPerFrame(animation.frames[0].width, animation.frames[0].height),
                    animation.frame_count,
                    bytesPerFrame(animation.frames[0].width, animation.frames[0].height) * animation.frame_count,
                },
            );
        } else {
            const label = if (export_zig_name) |name| name else "canvas";
            std.debug.print(
                "{s}: {d}x{d} px | {d} bytes/row | {d} bytes/frame | {d} frame(s) | {d} total bytes\n",
                .{
                    label,
                    canvas.width,
                    canvas.height,
                    bytesPerRow(canvas.width),
                    bytesPerFrame(canvas.width, canvas.height),
                    @as(usize, 1),
                    bytesPerFrame(canvas.width, canvas.height),
                },
            );
        }

        if (export_zig_name) |name| {
            var id_buf: [128]u8 = undefined;
            const asset_name = sanitizeIdentifier(name, &id_buf);
            try canvas.saveZigAsset(output_path.?, asset_name);
        } else if (export_zig_anim_name) |name| {
            var id_buf: [128]u8 = undefined;
            const asset_name = sanitizeIdentifier(name, &id_buf);
            try animation.saveZigAsset(output_path.?, asset_name);
        }
        return;
    }

    // Check if we're running in a terminal
    if (!std.posix.isatty(stdin.handle)) {
        std.debug.print("This program must be run in an interactive terminal.\n", .{});
        return;
    }

    // Set terminal to raw mode
    const termios = try std.posix.tcgetattr(stdin.handle);

    var state = AppState{
        .canvas = canvas,
        .render_mode = render_mode,
        .original_termios = termios,
        .animation = animation,
        .undo_stack = undo_stack,
        .redo_stack = redo_stack,
    };
    cleanup_animation_frames = false;

    defer {
        for (0..state.animation.frame_count) |frame_idx| {
            state.animation.frames[frame_idx].deinit();
        }
        var idx: usize = 0;
        while (idx < state.undo_count) : (idx += 1) {
            state.undo_stack[idx].deinit();
        }
        idx = 0;
        while (idx < state.redo_count) : (idx += 1) {
            state.redo_stack[idx].deinit();
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
                clearHistory(&state);

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
    _ = allocator;
    switch (state.render_mode) {
        .block => try state.canvas.renderBlock(stdout, state.cursor_x, state.cursor_y),
        .sixel => try state.canvas.renderSixel(stdout, state.cursor_x, state.cursor_y),
    }

    const status_start_row = switch (state.render_mode) {
        .block => state.canvas.height + 3,
        .sixel => (state.canvas.height + 5) / 6 + 2,
    };

    // Move to status area and clear it
    var clear_buf: [64]u8 = undefined;
    const clear_str = try std.fmt.bufPrint(&clear_buf, "\x1B[{d};1H\x1B[J", .{status_start_row});
    try stdout.writeAll(clear_str);

    // Status line
    var status_buf: [256]u8 = undefined;
    if (state.mode == .animation) {
        const status_str = try std.fmt.bufPrint(&status_buf, "Animation Mode | Frame: {d}/{d} | Speed: {d}ms | {d} bytes/frame | {s}\n", .{
            state.animation.current_frame + 1,
            state.animation.frame_count,
            state.animation.frame_delay_ms,
            bytesPerFrame(state.canvas.width, state.canvas.height),
            if (state.animation.playing) "PLAYING" else "EDITING",
        });
        try stdout.writeAll(status_str);
    } else {
        const status_str = try std.fmt.bufPrint(&status_buf, "Mode: {s} | Color: {s} | Position: ({d}, {d}) | {d} bytes/frame\n", .{
            @tagName(state.mode),
            @tagName(state.color),
            state.cursor_x,
            state.cursor_y,
            bytesPerFrame(state.canvas.width, state.canvas.height),
        });
        try stdout.writeAll(status_str);
    }

    // Help text
    if (state.mode == .animation) {
        try stdout.writeAll("Animation: [/]=prev/next frame, n=new frame, d=delete frame, y=duplicate frame, p=play/pause, -/+=speed, a=save anim, o=load anim, A=save frame header, z=save frame Zig, Z=save anim Zig\n");
    } else {
        try stdout.writeAll("Controls: hjkl/arrows=move, space=draw, u=undo, r=redo, m=mode, c=color, s=save, S=save C array, z=save Zig, L=load, C=clear, q=quit\n");
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

fn clearRedo(state: *AppState) void {
    var idx: usize = 0;
    while (idx < state.redo_count) : (idx += 1) {
        state.redo_stack[idx].deinit();
    }
    state.redo_count = 0;
}

fn pushUndoCopy(state: *AppState, allocator: std.mem.Allocator) !void {
    if (state.undo_count == MAX_HISTORY) {
        state.undo_stack[0].deinit();
        var idx: usize = 0;
        while (idx + 1 < state.undo_count) : (idx += 1) {
            state.undo_stack[idx] = state.undo_stack[idx + 1];
        }
        state.undo_count -= 1;
    }

    state.undo_stack[state.undo_count] = try state.canvas.copy(allocator);
    state.undo_count += 1;
    clearRedo(state);
}

fn pushUndoMove(state: *AppState, canvas: Canvas) void {
    if (state.undo_count == MAX_HISTORY) {
        state.undo_stack[0].deinit();
        var idx: usize = 0;
        while (idx + 1 < state.undo_count) : (idx += 1) {
            state.undo_stack[idx] = state.undo_stack[idx + 1];
        }
        state.undo_count -= 1;
    }

    state.undo_stack[state.undo_count] = canvas;
    state.undo_count += 1;
}

fn pushRedoMove(state: *AppState, canvas: Canvas) void {
    if (state.redo_count == MAX_HISTORY) {
        state.redo_stack[0].deinit();
        var idx: usize = 0;
        while (idx + 1 < state.redo_count) : (idx += 1) {
            state.redo_stack[idx] = state.redo_stack[idx + 1];
        }
        state.redo_count -= 1;
    }

    state.redo_stack[state.redo_count] = canvas;
    state.redo_count += 1;
}

fn clearHistory(state: *AppState) void {
    var idx: usize = 0;
    while (idx < state.undo_count) : (idx += 1) {
        state.undo_stack[idx].deinit();
    }
    state.undo_count = 0;
    clearRedo(state);
}

fn clampCursor(state: *AppState) void {
    if (state.cursor_x >= state.canvas.width) {
        state.cursor_x = state.canvas.width - 1;
    }
    if (state.cursor_y >= state.canvas.height) {
        state.cursor_y = state.canvas.height - 1;
    }
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

        // Undo/Redo
        'u' => {
            if (state.undo_count > 0) {
                pushRedoMove(state, state.canvas);
                state.canvas = state.undo_stack[state.undo_count - 1];
                state.undo_count -= 1;
                clampCursor(state);
            }
        },

        'r' => {
            if (state.redo_count > 0) {
                pushUndoMove(state, state.canvas);
                state.canvas = state.redo_stack[state.redo_count - 1];
                state.redo_count -= 1;
                clampCursor(state);
            }
        },

        // Drawing
        ' ' => {
            switch (state.mode) {
                .pen => {
                    if (state.canvas.getPixel(state.cursor_x, state.cursor_y)) |pixel| {
                        if (pixel != state.color) {
                            try pushUndoCopy(state, allocator);
                            state.canvas.setPixel(state.cursor_x, state.cursor_y, state.color);
                        }
                    }
                },
                .line => {
                    if (state.line_start_x == null) {
                        state.line_start_x = state.cursor_x;
                        state.line_start_y = state.cursor_y;
                    } else {
                        try pushUndoCopy(state, allocator);
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
                        try pushUndoCopy(state, allocator);
                        state.canvas.drawRectangle(x, y, @intCast(w), @intCast(h), state.color, false);
                        state.rect_start_x = null;
                        state.rect_start_y = null;
                    }
                },
                .fill => {
                    if (state.canvas.getPixel(state.cursor_x, state.cursor_y)) |pixel| {
                        if (pixel != state.color) {
                            try pushUndoCopy(state, allocator);
                            try state.canvas.floodFill(state.cursor_x, state.cursor_y, state.color, allocator);
                        }
                    }
                },
                .animation => {
                    if (state.canvas.getPixel(state.cursor_x, state.cursor_y)) |pixel| {
                        if (pixel != state.color) {
                            try pushUndoCopy(state, allocator);
                            state.canvas.setPixel(state.cursor_x, state.cursor_y, state.color);
                        }
                    }
                }, // Allow drawing in animation mode
                .quit => {},
            }
        },

        'f' => {
            if (state.mode == .rectangle and state.rect_start_x != null) {
                const x = @min(state.rect_start_x.?, state.cursor_x);
                const y = @min(state.rect_start_y.?, state.cursor_y);
                const w = @abs(@as(isize, @intCast(state.cursor_x)) - @as(isize, @intCast(state.rect_start_x.?))) + 1;
                const h = @abs(@as(isize, @intCast(state.cursor_y)) - @as(isize, @intCast(state.rect_start_y.?))) + 1;
                try pushUndoCopy(state, allocator);
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
        'c' => {
            state.color = switch (state.color) {
                .black => .white,
                .white => .black,
            };
        },

        // Clear canvas
        'C' => {
            try pushUndoCopy(state, allocator);
            state.canvas.clear();
        },

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

        'z' => {
            try stdout_file.writeAll(if (state.mode == .animation)
                "\nEnter Zig asset filename for current frame: "
            else
                "\nEnter Zig asset filename: ");

            const raw = try std.posix.tcgetattr(stdin.handle);
            try std.posix.tcsetattr(stdin.handle, .NOW, state.original_termios);
            defer std.posix.tcsetattr(stdin.handle, .NOW, raw) catch {};

            var buf: [256]u8 = undefined;
            if (try readLine(stdin, &buf)) |filename| {
                var name_buf: [128]u8 = undefined;
                const asset_name = assetNameFromPath(filename, &name_buf);
                state.canvas.saveZigAsset(filename, asset_name) catch |err| {
                    var err_buf: [256]u8 = undefined;
                    const err_str = try std.fmt.bufPrint(&err_buf, "Error saving Zig asset: {any}\n", .{err});
                    try stdout_file.writeAll(err_str);
                };
            }
        },

        'A' => {
            if (state.mode == .animation) {
                // Save current frame first
                state.animation.frames[state.animation.current_frame].deinit();
                state.animation.frames[state.animation.current_frame] = try state.canvas.copy(allocator);

                try stdout_file.writeAll("\nEnter header filename for frames: ");

                const raw = try std.posix.tcgetattr(stdin.handle);
                try std.posix.tcsetattr(stdin.handle, .NOW, state.original_termios);
                defer std.posix.tcsetattr(stdin.handle, .NOW, raw) catch {};

                var buf: [256]u8 = undefined;
                if (try readLine(stdin, &buf)) |filename| {
                    state.animation.saveFrameHeader(filename) catch |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_str = try std.fmt.bufPrint(&err_buf, "Error saving frame header: {any}\n", .{err});
                        try stdout_file.writeAll(err_str);
                    };
                }
            }
        },

        'Z' => {
            if (state.mode == .animation) {
                state.animation.frames[state.animation.current_frame].deinit();
                state.animation.frames[state.animation.current_frame] = try state.canvas.copy(allocator);

                try stdout_file.writeAll("\nEnter Zig asset filename for animation: ");

                const raw = try std.posix.tcgetattr(stdin.handle);
                try std.posix.tcsetattr(stdin.handle, .NOW, state.original_termios);
                defer std.posix.tcsetattr(stdin.handle, .NOW, raw) catch {};

                var buf: [256]u8 = undefined;
                if (try readLine(stdin, &buf)) |filename| {
                    var name_buf: [128]u8 = undefined;
                    const asset_name = assetNameFromPath(filename, &name_buf);
                    state.animation.saveZigAsset(filename, asset_name) catch |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_str = try std.fmt.bufPrint(&err_buf, "Error saving Zig animation asset: {any}\n", .{err});
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
                try pushUndoCopy(state, allocator);
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

        'a' => {
            if (state.mode == .animation) {
                state.animation.frames[state.animation.current_frame].deinit();
                state.animation.frames[state.animation.current_frame] = try state.canvas.copy(allocator);

                try stdout_file.writeAll("\nEnter animation filename: ");

                const raw = try std.posix.tcgetattr(stdin.handle);
                try std.posix.tcsetattr(stdin.handle, .NOW, state.original_termios);
                defer std.posix.tcsetattr(stdin.handle, .NOW, raw) catch {};

                var buf: [256]u8 = undefined;
                if (try readLine(stdin, &buf)) |filename| {
                    state.animation.saveAnimation(filename) catch |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_str = try std.fmt.bufPrint(&err_buf, "Error saving animation: {any}\n", .{err});
                        try stdout_file.writeAll(err_str);
                    };
                }
            }
        },

        'o' => {
            if (state.mode == .animation) {
                try stdout_file.writeAll("\nEnter animation filename: ");

                const raw = try std.posix.tcgetattr(stdin.handle);
                try std.posix.tcsetattr(stdin.handle, .NOW, state.original_termios);
                defer std.posix.tcsetattr(stdin.handle, .NOW, raw) catch {};

                var buf: [256]u8 = undefined;
                if (try readLine(stdin, &buf)) |filename| {
                    var idx: usize = 0;
                    while (idx < state.animation.frame_count) : (idx += 1) {
                        state.animation.frames[idx].deinit();
                    }
                    clearHistory(state);

                    state.animation.loadAnimation(allocator, filename) catch |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_str = try std.fmt.bufPrint(&err_buf, "Error loading animation: {any}\n", .{err});
                        try stdout_file.writeAll(err_str);
                        return;
                    };

                    state.canvas.deinit();
                    state.canvas = try state.animation.frames[state.animation.current_frame].copy(allocator);
                    state.cursor_x = 0;
                    state.cursor_y = 0;
                }
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
                clearHistory(state);
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
                clearHistory(state);
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
                clearHistory(state);
            }
        },

        'd' => {
            if (state.mode == .animation and state.animation.frame_count > 1) {
                const removed = state.animation.current_frame;
                state.animation.frames[removed].deinit();

                var idx = removed;
                while (idx + 1 < state.animation.frame_count) : (idx += 1) {
                    state.animation.frames[idx] = state.animation.frames[idx + 1];
                }

                state.animation.frame_count -= 1;
                if (state.animation.current_frame >= state.animation.frame_count) {
                    state.animation.current_frame = state.animation.frame_count - 1;
                }

                state.canvas.deinit();
                state.canvas = try state.animation.frames[state.animation.current_frame].copy(allocator);
            }
        },

        'y' => {
            if (state.mode == .animation and state.animation.frame_count < MAX_FRAMES) {
                // Save current canvas to current frame
                state.animation.frames[state.animation.current_frame].deinit();
                state.animation.frames[state.animation.current_frame] = try state.canvas.copy(allocator);

                const insert_idx = state.animation.current_frame + 1;
                var idx = state.animation.frame_count;
                while (idx > insert_idx) : (idx -= 1) {
                    state.animation.frames[idx] = state.animation.frames[idx - 1];
                }

                state.animation.frames[insert_idx] = try state.animation.frames[state.animation.current_frame].copy(allocator);
                state.animation.frame_count += 1;
                state.animation.current_frame = insert_idx;

                state.canvas.deinit();
                state.canvas = try state.animation.frames[state.animation.current_frame].copy(allocator);
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

fn appendPngChunk(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    chunk_type: []const u8,
    chunk_data: []const u8,
) !void {
    var len_bytes: [4]u8 = undefined;
    var crc_bytes: [4]u8 = undefined;

    writeBigEndianU32(&len_bytes, @intCast(chunk_data.len));
    try output.appendSlice(allocator, &len_bytes);
    try output.appendSlice(allocator, chunk_type);
    try output.appendSlice(allocator, chunk_data);

    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(chunk_data);
    writeBigEndianU32(&crc_bytes, crc.final());
    try output.appendSlice(allocator, &crc_bytes);
}

fn buildZlibStoreBlock(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len > std.math.maxInt(u16)) return error.TestDataTooLarge;

    const output = try allocator.alloc(u8, 2 + 1 + 2 + 2 + bytes.len + 4);
    errdefer allocator.free(output);

    output[0] = 0x78;
    output[1] = 0x01;
    output[2] = 0x01;
    writeLittleEndianU16(output[3..5], @intCast(bytes.len));
    writeLittleEndianU16(output[5..7], ~@as(u16, @intCast(bytes.len)));
    @memcpy(output[7 .. 7 + bytes.len], bytes);

    var adler = std.hash.Adler32{};
    adler.update(bytes);
    writeBigEndianU32(output[7 + bytes.len .. 11 + bytes.len], adler.adler);

    return output;
}

fn buildTestPng(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    color_type: PngColorType,
    interlace_method: u8,
    pixels: []const u8,
) ![]u8 {
    const bytes_per_pixel = pngBytesPerPixel(color_type);
    const row_bytes = try std.math.mul(usize, width, bytes_per_pixel);
    if (pixels.len != try std.math.mul(usize, row_bytes, height)) return error.InvalidTestData;

    var scanlines: std.ArrayList(u8) = .empty;
    defer scanlines.deinit(allocator);
    try scanlines.ensureTotalCapacity(allocator, height * (row_bytes + 1));

    for (0..height) |y| {
        try scanlines.append(allocator, 0);
        try scanlines.appendSlice(allocator, pixels[y * row_bytes .. (y + 1) * row_bytes]);
    }

    const idat = try buildZlibStoreBlock(allocator, scanlines.items);
    defer allocator.free(idat);

    var ihdr: [13]u8 = undefined;
    writeBigEndianU32(ihdr[0..4], @intCast(width));
    writeBigEndianU32(ihdr[4..8], @intCast(height));
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(color_type);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = interlace_method;

    var png: std.ArrayList(u8) = .empty;
    defer png.deinit(allocator);
    try png.appendSlice(allocator, &PNG_SIGNATURE);
    try appendPngChunk(allocator, &png, "IHDR", &ihdr);
    try appendPngChunk(allocator, &png, "IDAT", idat);
    try appendPngChunk(allocator, &png, "IEND", "");

    return png.toOwnedSlice(allocator);
}

test "PNG load auto-detects RGBA and keeps transparent pixels white" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{
        0,  0,  0,  255,
        10, 20, 30, 0,
    };
    const png = try buildTestPng(allocator, 2, 1, .rgba, 0, &pixels);
    defer allocator.free(png);

    var canvas = try Canvas.loadAutoBytes(allocator, png);
    defer canvas.deinit();

    try std.testing.expectEqual(@as(usize, 2), canvas.width);
    try std.testing.expectEqual(@as(usize, 1), canvas.height);
    try std.testing.expectEqual(Color.black, canvas.pixels[0][0]);
    try std.testing.expectEqual(Color.white, canvas.pixels[0][1]);
}

test "PNG load scales oversized grayscale images to fit the canvas" {
    const allocator = std.testing.allocator;
    const width = 256;
    const height = 64;
    const pixels = try allocator.alloc(u8, width * height);
    defer allocator.free(pixels);
    @memset(pixels, 0);

    const png = try buildTestPng(allocator, width, height, .grayscale, 0, pixels);
    defer allocator.free(png);

    var canvas = try Canvas.loadAutoBytes(allocator, png);
    defer canvas.deinit();

    try std.testing.expectEqual(@as(usize, 128), canvas.width);
    try std.testing.expectEqual(@as(usize, 32), canvas.height);
    try std.testing.expectEqual(Color.black, canvas.pixels[0][0]);
    try std.testing.expectEqual(Color.black, canvas.pixels[canvas.height - 1][canvas.width - 1]);
}

test "PNG load rejects unsupported interlaced images" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{0};
    const png = try buildTestPng(allocator, 1, 1, .grayscale, 1, &pixels);
    defer allocator.free(png);

    try std.testing.expectError(error.UnsupportedPngInterlace, Canvas.loadAutoBytes(allocator, png));
}

test "PNG load rejects invalid CRC" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{0};
    var png = try buildTestPng(allocator, 1, 1, .grayscale, 0, &pixels);
    defer allocator.free(png);

    png[15] ^= 0x01;
    try std.testing.expectError(error.InvalidPngChunkCrc, Canvas.loadAutoBytes(allocator, png));
}

test "PNG unfilter supports Sub and Paeth filters" {
    const allocator = std.testing.allocator;
    const sub_filtered = [_]u8{ 1, 10, 10, 5 };
    const paeth_filtered = [_]u8{
        0, 10, 20, 30,
        4, 5,  5,  5,
    };

    const sub_pixels = try unfilterPngScanlines(allocator, 3, 1, 1, &sub_filtered);
    defer allocator.free(sub_pixels);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 25 }, sub_pixels);

    const paeth_pixels = try unfilterPngScanlines(allocator, 3, 2, 1, &paeth_filtered);
    defer allocator.free(paeth_pixels);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 15, 25, 35 }, paeth_pixels);
}
