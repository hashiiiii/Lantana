const std = @import("std");
const package = @import("package.zig");

test "Homebrew formula pairs each platform URL with its archive checksum" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const hashes: package.ArchiveHashes = .{ .values = .{ "a" ** 64, "b" ** 64, "c" ** 64, "d" ** 64, "e" ** 64, "f" ** 64 } };

    // A checksum from another platform makes Homebrew reject the downloaded archive.
    const formula = try package.homebrewFormula(arena_state.allocator(), "2.3.4", &hashes);
    try std.testing.expect(std.mem.indexOf(u8, formula, "version \"2.3.4\"") != null);
    const expected_blocks = [_][]const u8{
        "  on_macos do\n    on_arm do\n      url \"https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-macos-arm64.zip\"\n      sha256 \"" ++ "a" ** 64 ++ "\"",
        "    on_intel do\n      url \"https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-macos-x64.zip\"\n      sha256 \"" ++ "b" ** 64 ++ "\"",
        "  on_linux do\n    on_intel do\n      url \"https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-linux-x64.zip\"\n      sha256 \"" ++ "c" ** 64 ++ "\"",
        "    on_arm do\n      url \"https://github.com/hashiiiii/Lantana/releases/download/v#{version}/lantana-linux-arm64.zip\"\n      sha256 \"" ++ "d" ** 64 ++ "\"",
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
