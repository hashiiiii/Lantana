const std = @import("std");
const git_patch = @import("git_patch.zig");

pub const RowKind = enum { hunk, context, change, fallback };

pub const Side = struct {
    number: usize,
    text: []const u8,
    no_newline: bool = false,
};

pub const PairRow = struct {
    kind: RowKind,
    before: ?Side = null,
    after: ?Side = null,
    label: []const u8 = "",
};

pub fn rows(arena: std.mem.Allocator, file: git_patch.FileEntry) ![]PairRow {
    if (file.kind == .binary or file.kind == .mode_only or file.kind == .unsupported) return fallback(arena, file.raw);
    var output: std.ArrayList(PairRow) = .empty;
    var removed: std.ArrayList(Side) = .empty;
    var added: std.ArrayList(Side) = .empty;
    var old_number: usize = 0;
    var new_number: usize = 0;
    var old_remaining: usize = 0;
    var new_remaining: usize = 0;
    var seen_hunk = false;
    var last_side: enum { none, before, after, context } = .none;

    var position: usize = 0;
    while (position < file.raw.len) {
        const line = nextLine(file.raw, position);
        const clean = try git_patch.controlFree(arena, file.raw[position..line.end]);
        position = line.next;
        if (std.mem.startsWith(u8, clean, "@@ ")) {
            if (seen_hunk) {
                if (old_remaining != 0 or new_remaining != 0) return fallback(arena, file.raw);
                try flush(arena, &output, &removed, &added);
            }
            const header = parseHunkHeader(clean) catch return fallback(arena, file.raw);
            old_number = header.old;
            new_number = header.new;
            old_remaining = header.old_count;
            new_remaining = header.new_count;
            seen_hunk = true;
            last_side = .none;
            try output.append(arena, .{ .kind = .hunk, .label = clean });
            continue;
        }
        if (!seen_hunk) continue;
        if (clean.len == 0) return fallback(arena, file.raw);
        switch (clean[0]) {
            ' ' => {
                if (old_remaining == 0 or new_remaining == 0) return fallback(arena, file.raw);
                try flush(arena, &output, &removed, &added);
                try output.append(arena, .{
                    .kind = .context,
                    .before = .{ .number = old_number, .text = clean[1..] },
                    .after = .{ .number = new_number, .text = clean[1..] },
                });
                old_number += 1;
                new_number += 1;
                old_remaining -= 1;
                new_remaining -= 1;
                last_side = .context;
            },
            '-' => {
                if (old_remaining == 0) return fallback(arena, file.raw);
                try removed.append(arena, .{ .number = old_number, .text = clean[1..] });
                old_number += 1;
                old_remaining -= 1;
                last_side = .before;
            },
            '+' => {
                if (new_remaining == 0) return fallback(arena, file.raw);
                try added.append(arena, .{ .number = new_number, .text = clean[1..] });
                new_number += 1;
                new_remaining -= 1;
                last_side = .after;
            },
            '\\' => {
                if (!std.mem.eql(u8, clean, "\\ No newline at end of file")) return fallback(arena, file.raw);
                switch (last_side) {
                    .before => if (removed.items.len > 0) {
                        removed.items[removed.items.len - 1].no_newline = true;
                    } else return fallback(arena, file.raw),
                    .after => if (added.items.len > 0) {
                        added.items[added.items.len - 1].no_newline = true;
                    } else return fallback(arena, file.raw),
                    .context => {
                        const row = &output.items[output.items.len - 1];
                        row.before.?.no_newline = true;
                        row.after.?.no_newline = true;
                    },
                    .none => return fallback(arena, file.raw),
                }
            },
            else => return fallback(arena, file.raw),
        }
    }
    if (!seen_hunk or old_remaining != 0 or new_remaining != 0) return fallback(arena, file.raw);
    try flush(arena, &output, &removed, &added);
    return output.toOwnedSlice(arena);
}

fn flush(arena: std.mem.Allocator, output: *std.ArrayList(PairRow), removed: *std.ArrayList(Side), added: *std.ArrayList(Side)) !void {
    const count = @max(removed.items.len, added.items.len);
    for (0..count) |index| {
        try output.append(arena, .{
            .kind = .change,
            .before = if (index < removed.items.len) removed.items[index] else null,
            .after = if (index < added.items.len) added.items[index] else null,
        });
    }
    removed.clearRetainingCapacity();
    added.clearRetainingCapacity();
}

fn fallback(arena: std.mem.Allocator, raw: []const u8) ![]PairRow {
    var output: std.ArrayList(PairRow) = .empty;
    var position: usize = 0;
    while (position < raw.len) {
        const line = nextLine(raw, position);
        try output.append(arena, .{
            .kind = .fallback,
            .before = .{ .number = 0, .text = try git_patch.controlFree(arena, raw[position..line.end]) },
        });
        position = line.next;
    }
    return output.toOwnedSlice(arena);
}

const Line = struct { end: usize, next: usize };

fn nextLine(raw: []const u8, position: usize) Line {
    const length = std.mem.indexOfScalar(u8, raw[position..], '\n') orelse return .{ .end = raw.len, .next = raw.len };
    const end = position + length;
    return .{ .end = end, .next = end + 1 };
}

const Hunk = struct { old: usize, old_count: usize, new: usize, new_count: usize };

fn parseHunkHeader(line: []const u8) !Hunk {
    if (!std.mem.startsWith(u8, line, "@@ -")) return error.InvalidHunk;
    var position: usize = 4;
    const old = try number(line, &position);
    const old_count = if (position < line.len and line[position] == ',') blk: {
        position += 1;
        break :blk try number(line, &position);
    } else 1;
    if (position + 2 >= line.len or line[position] != ' ' or line[position + 1] != '+') return error.InvalidHunk;
    position += 2;
    const new = try number(line, &position);
    const new_count = if (position < line.len and line[position] == ',') blk: {
        position += 1;
        break :blk try number(line, &position);
    } else 1;
    if (position + 3 > line.len or !std.mem.eql(u8, line[position .. position + 3], " @@")) return error.InvalidHunk;
    return .{ .old = old, .old_count = old_count, .new = new, .new_count = new_count };
}

fn number(line: []const u8, position: *usize) !usize {
    const start = position.*;
    while (position.* < line.len and std.ascii.isDigit(line[position.*])) position.* += 1;
    if (start == position.*) return error.InvalidHunk;
    return std.fmt.parseInt(usize, line[start..position.*], 10) catch error.InvalidHunk;
}
