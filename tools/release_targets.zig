const std = @import("std");

pub const ReleaseTarget = struct {
    query: []const u8,
    asset: []const u8,
    binary: []const u8,
    placeholder: []const u8,
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    abi: std.Target.Abi,
};

pub const targets = [_]ReleaseTarget{
    .{ .query = "aarch64-macos", .asset = "macos-arm64", .binary = "lantana", .placeholder = "{{SHA256_MACOS_ARM64}}", .arch = .aarch64, .os = .macos, .abi = .none },
    .{ .query = "x86_64-macos", .asset = "macos-x64", .binary = "lantana", .placeholder = "{{SHA256_MACOS_X64}}", .arch = .x86_64, .os = .macos, .abi = .none },
    .{ .query = "x86_64-linux-gnu", .asset = "linux-x64", .binary = "lantana", .placeholder = "{{SHA256_LINUX_X64}}", .arch = .x86_64, .os = .linux, .abi = .gnu },
    .{ .query = "aarch64-linux-gnu", .asset = "linux-arm64", .binary = "lantana", .placeholder = "{{SHA256_LINUX_ARM64}}", .arch = .aarch64, .os = .linux, .abi = .gnu },
    .{ .query = "x86_64-windows", .asset = "windows-x64", .binary = "lantana.exe", .placeholder = "{{SHA256_WINDOWS_X64}}", .arch = .x86_64, .os = .windows, .abi = .gnu },
    .{ .query = "aarch64-windows", .asset = "windows-arm64", .binary = "lantana.exe", .placeholder = "{{SHA256_WINDOWS_ARM64}}", .arch = .aarch64, .os = .windows, .abi = .gnu },
};

pub fn forTarget(target: std.Target) ?ReleaseTarget {
    for (targets) |candidate| {
        if (target.cpu.arch == candidate.arch and target.os.tag == candidate.os and target.abi == candidate.abi) return candidate;
    }
    return null;
}
