const std = @import("std");
const git_patch = @import("git_patch.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

pub const RowKind = enum { hunk, context, change, fold, fallback };

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
    hidden: []PairRow = &.{},
    expanded: bool = false,
};

pub fn fullRows(arena: std.mem.Allocator, file: git_patch.FileEntry, before_text: []const u8, after_text: []const u8) ![]PairRow {
    const patch_rows = try rows(arena, file);
    if (patch_rows.len == 0 or patch_rows[0].kind == .fallback) return patch_rows;
    const before_lines = try sourceLines(arena, before_text);
    const after_lines = try sourceLines(arena, after_text);
    var complete: std.ArrayList(PairRow) = .empty;
    var before_next: usize = 1;
    var after_next: usize = 1;
    for (patch_rows) |row| {
        if (row.kind == .hunk) {
            const header = parseHunkHeader(row.label) catch return patch_rows;
            const before_start = header.old + @intFromBool(header.old_count == 0);
            const after_start = header.new + @intFromBool(header.new_count == 0);
            if (!try appendGap(arena, &complete, before_lines, after_lines, &before_next, &after_next, before_start, after_start)) return patch_rows;
            continue;
        }
        if (row.before) |side| {
            if (side.number != before_next or side.number > before_lines.len or
                !std.mem.eql(u8, side.text, before_lines[side.number - 1].text) or
                side.no_newline != before_lines[side.number - 1].no_newline) return patch_rows;
            before_next += 1;
        }
        if (row.after) |side| {
            if (side.number != after_next or side.number > after_lines.len or
                !std.mem.eql(u8, side.text, after_lines[side.number - 1].text) or
                side.no_newline != after_lines[side.number - 1].no_newline) return patch_rows;
            after_next += 1;
        }
        try complete.append(arena, row);
    }
    if (!try appendGap(arena, &complete, before_lines, after_lines, &before_next, &after_next, before_lines.len + 1, after_lines.len + 1)) return patch_rows;
    return foldContext(arena, complete.items);
}

pub fn visibleRows(arena: std.mem.Allocator, all: []PairRow) ![]PairRow {
    var visible: std.ArrayList(PairRow) = .empty;
    for (all) |row| {
        try visible.append(arena, row);
        if (row.kind == .fold and row.expanded) try visible.appendSlice(arena, row.hidden);
    }
    return visible.toOwnedSlice(arena);
}

pub fn toggleFold(all: []PairRow, visible_index: usize) bool {
    var position: usize = 0;
    for (all) |*row| {
        if (position == visible_index and row.kind == .fold) {
            row.expanded = !row.expanded;
            return true;
        }
        position += 1;
        if (row.kind == .fold and row.expanded) position += row.hidden.len;
    }
    return false;
}

fn sourceLines(arena: std.mem.Allocator, text: []const u8) ![]Side {
    var output: std.ArrayList(Side) = .empty;
    var position: usize = 0;
    while (position < text.len) {
        const line = nextLine(text, position);
        try output.append(arena, .{
            .number = output.items.len + 1,
            .text = text[position..line.end],
            .no_newline = line.next == text.len and line.end == text.len,
        });
        position = line.next;
    }
    return output.toOwnedSlice(arena);
}

fn appendGap(
    arena: std.mem.Allocator,
    output: *std.ArrayList(PairRow),
    before_lines: []const Side,
    after_lines: []const Side,
    before_next: *usize,
    after_next: *usize,
    before_end: usize,
    after_end: usize,
) !bool {
    if (before_end < before_next.* or after_end < after_next.* or before_end > before_lines.len + 1 or after_end > after_lines.len + 1) return false;
    const count = before_end - before_next.*;
    if (count != after_end - after_next.*) return false;
    for (0..count) |offset| {
        const before = before_lines[before_next.* + offset - 1];
        const after = after_lines[after_next.* + offset - 1];
        if (!std.mem.eql(u8, before.text, after.text) or before.no_newline != after.no_newline) return false;
        try output.append(arena, .{ .kind = .context, .before = before, .after = after });
    }
    before_next.* = before_end;
    after_next.* = after_end;
    return true;
}

fn foldContext(arena: std.mem.Allocator, complete: []PairRow) ![]PairRow {
    var output: std.ArrayList(PairRow) = .empty;
    var position: usize = 0;
    while (position < complete.len) {
        if (complete[position].kind != .context) {
            try output.append(arena, complete[position]);
            position += 1;
            continue;
        }
        const start = position;
        while (position < complete.len and complete[position].kind == .context) position += 1;
        const head: usize = if (start == 0) 0 else 3;
        const tail: usize = if (position == complete.len) 0 else 3;
        if (position - start <= head + tail + 2) {
            try output.appendSlice(arena, complete[start..position]);
            continue;
        }
        try output.appendSlice(arena, complete[start .. start + head]);
        try output.append(arena, .{ .kind = .fold, .hidden = complete[start + head .. position - tail] });
        try output.appendSlice(arena, complete[position - tail .. position]);
    }
    return output.toOwnedSlice(arena);
}

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

test "real Git hunks align unequal changes and preserve line numbers" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const patch = try git_patch.parse(arena, @embedFile("fixtures/hunks.patch"));
    const parsed = try @This().rows(arena, patch.files[0]);
    try expectEqual(@as(usize, 10), parsed.len);
    try expectEqual(RowKind.hunk, parsed[0].kind);
    try expectEqualStrings("zero", parsed[1].before.?.text);
    try expectEqual(@as(usize, 1), parsed[1].before.?.number);
    try expectEqual(@as(usize, 1), parsed[1].after.?.number);
    try expectEqualStrings("one", parsed[2].before.?.text);
    try expectEqualStrings("ONE", parsed[2].after.?.text);
    try expectEqual(@as(usize, 2), parsed[2].before.?.number);
    try expectEqual(@as(usize, 2), parsed[2].after.?.number);
    try expect(parsed[3].before == null);
    try expectEqualStrings("extra", parsed[3].after.?.text);
    try expectEqual(@as(usize, 3), parsed[3].after.?.number);
    try expectEqualStrings("", parsed[5].before.?.text);
    try expectEqual(@as(usize, 4), parsed[5].before.?.number);
    try expectEqual(@as(usize, 5), parsed[5].after.?.number);
    try expectEqual(RowKind.hunk, parsed[6].kind);
    try expectEqualStrings("nine", parsed[9].before.?.text);
    try expectEqualStrings("NINE", parsed[9].after.?.text);
    try expectEqual(@as(usize, 10), parsed[9].before.?.number);
    try expectEqual(@as(usize, 11), parsed[9].after.?.number);
    // Git's no-newline marker describes the preceding line and consumes no line number.
    try expect(parsed[9].before.?.no_newline);
    try expect(parsed[9].after.?.no_newline);
}

test "binary mode-only and malformed hunks remain visible as raw rows" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const kinds = try git_patch.parse(arena, @embedFile("fixtures/kinds.patch"));
    for ([_]usize{ 1, 4 }) |index| {
        const parsed = try @This().rows(arena, kinds.files[index]);
        try expect(parsed.len > 0);
        try expectEqual(RowKind.fallback, parsed[0].kind);
        try expect(std.mem.startsWith(u8, parsed[0].before.?.text, "diff --git"));
    }
    const malformed = try git_patch.parse(arena, "diff --git a/B.cs b/B.cs\n@@ -1 +1 @@\n+new\n");
    const parsed = try @This().rows(arena, malformed.files[0]);
    try expectEqual(RowKind.fallback, parsed[0].kind);
}

test "full file text restores omitted lines only when it matches the patch" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const patch = try git_patch.parse(arena, @embedFile("fixtures/hunks.patch"));
    const before = "zero\none\ntwo\n\nfour\nfive\nsix\nseven\neight\nnine";
    const after = "zero\nONE\nextra\ntwo\n\nfour\nfive\nsix\nseven\neight\nNINE";
    const restored = try fullRows(arena, patch.files[0], before, after);
    try expectEqual(@as(usize, 11), restored.len);
    try expectEqualStrings("four", restored[5].before.?.text);
    try expectEqual(@as(usize, 6), restored[5].after.?.number);
    try expectEqualStrings("NINE", restored[10].after.?.text);

    // A stale worktree file must not replace lines from a captured Git patch.
    const stale = try fullRows(arena, patch.files[0], before, "different\n");
    try expectEqual(RowKind.hunk, stale[0].kind);
}
