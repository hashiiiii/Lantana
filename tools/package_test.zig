const std = @import("std");
const package = @import("package.zig");

comptime {
    // Package tests must remain discoverable when the root tests are filtered out.
    _ = package;
}

test "Homebrew formula pairs each platform URL with its archive checksum" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const hashes: package.ArchiveHashes = .{ .values = .{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" } };

    // A checksum from another platform makes Homebrew reject the downloaded archive.
    const formula = try package.homebrewFormula(arena_state.allocator(), "2.3.4", &hashes);
    try std.testing.expect(std.mem.indexOf(u8, formula, "version \"2.3.4\"") != null);
    const expected_blocks = [_][]const u8{
        "  on_macos do\n    on_arm do\n      url \"https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-macos-arm64.zip\"\n      sha256 \"" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++ "\"",
        "    on_intel do\n      url \"https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-macos-x64.zip\"\n      sha256 \"" ++ "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++ "\"",
        "  on_linux do\n    on_intel do\n      url \"https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-linux-x64.zip\"\n      sha256 \"" ++ "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" ++ "\"",
        "    on_arm do\n      url \"https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-linux-arm64.zip\"\n      sha256 \"" ++ "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" ++ "\"",
    };
    for (expected_blocks) |block| try std.testing.expect(std.mem.indexOf(u8, formula, block) != null);
    try std.testing.expect(std.mem.indexOf(u8, formula, "windows-") == null);
}

test "checksum validation rejects a changed archive hash" {
    const hashes: package.ArchiveHashes = .{ .values = .{ "a", "b", "c", "d", "e", "f" } };
    // A stale published sum must stop package rendering before metadata is regenerated.
    try std.testing.expectError(error.ChecksumMismatch, package.validateChecksumManifest(
        "a  lantana-macos-arm64.zip\n" ++
            "b  lantana-macos-x64.zip\n" ++
            "c  lantana-linux-x64.zip\n" ++
            "d  lantana-linux-arm64.zip\n" ++
            "e  lantana-windows-x64.zip\n" ++
            "wrong  lantana-windows-arm64.zip\n",
        &hashes,
    ));
}
