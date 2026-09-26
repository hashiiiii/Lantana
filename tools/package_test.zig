const std = @import("std");
const package = @import("package.zig");

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
