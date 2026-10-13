const std = @import("std");
const Repo = @import("git_repo").Repo;
const options = @import("test_options");
const pty = @import("posix_pty_support.zig");

test "PrefabLens renders semantic content in plain git diff and keeps mixed-file raw views" {
    const before =
        \\%YAML 1.1
        \\%TAG !u! tag:unity3d.com,2011:
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Component:
        \\  - component: {fileID: 2}
        \\  m_Name: Before
        \\  m_IsActive: 1
        \\--- !u!4 &2
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
        \\
    ;
    const after =
        \\%YAML 1.1
        \\%TAG !u! tag:unity3d.com,2011:
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Component:
        \\  - component: {fileID: 2}
        \\  m_Name: After
        \\  m_IsActive: 1
        \\--- !u!4 &2
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
        \\
    ;

    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    const pager = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, options.pager_path, arena);
    _ = try repo.git(&.{ "config", "pager.diff", pager });
    try repo.write("Assets/A.prefab", before);
    try repo.write("Scripts/A.cs", "class Before {}\n");
    try repo.commit();
    try repo.write("Assets/A.prefab", after);
    try repo.write("Scripts/A.cs", "class After {}\n");
    const json = try std.json.Stringify.valueAlloc(arena, .{.{
        .patterns = &.{"*.prefab"},
        .command = &.{ options.prefablens_path, "--color", "--project", "{repo}", "{before}", "{after}" },
    }}, .{});
    try repo.write(".git/xdg/lantana/renderers.json", json);
    const status = try repo.git(&.{ "status", "--porcelain=v1" });
    const config = try repo.read(".git/config");
    var session = try pty.Session.startPlainDiff(arena, std.testing.io, &repo);
    defer session.abort();
    const semantic = try session.waitFrame("After", 0);
    // The initial content must come from the actual semantic engine, not YAML or a substitute renderer.
    try std.testing.expect(std.mem.indexOf(u8, pty.bodyRows(semantic), "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, pty.bodyRows(semantic), "m_Name") == null);
    try std.testing.expect(std.mem.indexOf(u8, pty.bodyRows(semantic), "%YAML") == null);
    var mark = session.screen.frame;
    try session.send("m");
    _ = try session.waitFrame("m_Name: Before", mark);
    mark = session.screen.frame;
    try session.send("\x1b");
    _ = try session.waitFrame("A.prefab", mark);
    mark = session.screen.frame;
    try session.send("\x1b[B\x1b[B");
    _ = try session.waitFrame("class Before", mark);
    try session.finish();
    try std.testing.expectEqualStrings(status, try repo.git(&.{ "status", "--porcelain=v1" }));
    try std.testing.expectEqualStrings(config, try repo.read(".git/config"));
}
