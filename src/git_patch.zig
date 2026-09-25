const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

pub const ChangeKind = enum { modified, added, deleted, renamed, binary, mode_only, unsupported };

pub const FileEntry = struct {
    raw: []const u8,
    start: usize,
    end: usize,
    display_path: []const u8,
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    kind: ChangeKind,
    old_blob: ?[]const u8 = null,
    new_blob: ?[]const u8 = null,
    added_lines: usize = 0,
    removed_lines: usize = 0,
};

pub const Patch = struct {
    source: []const u8,
    files: []FileEntry,
    prelude: []const u8,
    raw_fallback: ?[]const u8 = null,
};

pub fn parse(arena: std.mem.Allocator, source: []const u8) !Patch {
    var starts: std.ArrayList(usize) = .empty;
    var ordinary_count: usize = 0;
    var position: usize = 0;
    while (position < source.len) {
        const line = nextLine(source, position);
        const clean = try controlFree(arena, source[position..line.end]);
        if (std.mem.startsWith(u8, clean, "diff --git ")) {
            try starts.append(arena, position);
            ordinary_count += 1;
        } else if (std.mem.startsWith(u8, clean, "diff --cc ") or std.mem.startsWith(u8, clean, "diff --combined ")) {
            try starts.append(arena, position);
        }
        position = line.next;
    }
    if (ordinary_count == 0) return .{
        .source = source,
        .files = try arena.alloc(FileEntry, 0),
        .prelude = "",
        .raw_fallback = source,
    };

    const files = try arena.alloc(FileEntry, starts.items.len);
    for (starts.items, 0..) |start, index| {
        const end = if (index + 1 < starts.items.len) starts.items[index + 1] else source.len;
        files[index] = try parseSection(arena, source[start..end], start, end);
    }
    return .{ .source = source, .files = files, .prelude = source[0..starts.items[0]] };
}

const Line = struct { end: usize, next: usize };

fn nextLine(source: []const u8, position: usize) Line {
    const length = std.mem.indexOfScalar(u8, source[position..], '\n') orelse return .{ .end = source.len, .next = source.len };
    const end = position + length;
    return .{ .end = end, .next = end + 1 };
}

const Paths = struct { old: ?[]const u8, new: ?[]const u8 };

fn parseSection(arena: std.mem.Allocator, raw: []const u8, start: usize, end: usize) !FileEntry {
    const first = nextLine(raw, 0);
    const header = try controlFree(arena, raw[0..first.end]);
    const paths = parseHeader(arena, header) catch |err| switch (err) {
        error.InvalidPatchPath => null,
        else => return err,
    };
    if (paths == null) return .{
        .raw = raw,
        .start = start,
        .end = end,
        .display_path = "(unsupported patch section)",
        .old_path = null,
        .new_path = null,
        .kind = .unsupported,
    };
    var file: FileEntry = .{
        .raw = raw,
        .start = start,
        .end = end,
        .display_path = paths.?.new orelse paths.?.old orelse "(unknown path)",
        .old_path = paths.?.old,
        .new_path = paths.?.new,
        .kind = .modified,
    };
    var added = false;
    var deleted = false;
    var renamed = false;
    var binary = false;
    var mode = false;
    var hunk = false;
    var rename_from: ?[]const u8 = null;
    var rename_to: ?[]const u8 = null;
    var position = first.next;
    while (position < raw.len) {
        const line = nextLine(raw, position);
        const clean = try controlFree(arena, raw[position..line.end]);
        if (std.mem.startsWith(u8, clean, "@@ ")) {
            hunk = true;
            position = line.next;
            continue;
        }
        // Hunk lines can begin with the same bytes as Git metadata after their +/- prefix.
        if (hunk) {
            if (clean.len != 0 and clean[0] == '+') file.added_lines += 1;
            if (clean.len != 0 and clean[0] == '-') file.removed_lines += 1;
            position = line.next;
            continue;
        }
        if (std.mem.startsWith(u8, clean, "new file mode ")) added = true;
        if (std.mem.startsWith(u8, clean, "deleted file mode ")) deleted = true;
        if (std.mem.startsWith(u8, clean, "rename from ")) {
            renamed = true;
            rename_from = decodeRenamePath(arena, clean[12..]) catch |err| switch (err) {
                error.InvalidPatchPath => null,
                else => return err,
            };
        }
        if (std.mem.startsWith(u8, clean, "rename to ")) {
            renamed = true;
            rename_to = decodeRenamePath(arena, clean[10..]) catch |err| switch (err) {
                error.InvalidPatchPath => null,
                else => return err,
            };
        }
        if (std.mem.startsWith(u8, clean, "Binary files ") or std.mem.eql(u8, clean, "GIT binary patch")) binary = true;
        if (std.mem.startsWith(u8, clean, "old mode ") or std.mem.startsWith(u8, clean, "new mode ")) mode = true;
        if (std.mem.startsWith(u8, clean, "index ")) parseIndex(&file, clean[6..]);
        if (std.mem.startsWith(u8, clean, "--- ")) {
            file.old_path = decodePathLine(arena, clean[4..], 'a') catch |err| switch (err) {
                error.InvalidPatchPath => file.old_path,
                else => return err,
            };
        }
        if (std.mem.startsWith(u8, clean, "+++ ")) {
            file.new_path = decodePathLine(arena, clean[4..], 'b') catch |err| switch (err) {
                error.InvalidPatchPath => file.new_path,
                else => return err,
            };
        }
        position = line.next;
    }
    if (rename_from) |path| file.old_path = path;
    if (rename_to) |path| file.new_path = path;
    if (added) file.old_path = null;
    if (deleted) file.new_path = null;
    file.display_path = file.new_path orelse file.old_path orelse "(unknown path)";
    file.kind = if (added) .added else if (deleted) .deleted else if (renamed) .renamed else if (binary) .binary else if (mode and !hunk) .mode_only else .modified;
    return file;
}

fn parseIndex(file: *FileEntry, value: []const u8) void {
    const end = std.mem.indexOfAny(u8, value, " \t\r") orelse value.len;
    const pair = value[0..end];
    const sep = std.mem.indexOf(u8, pair, "..") orelse return;
    if (sep == 0 or sep + 2 == pair.len) return;
    file.old_blob = pair[0..sep];
    file.new_blob = pair[sep + 2 ..];
}

fn parseHeader(arena: std.mem.Allocator, header: []const u8) !Paths {
    if (!std.mem.startsWith(u8, header, "diff --git ")) return error.InvalidPatchPath;
    const rest = header[11..];
    if (rest.len == 0) return error.InvalidPatchPath;
    if (rest[0] == '"') {
        const old = try quoted(arena, rest);
        const remaining = std.mem.trimStart(u8, rest[old.consumed..], " ");
        if (remaining.len == 0) return error.InvalidPatchPath;
        if (remaining[0] == '"') {
            const new = try quoted(arena, remaining);
            if (std.mem.trim(u8, remaining[new.consumed..], " \t\r").len != 0) return error.InvalidPatchPath;
            return .{ .old = try stripPrefix(old.value, 'a'), .new = try stripPrefix(new.value, 'b') };
        }
        return .{ .old = try stripPrefix(old.value, 'a'), .new = try stripPrefix(std.mem.trimEnd(u8, remaining, "\t\r"), 'b') };
    }
    if (std.mem.indexOf(u8, rest, " \"")) |boundary| {
        const old = rest[0..boundary];
        const remaining = rest[boundary + 1 ..];
        const new = try quoted(arena, remaining);
        if (std.mem.trim(u8, remaining[new.consumed..], " \t\r").len != 0) return error.InvalidPatchPath;
        return .{ .old = try stripPrefix(old, 'a'), .new = try stripPrefix(new.value, 'b') };
    }
    var boundary: ?usize = null;
    var cursor: usize = 0;
    // Mode-only sections have no ---/+++ paths, so prefer the split where both sides agree.
    while (std.mem.indexOfPos(u8, rest, cursor, " b/")) |candidate| {
        if (boundary == null) boundary = candidate;
        const old_candidate = rest[0..candidate];
        const new_candidate = rest[candidate + 1 ..];
        if (std.mem.startsWith(u8, old_candidate, "a/") and std.mem.startsWith(u8, new_candidate, "b/") and
            std.mem.eql(u8, old_candidate[2..], new_candidate[2..]))
        {
            boundary = candidate;
            break;
        }
        cursor = candidate + 1;
    }
    const split = boundary orelse return error.InvalidPatchPath;
    const old = rest[0..split];
    const new = rest[split + 1 ..];
    return .{ .old = try stripPrefix(old, 'a'), .new = try stripPrefix(new, 'b') };
}

fn stripPrefix(value: []const u8, expected: u8) !?[]const u8 {
    if (std.mem.eql(u8, value, "/dev/null")) return null;
    if (value.len < 3 or value[0] != expected or value[1] != '/') return error.InvalidPatchPath;
    return value[2..];
}

fn decodePathLine(arena: std.mem.Allocator, input: []const u8, expected: u8) !?[]const u8 {
    const value = std.mem.trimEnd(u8, input, "\t\r");
    if (value.len == 0) return error.InvalidPatchPath;
    if (value[0] == '"') {
        const parsed = try quoted(arena, value);
        return stripPrefix(parsed.value, expected);
    }
    return stripPrefix(value, expected);
}

fn decodeRenamePath(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    const value = std.mem.trimEnd(u8, input, "\r");
    if (value.len == 0) return error.InvalidPatchPath;
    if (value[0] != '"') return value;
    const parsed = try quoted(arena, value);
    if (std.mem.trim(u8, value[parsed.consumed..], " \t\r").len != 0) return error.InvalidPatchPath;
    return parsed.value;
}

const Quoted = struct { value: []const u8, consumed: usize };

fn quoted(arena: std.mem.Allocator, source: []const u8) !Quoted {
    if (source.len == 0 or source[0] != '"') return error.InvalidPatchPath;
    var decoded: std.ArrayList(u8) = .empty;
    var index: usize = 1;
    while (index < source.len) {
        const byte = source[index];
        index += 1;
        if (byte == '"') return .{ .value = try decoded.toOwnedSlice(arena), .consumed = index };
        if (byte != '\\') {
            try decoded.append(arena, byte);
            continue;
        }
        if (index == source.len) return error.InvalidPatchPath;
        const escaped = source[index];
        index += 1;
        if (escaped >= '0' and escaped <= '7') {
            var value: u16 = escaped - '0';
            var count: usize = 1;
            while (count < 3 and index < source.len and source[index] >= '0' and source[index] <= '7') : (count += 1) {
                value = value * 8 + source[index] - '0';
                index += 1;
            }
            if (value > 255) return error.InvalidPatchPath;
            try decoded.append(arena, @intCast(value));
            continue;
        }
        const mapped: u8 = switch (escaped) {
            'a' => 7,
            'b' => 8,
            'f' => 12,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => 11,
            '"', '\\' => escaped,
            else => return error.InvalidPatchPath,
        };
        try decoded.append(arena, mapped);
    }
    return error.InvalidPatchPath;
}

pub fn controlFree(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var clean: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < raw.len) {
        const byte = raw[index];
        if (byte == 0x1b and index + 1 < raw.len) {
            const next = raw[index + 1];
            index += 2;
            if (next == '[') {
                while (index < raw.len) : (index += 1) {
                    if (raw[index] >= 0x40 and raw[index] <= 0x7e) {
                        index += 1;
                        break;
                    }
                }
            } else if (next == ']') {
                while (index < raw.len) : (index += 1) {
                    if (raw[index] == 7) {
                        index += 1;
                        break;
                    }
                    if (raw[index] == 0x1b and index + 1 < raw.len and raw[index + 1] == '\\') {
                        index += 2;
                        break;
                    }
                }
            }
            continue;
        }
        index += 1;
        if (byte >= 0x20 or byte == '\t') try clean.append(arena, byte);
    }
    return clean.toOwnedSlice(arena);
}

fn parseFixture(arena: std.mem.Allocator, comptime name: []const u8) !Patch {
    return parse(arena, @embedFile("fixtures/" ++ name));
}

test "ordinary Git sections retain exact bytes and do not split on hunk text" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const source = @embedFile("fixtures/ordinary.patch");
    const patch = try parseFixture(memory.allocator(), "ordinary.patch");
    try expectEqual(@as(usize, 2), patch.files.len);
    try expectEqualStrings("Assets/A.prefab", patch.files[0].display_path);
    try expectEqualStrings("Scripts/A.cs", patch.files[1].display_path);
    try expectEqual(ChangeKind.modified, patch.files[0].kind);
    try expectEqualStrings("a869c28", patch.files[1].old_blob.?);
    try expectEqualStrings("0dad58b", patch.files[1].new_blob.?);
    // Counts come from hunk content, so +++/--- paths and header text cannot inflate them.
    try expectEqual(@as(usize, 1), patch.files[0].added_lines);
    try expectEqual(@as(usize, 1), patch.files[0].removed_lines);
    try expectEqual(@as(usize, 3), patch.files[1].added_lines);
    try expectEqual(@as(usize, 1), patch.files[1].removed_lines);
    // A source line with a Git header prefix must not become another file section.
    try expect(std.mem.indexOf(u8, patch.files[1].raw, "+  // diff --git a/fake b/fake") != null);
    try expectEqual(@as(usize, 0), patch.files[0].start);
    try expectEqual(source.len, patch.files[1].end);
    // Exact source slices keep the caller's raw fallback available after parsing.
    for (patch.files) |file| try expectEqualStrings(source[file.start..file.end], file.raw);
}

test "Git change kinds retain selectable additions deletions renames binary and mode changes" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "kinds.patch");
    try expectEqual(@as(usize, 5), patch.files.len);
    try expectEqual(ChangeKind.deleted, patch.files[0].kind);
    try expectEqual(@as(?[]const u8, null), patch.files[0].new_path);
    try expectEqual(ChangeKind.mode_only, patch.files[1].kind);
    // A mode-only section has no changed source lines to report in the header.
    try expectEqual(@as(usize, 0), patch.files[1].added_lines);
    try expectEqual(@as(usize, 0), patch.files[1].removed_lines);
    try expectEqual(ChangeKind.added, patch.files[2].kind);
    try expectEqual(@as(?[]const u8, null), patch.files[2].old_path);
    try expectEqual(ChangeKind.renamed, patch.files[3].kind);
    try expectEqualStrings("Assets/Rename.prefab", patch.files[3].old_path.?);
    try expectEqualStrings("Assets/Renamed.prefab", patch.files[3].new_path.?);
    try expectEqual(ChangeKind.binary, patch.files[4].kind);
    try expectEqualStrings("Image.png", patch.files[4].display_path);
}

test "line counts include every hunk and ignore newline markers" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "hunks.patch");
    // Both separated changes belong to one file; newline markers are not source lines.
    try expectEqual(@as(usize, 3), patch.files[0].added_lines);
    try expectEqual(@as(usize, 2), patch.files[0].removed_lines);
}

test "Git C quoted paths decode spaces quotes tabs and Unicode" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "paths.patch");
    try expectEqual(@as(usize, 4), patch.files.len);
    // Mode-only patches have no ---/+++ lines to correct a misread diff header.
    try expectEqualStrings("dir b/Mode.cs", patch.files[0].display_path);
    try expectEqualStrings("quote\"tab\t.cs", patch.files[1].display_path);
    try expectEqualStrings("space name.cs", patch.files[2].display_path);
    try expectEqualStrings("日本語.prefab", patch.files[3].display_path);
}

test "renamed Git path may quote only one side" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "mixed_rename.patch");
    try expectEqual(@as(usize, 1), patch.files.len);
    try expectEqual(ChangeKind.renamed, patch.files[0].kind);
    try expectEqualStrings("日本語.cs", patch.files[0].old_path.?);
    try expectEqualStrings("Plain.cs", patch.files[0].new_path.?);
    const reverse = try parseFixture(memory.allocator(), "mixed_rename_reverse.patch");
    try expectEqual(@as(usize, 1), reverse.files.len);
    try expectEqual(ChangeKind.renamed, reverse.files[0].kind);
    try expectEqualStrings("Plain.cs", reverse.files[0].old_path.?);
    try expectEqualStrings("日本語.cs", reverse.files[0].new_path.?);
}

test "rename metadata resolves an ambiguous unquoted diff header" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "ambiguous_rename.patch");
    try expectEqual(@as(usize, 1), patch.files.len);
    // The first b/ separator also occurs inside the old path, so the header alone is ambiguous.
    try expectEqualStrings("dir b/Old.cs", patch.files[0].old_path.?);
    try expectEqualStrings("New.cs", patch.files[0].new_path.?);
    try expectEqual(ChangeKind.renamed, patch.files[0].kind);
}

test "hunk content cannot replace file metadata" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "metadata_hunk.patch");
    try expectEqual(@as(usize, 1), patch.files.len);
    // Git prefixes source lines with -/+; source text can then look like ---/+++ headers.
    try expectEqualStrings("Actual.cs", patch.files[0].old_path.?);
    try expectEqualStrings("Actual.cs", patch.files[0].new_path.?);
    try expectEqualStrings("Actual.cs", patch.files[0].display_path);
}

test "colored Git headers parse without changing their original bytes" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const source = @embedFile("fixtures/colored.patch");
    const patch = try parse(memory.allocator(), source);
    try expectEqual(@as(usize, 2), patch.files.len);
    try expectEqualStrings("Assets/A.prefab", patch.files[0].display_path);
    try expect(std.mem.indexOf(u8, patch.files[0].raw, "\x1b[") != null);
    for (patch.files) |file| try expectEqualStrings(source[file.start..file.end], file.raw);
}

test "malformed and combined input remains available as raw text" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    for ([_][]const u8{ "not a patch\n", "diff --cc File.cs\n@@@ -1,1 -1,1 +1,1 @@@\n" }) |source| {
        const patch = try parse(memory.allocator(), source);
        try expectEqual(@as(usize, 0), patch.files.len);
        try expectEqualStrings(source, patch.raw_fallback.?);
    }
}
