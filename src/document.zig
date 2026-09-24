const std = @import("std");

pub const Color = union(enum) {
    indexed: u8,
    rgb: [3]u8,
};

pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    underline: bool = false,
};

pub const Span = struct { text: []const u8, style: Style };
pub const Line = struct { spans: []Span };
pub const Parsed = struct { lines: []Line };

pub fn parse(arena: std.mem.Allocator, input: []const u8) !Parsed {
    var lines: std.ArrayList(Line) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var style: Style = .{};
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte == 0x1b) {
            if (index + 1 >= input.len) break;
            const next = input[index + 1];
            if (next == '[') {
                const start = index + 2;
                index = start;
                while (index < input.len and !(input[index] >= 0x40 and input[index] <= 0x7e)) index += 1;
                if (index == input.len) break;
                const final = input[index];
                if (final == 'm') {
                    try flushSpan(arena, &spans, &text, style);
                    applySgr(&style, input[start..index]);
                }
                index += 1;
                continue;
            }
            if (next == ']' or next == 'P' or next == '_' or next == '^') {
                index += 2;
                while (index < input.len) : (index += 1) {
                    if (input[index] == 7) {
                        index += 1;
                        break;
                    }
                    if (input[index] == 0x1b and index + 1 < input.len and input[index + 1] == '\\') {
                        index += 2;
                        break;
                    }
                }
                continue;
            }
            index += 2;
            continue;
        }
        index += 1;
        switch (byte) {
            '\n' => {
                try flushSpan(arena, &spans, &text, style);
                try lines.append(arena, .{ .spans = try spans.toOwnedSlice(arena) });
            },
            '\t' => try text.appendSlice(arena, "    "),
            0x20...0x7e, 0x80...0xff => try text.append(arena, byte),
            else => {},
        }
    }
    try flushSpan(arena, &spans, &text, style);
    try lines.append(arena, .{ .spans = try spans.toOwnedSlice(arena) });
    return .{ .lines = try lines.toOwnedSlice(arena) };
}

fn flushSpan(arena: std.mem.Allocator, spans: *std.ArrayList(Span), text: *std.ArrayList(u8), style: Style) !void {
    if (text.items.len == 0) return;
    if (!std.unicode.utf8ValidateSlice(text.items)) return error.InvalidDocumentText;
    try spans.append(arena, .{ .text = try text.toOwnedSlice(arena), .style = style });
}

fn applySgr(style: *Style, source: []const u8) void {
    var params: [32]u16 = undefined;
    var count: usize = 0;
    var pieces = std.mem.splitScalar(u8, source, ';');
    while (pieces.next()) |piece| {
        if (count == params.len) return;
        params[count] = if (piece.len == 0) 0 else std.fmt.parseInt(u16, piece, 10) catch return;
        count += 1;
    }
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const code = params[index];
        switch (code) {
            0 => style.* = .{},
            1 => style.bold = true,
            2 => style.dim = true,
            4 => style.underline = true,
            22 => {
                style.bold = false;
                style.dim = false;
            },
            24 => style.underline = false,
            30...37 => style.fg = .{ .indexed = @intCast(code - 30) },
            39 => style.fg = null,
            40...47 => style.bg = .{ .indexed = @intCast(code - 40) },
            49 => style.bg = null,
            90...97 => style.fg = .{ .indexed = @intCast(code - 90 + 8) },
            100...107 => style.bg = .{ .indexed = @intCast(code - 100 + 8) },
            38, 48 => {
                const color = extendedColor(params[0..count], &index) orelse continue;
                if (code == 38) style.fg = color else style.bg = color;
            },
            else => {},
        }
    }
}

fn extendedColor(params: []const u16, index: *usize) ?Color {
    if (index.* + 1 >= params.len) return null;
    switch (params[index.* + 1]) {
        5 => {
            if (index.* + 2 >= params.len or params[index.* + 2] > 255) return null;
            index.* += 2;
            return .{ .indexed = @intCast(params[index.*]) };
        },
        2 => {
            if (index.* + 4 >= params.len) return null;
            const red = params[index.* + 2];
            const green = params[index.* + 3];
            const blue = params[index.* + 4];
            if (red > 255 or green > 255 or blue > 255) return null;
            index.* += 4;
            return .{ .rgb = .{ @intCast(red), @intCast(green), @intCast(blue) } };
        },
        else => return null,
    }
}
