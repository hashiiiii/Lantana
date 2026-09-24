const std = @import("std");
const git_patch = @import("git_patch.zig");
const raw_split = @import("raw_split.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

pub const FileMetadata = struct {
    patch: []const u8,
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    old_blob: ?[]const u8,
    new_blob: ?[]const u8,
};

pub const Document = union(enum) {
    text: []const u8,
    unavailable: []const u8,
};

pub const DocumentRenderer = struct {
    context: ?*anyopaque = null,
    render: *const fn (?*anyopaque, std.mem.Allocator, FileMetadata) anyerror!Document,
};

pub const Mode = enum { raw, document };
pub const NodeKind = enum { folder, file };

pub const Scroll = struct { vertical: usize = 0, horizontal: usize = 0 };

pub const FileState = struct {
    rendered: bool = false,
    mode: Mode = .raw,
    document: ?[]const u8 = null,
    unavailable_reason: ?[]const u8 = null,
    raw_rows: ?[]raw_split.PairRow = null,
    raw_scroll: Scroll = .{},
    document_scroll: Scroll = .{},
};

pub const Node = struct {
    kind: NodeKind,
    path: []const u8,
    name: []const u8,
    depth: usize,
    file_index: ?usize = null,
    expanded: bool = true,
};

pub const Review = struct {
    arena: std.mem.Allocator,
    patch: git_patch.Patch,
    files: []git_patch.FileEntry,
    states: []FileState,
    nodes: []Node,
    renderer: ?DocumentRenderer,
    selected: ?usize = null,

    pub fn init(arena: std.mem.Allocator, patch: git_patch.Patch, renderer: ?DocumentRenderer) !Review {
        const extra: usize = @intFromBool(patch.raw_fallback != null or patch.prelude.len != 0);
        const files = try arena.alloc(git_patch.FileEntry, patch.files.len + extra);
        var offset: usize = 0;
        if (extra != 0) {
            const raw = patch.raw_fallback orelse patch.prelude;
            files[0] = .{
                .raw = raw,
                .start = 0,
                .end = raw.len,
                .display_path = if (patch.raw_fallback != null) "(raw patch)" else "(patch prelude)",
                .old_path = null,
                .new_path = null,
                .kind = .unsupported,
            };
            offset = 1;
        }
        @memcpy(files[offset..], patch.files);
        const states = try arena.alloc(FileState, files.len);
        @memset(states, .{});

        const sorted = try arena.alloc(usize, files.len);
        for (sorted, 0..) |*slot, index| slot.* = index;
        std.mem.sort(usize, sorted, files, struct {
            fn lessThan(entries: []git_patch.FileEntry, left: usize, right: usize) bool {
                const order = std.mem.order(u8, entries[left].display_path, entries[right].display_path);
                return order == .lt or (order == .eq and left < right);
            }
        }.lessThan);

        var nodes: std.ArrayList(Node) = .empty;
        for (sorted) |file_index| {
            const path = files[file_index].display_path;
            var parts = std.mem.splitScalar(u8, path, '/');
            var cursor: usize = 0;
            var depth: usize = 0;
            while (parts.next()) |name| {
                const end = cursor + name.len;
                if (end < path.len) {
                    const folder_path = path[0..end];
                    if (!hasFolder(nodes.items, folder_path)) try nodes.append(arena, .{
                        .kind = .folder,
                        .path = folder_path,
                        .name = name,
                        .depth = depth,
                    });
                    depth += 1;
                } else {
                    try nodes.append(arena, .{
                        .kind = .file,
                        .path = path,
                        .name = name,
                        .depth = depth,
                        .file_index = file_index,
                    });
                }
                cursor = end + 1;
            }
        }

        var self: Review = .{
            .arena = arena,
            .patch = patch,
            .files = files,
            .states = states,
            .nodes = try nodes.toOwnedSlice(arena),
            .renderer = renderer,
        };
        if (self.nodes.len > 0) for (self.nodes) |node| {
            if (node.file_index) |index| {
                try self.selectFile(index);
                break;
            }
        };
        return self;
    }

    pub fn currentFile(self: *const Review) ?git_patch.FileEntry {
        return if (self.selected) |index| self.files[index] else null;
    }

    pub fn currentState(self: *Review) ?*FileState {
        return if (self.selected) |index| &self.states[index] else null;
    }

    pub fn selectFile(self: *Review, index: usize) !void {
        if (index >= self.files.len) return error.InvalidFileIndex;
        self.selected = index;
        const state = &self.states[index];
        if (state.rendered) return;
        state.rendered = true;
        const renderer = self.renderer orelse {
            state.unavailable_reason = "Document renderer not configured";
            return;
        };
        const file = self.files[index];
        const document = renderer.render(renderer.context, self.arena, .{
            .patch = file.raw,
            .old_path = file.old_path,
            .new_path = file.new_path,
            .old_blob = file.old_blob,
            .new_blob = file.new_blob,
        }) catch |err| {
            state.unavailable_reason = @errorName(err);
            return;
        };
        switch (document) {
            .text => |text| {
                state.document = text;
                state.mode = .document;
            },
            .unavailable => |reason| state.unavailable_reason = reason,
        }
    }

    pub fn currentRows(self: *Review) ![]raw_split.PairRow {
        const index = self.selected orelse return error.NoSelectedFile;
        const state = &self.states[index];
        if (state.raw_rows == null) state.raw_rows = try raw_split.rows(self.arena, self.files[index]);
        return state.raw_rows.?;
    }

    pub fn toggleMode(self: *Review) void {
        const state = self.currentState() orelse return;
        if (state.document == null) return;
        state.mode = if (state.mode == .document) .raw else .document;
    }

    pub fn scrollDown(self: *Review, count: usize) void {
        const state = self.currentState() orelse return;
        const scroll = if (state.mode == .document) &state.document_scroll else &state.raw_scroll;
        scroll.vertical +|= count;
    }

    pub fn scrollUp(self: *Review, count: usize) void {
        const state = self.currentState() orelse return;
        const scroll = if (state.mode == .document) &state.document_scroll else &state.raw_scroll;
        scroll.vertical -|= count;
    }

    pub fn panRight(self: *Review, count: usize) void {
        const state = self.currentState() orelse return;
        const scroll = if (state.mode == .document) &state.document_scroll else &state.raw_scroll;
        scroll.horizontal +|= count;
    }

    pub fn panLeft(self: *Review, count: usize) void {
        const state = self.currentState() orelse return;
        const scroll = if (state.mode == .document) &state.document_scroll else &state.raw_scroll;
        scroll.horizontal -|= count;
    }

    pub fn toggleFolder(self: *Review, node_index: usize) !void {
        if (node_index >= self.nodes.len or self.nodes[node_index].kind != .folder) return error.InvalidFolderIndex;
        self.nodes[node_index].expanded = !self.nodes[node_index].expanded;
        if (self.selected) |selected| {
            if (self.isFileVisible(selected)) return;
        }
        self.selected = null;
        for (self.nodes, 0..) |node, index| {
            if (node.file_index) |file_index| {
                if (self.isNodeVisible(index)) {
                    try self.selectFile(file_index);
                    break;
                }
            }
        }
    }

    pub fn visibleNodes(self: *const Review, arena: std.mem.Allocator) ![]usize {
        var output: std.ArrayList(usize) = .empty;
        for (self.nodes, 0..) |_, index| if (self.isNodeVisible(index)) try output.append(arena, index);
        return output.toOwnedSlice(arena);
    }

    pub fn moveDown(self: *Review) !void {
        try self.move(1);
    }

    pub fn moveUp(self: *Review) !void {
        try self.move(-1);
    }

    fn move(self: *Review, direction: isize) !void {
        var previous: ?usize = null;
        var selected_seen = false;
        for (self.nodes, 0..) |node, index| {
            const file_index = node.file_index orelse continue;
            if (!self.isNodeVisible(index)) continue;
            if (self.selected != null and file_index == self.selected.?) {
                selected_seen = true;
                if (direction < 0 and previous != null) try self.selectFile(previous.?);
                continue;
            }
            if (direction > 0 and selected_seen) {
                try self.selectFile(file_index);
                return;
            }
            previous = file_index;
        }
    }

    fn isFileVisible(self: *const Review, file_index: usize) bool {
        for (self.nodes, 0..) |node, index| {
            if (node.file_index != null and node.file_index.? == file_index) return self.isNodeVisible(index);
        }
        return false;
    }

    fn isNodeVisible(self: *const Review, node_index: usize) bool {
        const path = self.nodes[node_index].path;
        for (self.nodes) |folder| {
            if (folder.kind != .folder or folder.expanded) continue;
            if (path.len > folder.path.len and std.mem.startsWith(u8, path, folder.path) and path[folder.path.len] == '/') return false;
        }
        return true;
    }
};

fn hasFolder(nodes: []const Node, path: []const u8) bool {
    for (nodes) |node| if (node.kind == .folder and std.mem.eql(u8, node.path, path)) return true;
    return false;
}

fn renderPatchPath(_: ?*anyopaque, arena: std.mem.Allocator, file: FileMetadata) anyerror!Document {
    return .{ .text = try std.fmt.allocPrint(arena, "Document for {s}", .{file.new_path orelse file.old_path orelse "unknown"}) };
}

fn renderTextOnly(_: ?*anyopaque, arena: std.mem.Allocator, file: FileMetadata) anyerror!Document {
    if (std.mem.indexOf(u8, file.patch, "Binary files") != null) return error.BinaryDocumentUnavailable;
    return .{ .text = try std.fmt.allocPrint(arena, "{s}", .{file.new_path orelse file.old_path orelse "unknown"}) };
}

test "review tree skips folders and keeps each file mode and scroll position" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const patch = try git_patch.parse(arena, @embedFile("fixtures/ordinary.patch"));
    var view = try Review.init(arena, patch, .{ .render = renderPatchPath });
    try expectEqualStrings("Assets/A.prefab", view.currentFile().?.display_path);
    try expectEqual(Mode.document, view.currentState().?.mode);
    try expect(view.states[0].rendered);
    // Rendering the first selected file must not compute another file's document.
    try expect(!view.states[1].rendered);
    try expectEqualStrings("Assets", view.nodes[0].name);
    try expectEqual(NodeKind.folder, view.nodes[0].kind);

    view.scrollDown(3);
    view.panRight(2);
    view.toggleMode();
    view.scrollDown(5);
    try view.moveDown();
    try expectEqualStrings("Scripts/A.cs", view.currentFile().?.display_path);
    try expect(view.states[1].rendered);
    try expectEqual(Mode.document, view.currentState().?.mode);
    try view.moveUp();
    try expectEqual(Mode.raw, view.currentState().?.mode);
    try expectEqual(@as(usize, 5), view.currentState().?.raw_scroll.vertical);
    try expectEqual(@as(usize, 3), view.currentState().?.document_scroll.vertical);
    try expectEqual(@as(usize, 2), view.currentState().?.document_scroll.horizontal);

    // Hiding the selected file must choose another visible file, not a folder heading.
    try view.toggleFolder(0);
    try expectEqualStrings("Scripts/A.cs", view.currentFile().?.display_path);
    try view.moveUp();
    try expectEqualStrings("Scripts/A.cs", view.currentFile().?.display_path);
}

test "renderer error keeps the original binary patch in raw mode" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const patch = try git_patch.parse(arena, @embedFile("fixtures/kinds.patch"));
    var view = try Review.init(arena, patch, .{ .render = renderTextOnly });
    try view.selectFile(4);
    try expectEqual(Mode.raw, view.currentState().?.mode);
    try expectEqualStrings("BinaryDocumentUnavailable", view.currentState().?.unavailable_reason.?);
    const raw = try view.currentRows();
    try expectEqual(raw_split.RowKind.fallback, raw[0].kind);
    try expect(std.mem.indexOf(u8, view.currentFile().?.raw, "Binary files") != null);
}
