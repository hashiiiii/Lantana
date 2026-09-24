const std = @import("std");
const Repo = @import("git_repo.zig").Repo;
const pager_path = @import("test_options").pager_path;

const c = @cImport({
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cDefine("NTDDI_VERSION", "0x0A000006");
    @cInclude("windows.h");
});

const Result = struct {
    transcript: []const u8,
    exit_code: c.DWORD,
    sent_quit: bool,
};

fn writePipe(handle: c.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: c.DWORD = 0;
        if (c.WriteFile(handle, bytes.ptr + offset, @intCast(bytes.len - offset), &written, null) == 0 or written == 0)
            return error.ConPtyWriteFailed;
        offset += written;
    }
}

fn visibleText(arena: std.mem.Allocator, transcript: []const u8) ![]const u8 {
    var visible: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < transcript.len) {
        if (transcript[index] == 0x1b and index + 1 < transcript.len and transcript[index + 1] == '[') {
            index += 2;
            while (index < transcript.len and !(transcript[index] >= 0x40 and transcript[index] <= 0x7e)) index += 1;
            if (index < transcript.len) index += 1;
            continue;
        }
        try visible.append(arena, transcript[index]);
        index += 1;
    }
    return visible.toOwnedSlice(arena);
}

fn runConPty(arena: std.mem.Allocator, io: std.Io, repo: *Repo) !Result {
    var input_read: c.HANDLE = null;
    var input_write: c.HANDLE = null;
    var output_read: c.HANDLE = null;
    var output_write: c.HANDLE = null;
    if (c.CreatePipe(&input_read, &input_write, null, 0) == 0) return error.ConPtyPipeFailed;
    defer {
        if (input_read != null) _ = c.CloseHandle(input_read);
        if (input_write != null) _ = c.CloseHandle(input_write);
    }
    if (c.CreatePipe(&output_read, &output_write, null, 0) == 0) return error.ConPtyPipeFailed;
    defer {
        if (output_read != null) _ = c.CloseHandle(output_read);
        if (output_write != null) _ = c.CloseHandle(output_write);
    }

    var pseudoconsole: c.HPCON = null;
    const console_result = c.CreatePseudoConsole(.{ .X = 80, .Y = 24 }, input_read, output_write, 0, &pseudoconsole);
    if (console_result != 0) {
        std.log.err("CreatePseudoConsole failed: {x}", .{@as(u32, @bitCast(console_result))});
        return error.CreatePseudoConsoleFailed;
    }
    defer c.ClosePseudoConsole(pseudoconsole);
    var attribute_bytes: usize = 0;
    // The first call reports the opaque list's required size by failing.
    _ = c.InitializeProcThreadAttributeList(null, 1, 0, &attribute_bytes);
    const storage = try arena.alignedAlloc(u8, .of(usize), attribute_bytes);
    const attributes: c.LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(storage.ptr);
    if (c.InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes) == 0)
        return error.InitializeAttributesFailed;
    defer c.DeleteProcThreadAttributeList(attributes);
    if (c.UpdateProcThreadAttribute(
        attributes,
        0,
        c.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        pseudoconsole,
        @sizeOf(c.HPCON),
        null,
        null,
    ) == 0) return error.UpdateAttributesFailed;

    var startup: c.STARTUPINFOEXW = std.mem.zeroes(c.STARTUPINFOEXW);
    startup.StartupInfo.cb = @sizeOf(c.STARTUPINFOEXW);
    startup.lpAttributeList = attributes;
    var process: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
    const command = try std.unicode.utf8ToUtf16LeAllocZ(arena, "git.exe --paginate diff");
    const directory = try std.unicode.utf8ToUtf16LeAllocZ(arena, repo.path);
    if (c.CreateProcessW(
        null,
        command.ptr,
        null,
        null,
        0,
        c.EXTENDED_STARTUPINFO_PRESENT,
        null,
        directory.ptr,
        &startup.StartupInfo,
        &process,
    ) == 0) {
        std.log.err("CreateProcessW failed: {d}", .{c.GetLastError()});
        return error.ConPtyProcessFailed;
    }
    defer _ = c.CloseHandle(process.hProcess);
    defer _ = c.CloseHandle(process.hThread);
    var exited = false;
    defer {
        if (!exited) {
            _ = c.TerminateProcess(process.hProcess, 1);
            _ = c.WaitForSingleObject(process.hProcess, 5000);
        }
    }
    // Keeping the host copies open prevents broken-pipe detection after Git exits.
    _ = c.CloseHandle(input_read);
    input_read = null;
    _ = c.CloseHandle(output_write);
    output_write = null;

    var transcript: std.ArrayList(u8) = .empty;
    var replies: [3]usize = .{ 0, 0, 0 };
    const queries = [_][]const u8{ "\x1b[6n", "\x1b[?u", "\x1b[5n" };
    const answers = [_][]const u8{ "\x1b[1;1R", "\x1b[?0u\x1b[?1;2c", "\x1b[0n" };
    var sent_quit = false;
    const deadline = std.Io.Clock.now(.awake, io).nanoseconds + 20 * std.time.ns_per_s;
    while (std.Io.Clock.now(.awake, io).nanoseconds < deadline) {
        var available: c.DWORD = 0;
        if (c.PeekNamedPipe(output_read, null, 0, null, &available, null) != 0 and available > 0) {
            var buffer: [65536]u8 = undefined;
            var count: c.DWORD = 0;
            if (c.ReadFile(output_read, &buffer, @min(available, buffer.len), &count, null) == 0)
                return error.ConPtyReadFailed;
            try transcript.appendSlice(arena, buffer[0..count]);
            for (queries, answers, 0..) |query, answer, index| {
                const found = std.mem.count(u8, transcript.items, query);
                while (replies[index] < found) : (replies[index] += 1) try writePipe(input_write, answer);
            }
            if (!sent_quit) {
                const visible = try visibleText(arena, transcript.items);
                if (std.mem.indexOf(u8, visible, "Before (-)") != null and
                    std.mem.indexOf(u8, visible, "Example.cs") != null)
                {
                    try writePipe(input_write, "q");
                    sent_quit = true;
                }
            }
        }
        if (c.WaitForSingleObject(process.hProcess, 0) == c.WAIT_OBJECT_0 and
            std.mem.indexOf(u8, transcript.items, "\x1b[?1049l") != null)
        {
            var exit_code: c.DWORD = undefined;
            if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0) return error.ConPtyExitCodeFailed;
            exited = true;
            return .{ .transcript = try transcript.toOwnedSlice(arena), .exit_code = exit_code, .sent_quit = sent_quit };
        }
        c.Sleep(10);
    }
    std.log.err("ConPTY timed out; output: {s}", .{transcript.items});
    return error.ConPtyTimedOut;
}

test "Git pager opens and closes a native ConPTY without changing the repository" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.write("Example.cs", "before\n");
    try repo.commit();
    try repo.write("Example.cs", "after\n");
    try repo.setPager(pager_path, false);
    const patch = try repo.git(&.{ "--no-pager", "diff" });
    try std.testing.expect(patch.len > 0);
    const status_before = try repo.git(&.{ "status", "--porcelain=v1" });
    const config_before = try repo.read(".git/config");
    const result = try runConPty(arena, std.testing.io, &repo);
    try std.testing.expect(result.sent_quit);
    try std.testing.expectEqual(@as(c.DWORD, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "\x1b[?1049l") != null);
    try std.testing.expectEqualStrings(status_before, try repo.git(&.{ "status", "--porcelain=v1" }));
    try std.testing.expectEqualStrings(config_before, try repo.read(".git/config"));
    try std.testing.expectEqualStrings("after\n", try repo.read("Example.cs"));
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, pager_path, arena);
    const empty = try std.process.run(arena, std.testing.io, .{ .argv = &.{executable} });
    try std.testing.expectEqual(@as(u8, 0), empty.term.exited);
    try std.testing.expectEqualStrings("", empty.stdout);
}
