const std = @import("std");

const Cell = struct {
    bytes: [4]u8 = .{ ' ', 0, 0, 0 },
    len: u3 = 1,
};

pub const Screen = struct {
    arena: std.mem.Allocator,
    width: usize,
    height: usize,
    cells: []Cell,
    row: usize = 0,
    col: usize = 0,
    frame: usize = 0,
    alt: bool = false,
    pending: std.ArrayList(u8) = .empty,

    pub fn init(arena: std.mem.Allocator, width: usize, height: usize) !Screen {
        const cells = try arena.alloc(Cell, width * height);
        @memset(cells, .{});
        return .{ .arena = arena, .width = width, .height = height, .cells = cells };
    }

    pub fn resize(self: *Screen, width: usize, height: usize) !void {
        self.width = width;
        self.height = height;
        self.cells = try self.arena.alloc(Cell, width * height);
        @memset(self.cells, .{});
        self.row = 0;
        self.col = 0;
    }

    pub fn text(self: *Screen) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (0..self.height) |row| {
            if (row > 0) try out.append(self.arena, '\n');
            for (self.cells[row * self.width ..][0..self.width]) |cell|
                try out.appendSlice(self.arena, cell.bytes[0..cell.len]);
        }
        return out.toOwnedSlice(self.arena);
    }

    pub fn feed(self: *Screen, data: []const u8) !void {
        try self.pending.appendSlice(self.arena, data);
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const byte = self.pending.items[index];
            if (byte == 0x1b) {
                if (index + 1 >= self.pending.items.len) break;
                const next = self.pending.items[index + 1];
                if (next == '[') {
                    var end = index + 2;
                    while (end < self.pending.items.len and !(self.pending.items[end] >= 0x40 and self.pending.items[end] <= 0x7e)) end += 1;
                    if (end >= self.pending.items.len) break;
                    try self.csi(self.pending.items[index + 2 .. end], self.pending.items[end]);
                    index = end + 1;
                    continue;
                }
                if (next == ']' or next == 'P' or next == '_' or next == '^' or next == 'G') {
                    var end = index + 2;
                    var closed = false;
                    while (end < self.pending.items.len) : (end += 1) {
                        if (self.pending.items[end] == 7) {
                            end += 1;
                            closed = true;
                            break;
                        }
                        if (self.pending.items[end] == 0x1b and end + 1 < self.pending.items.len and self.pending.items[end + 1] == '\\') {
                            end += 2;
                            closed = true;
                            break;
                        }
                    }
                    if (!closed) break;
                    index = end;
                    continue;
                }
                index += 2;
                continue;
            }
            if (byte == '\r') {
                self.col = 0;
                index += 1;
                continue;
            }
            if (byte == '\n') {
                self.row = @min(self.height - 1, self.row + 1);
                index += 1;
                continue;
            }
            if (byte < 32 or byte == 127) {
                index += 1;
                continue;
            }
            const size: usize = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            if (index + size > self.pending.items.len) break;
            const slice = self.pending.items[index .. index + size];
            _ = std.unicode.utf8Decode(slice) catch {
                self.put("?");
                index += 1;
                continue;
            };
            self.put(slice);
            index += size;
        }
        std.mem.copyForwards(u8, self.pending.items, self.pending.items[index..]);
        self.pending.items.len -= index;
    }

    fn put(self: *Screen, bytes: []const u8) void {
        if (self.row < self.height and self.col < self.width) {
            const cell = &self.cells[self.row * self.width + self.col];
            @memset(&cell.bytes, 0);
            @memcpy(cell.bytes[0..bytes.len], bytes);
            cell.len = @intCast(bytes.len);
        }
        self.col += 1;
    }

    fn csi(self: *Screen, raw: []const u8, final: u8) !void {
        if (std.mem.eql(u8, raw, "?1049")) {
            if (final == 'h') {
                self.alt = true;
                try self.resize(self.width, self.height);
            } else if (final == 'l') self.alt = false;
            return;
        }
        if (std.mem.eql(u8, raw, "?2026") and final == 'l') {
            self.frame += 1;
            return;
        }
        if (raw.len > 0 and (raw[0] == '?' or raw[0] == '>')) return;
        var parts = std.mem.splitScalar(u8, raw, ';');
        const first_raw = parts.next() orelse "";
        const first = std.fmt.parseInt(usize, first_raw, 10) catch 0;
        switch (final) {
            'H', 'f' => {
                const col_raw = parts.next() orelse "";
                const column = std.fmt.parseInt(usize, col_raw, 10) catch 1;
                self.row = @min(self.height - 1, (if (first == 0) @as(usize, 1) else first) - 1);
                self.col = @min(self.width - 1, (if (column == 0) @as(usize, 1) else column) - 1);
            },
            'J' => {
                if (first == 2) {
                    try self.resize(self.width, self.height);
                } else if (first == 0) {
                    for (self.row..self.height) |row| {
                        const start = if (row == self.row) self.col else 0;
                        @memset(self.cells[row * self.width + start .. (row + 1) * self.width], .{});
                    }
                }
            },
            'K' => @memset(self.cells[self.row * self.width + self.col .. (self.row + 1) * self.width], .{}),
            else => {},
        }
    }
};

test "screen keeps only live cells across cursor moves and split control sequences" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var screen = try Screen.init(memory.allocator(), 12, 2);
    try screen.feed("\x1b[?1049h\x1b[1;1HOld");
    try screen.feed("\x1b[1;1HNew\x1b[?202");
    try screen.feed("6l");
    const text = try screen.text();
    try std.testing.expect(std.mem.indexOf(u8, text, "New") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Old") == null);
    try std.testing.expectEqual(@as(usize, 1), screen.frame);
}
