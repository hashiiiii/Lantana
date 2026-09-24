const std = @import("std");
const Repo = @import("git_repo.zig").Repo;

fn repository(arena: std.mem.Allocator) !Repo {
    var repo = try Repo.init(arena, std.testing.io);
    _ = try repo.git(&.{ "config", "core.quotePath", "true" });
    return repo;
}

fn executable(repo: *Repo, name: []const u8) !void {
    var file = try repo.temp.dir.openFile(repo.io, name, .{ .mode = .read_write });
    defer file.close(repo.io);
    try file.setPermissions(repo.io, .executable_file);
}

fn save(repo: *Repo, name: []const u8, options: []const []const u8) !void {
    _ = try repo.git(&.{ "add", "-A" });
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(repo.arena, &.{ "diff", "--cached" });
    try args.appendSlice(repo.arena, options);
    const patch = try repo.git(args.items);
    const destination = try std.fmt.allocPrint(repo.arena, "src/fixtures/{s}", .{name});
    try std.Io.Dir.cwd().writeFile(repo.io, .{ .sub_path = destination, .data = patch });
}

test "regenerate parser fixtures from real Git output" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();

    var ordinary = try repository(arena);
    defer ordinary.deinit();
    try ordinary.write("Assets/A.prefab", "name: Before\ncount: 1\n");
    try ordinary.write("Scripts/A.cs", "class A {}\n");
    try ordinary.commit();
    try ordinary.write("Assets/A.prefab", "name: After\ncount: 1\n");
    try ordinary.write("Scripts/A.cs", "class A {\n  // diff --git a/fake b/fake\n}\n");
    try save(&ordinary, "ordinary.patch", &.{});

    var kinds = try repository(arena);
    defer kinds.deinit();
    try kinds.write("Assets/Delete.prefab", "deleted\n");
    try kinds.write("Assets/Rename.prefab", "same content\n");
    try kinds.write("Assets/Mode.cs", "mode only\n");
    try kinds.write("Image.png", "\x89PNG\x00before");
    try kinds.commit();
    try kinds.temp.dir.deleteFile(kinds.io, "Assets/Delete.prefab");
    try kinds.temp.dir.rename("Assets/Rename.prefab", kinds.temp.dir, "Assets/Renamed.prefab", kinds.io);
    try executable(&kinds, "Assets/Mode.cs");
    try kinds.write("Assets/New.meta", "guid: abc\n");
    try kinds.write("Image.png", "\x89PNG\x00after");
    try save(&kinds, "kinds.patch", &.{"--find-renames"});

    var paths = try repository(arena);
    defer paths.deinit();
    for ([_][]const u8{ "space name.cs", "quote\"tab\t.cs", "日本語.prefab" }) |name|
        try paths.write(name, "before\n");
    try paths.write("dir b/Mode.cs", "mode only\n");
    try paths.commit();
    for ([_][]const u8{ "space name.cs", "quote\"tab\t.cs", "日本語.prefab" }) |name|
        try paths.write(name, "after\n");
    try executable(&paths, "dir b/Mode.cs");
    try save(&paths, "paths.patch", &.{});

    var rename = try repository(arena);
    defer rename.deinit();
    try rename.write("日本語.cs", "same content\n");
    try rename.commit();
    try rename.temp.dir.rename("日本語.cs", rename.temp.dir, "Plain.cs", rename.io);
    try save(&rename, "mixed_rename.patch", &.{"--find-renames"});

    var reverse = try repository(arena);
    defer reverse.deinit();
    try reverse.write("Plain.cs", "same content\n");
    try reverse.commit();
    try reverse.temp.dir.rename("Plain.cs", reverse.temp.dir, "日本語.cs", reverse.io);
    try save(&reverse, "mixed_rename_reverse.patch", &.{"--find-renames"});

    var ambiguous = try repository(arena);
    defer ambiguous.deinit();
    try ambiguous.write("dir b/Old.cs", "same content\n");
    try ambiguous.commit();
    try ambiguous.temp.dir.rename("dir b/Old.cs", ambiguous.temp.dir, "New.cs", ambiguous.io);
    try save(&ambiguous, "ambiguous_rename.patch", &.{"--find-renames"});

    var metadata = try repository(arena);
    defer metadata.deinit();
    try metadata.write("Actual.cs", "-- a/wrong-old.cs\n");
    try metadata.commit();
    try metadata.write("Actual.cs", "++ b/wrong-new.cs\n");
    try save(&metadata, "metadata_hunk.patch", &.{});

    var hunks = try repository(arena);
    defer hunks.deinit();
    try hunks.write("Script.cs", "zero\none\ntwo\n\nfour\nfive\nsix\nseven\neight\nnine");
    try hunks.commit();
    try hunks.write("Script.cs", "zero\nONE\nextra\ntwo\n\nfour\nfive\nsix\nseven\neight\nNINE");
    try save(&hunks, "hunks.patch", &.{"--unified=2"});

    const colored = try ordinary.git(&.{ "-c", "color.ui=always", "diff", "--cached", "--color=always" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "src/fixtures/colored.patch", .data = colored });
}
