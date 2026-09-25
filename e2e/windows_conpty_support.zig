const std = @import("std");
const Repo = @import("git_repo").Repo;

const c = @cImport({
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cDefine("NTDDI_VERSION", "0x0A000006");
    @cInclude("windows.h");
});

pub const Result = struct {
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

const EnvironmentEntry = struct {
    key: []const u8,
    value: []const u8,
    wide_key: []const u16,
};

fn environmentLessThan(_: void, left: EnvironmentEntry, right: EnvironmentEntry) bool {
    return c.CompareStringOrdinal(
        left.wide_key.ptr,
        @intCast(left.wide_key.len),
        right.wide_key.ptr,
        @intCast(right.wide_key.len),
        1,
    ) == c.CSTR_LESS_THAN;
}

fn childEnvironment(arena: std.mem.Allocator) !std.process.Environ.WindowsBlock {
    const current: std.process.Environ = .{ .block = std.process.Environ.GlobalBlock.global };
    var map = try current.createMap(arena);
    defer map.deinit();
    // Git honors these variables ahead of core.pager, so inherited values could bypass the pager under test.
    _ = map.orderedRemove("GIT_PAGER");
    _ = map.orderedRemove("PAGER");
    try map.put("TERM", "xterm-256color");
    const entries = try arena.alloc(EnvironmentEntry, map.count());
    for (map.keys(), map.values(), entries) |key, value, *entry| {
        entry.* = .{ .key = key, .value = value, .wide_key = try std.unicode.wtf8ToWtf16LeAlloc(arena, key) };
    }
    // CreateProcessW requires the supplied environment block to be sorted by variable name.
    std.mem.sort(EnvironmentEntry, entries, {}, environmentLessThan);
    var sorted = std.process.Environ.Map.init(arena);
    defer sorted.deinit();
    for (entries) |entry| try sorted.put(entry.key, entry.value);
    return sorted.createWindowsBlock(arena, .{});
}

fn drainPipe(handle: c.HANDLE) void {
    var bytes: [8192]u8 = undefined;
    var count: c.DWORD = 0;
    while (c.ReadFile(handle, &bytes, bytes.len, &count, null) != 0 and count > 0) {}
}

fn closePseudoConsole(pseudoconsole: c.HPCON, output_read: *c.HANDLE, output_write: *c.HANDLE) void {
    if (output_write.* != null) {
        _ = c.CloseHandle(output_write.*);
        output_write.* = null;
    }
    // Closing ConPTY can emit a final frame and block until its output pipe is drained.
    const reader = std.Thread.spawn(.{}, drainPipe, .{output_read.*}) catch {
        _ = c.CloseHandle(output_read.*);
        output_read.* = null;
        c.ClosePseudoConsole(pseudoconsole);
        return;
    };
    c.ClosePseudoConsole(pseudoconsole);
    reader.join();
}

pub fn runConPty(arena: std.mem.Allocator, io: std.Io, repo: *Repo) !Result {
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
    defer closePseudoConsole(pseudoconsole, &output_read, &output_write);
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
    const environment = try childEnvironment(arena);
    const launch = blk: {
        const standard_kinds = [_]c.DWORD{ c.STD_INPUT_HANDLE, c.STD_OUTPUT_HANDLE, c.STD_ERROR_HANDLE };
        var standard_handles: [standard_kinds.len]c.HANDLE = undefined;
        for (standard_kinds, &standard_handles) |kind, *handle| handle.* = c.GetStdHandle(kind);
        defer for (standard_kinds, standard_handles) |kind, handle| {
            _ = c.SetStdHandle(kind, handle);
        };
        // A redirected test runner can pass its pipe handles to Git despite the attached ConPTY.
        // Clearing them lets Windows fill Git's standard handles from its new console.
        for (standard_kinds) |kind| {
            if (c.SetStdHandle(kind, null) == 0) return error.ClearStandardHandleFailed;
        }
        const started = c.CreateProcessW(
            null,
            command.ptr,
            null,
            null,
            0,
            c.EXTENDED_STARTUPINFO_PRESENT | c.CREATE_UNICODE_ENVIRONMENT,
            @ptrCast(@constCast(environment.slice.ptr)),
            directory.ptr,
            &startup.StartupInfo,
            &process,
        );
        break :blk .{ .started = started != 0, .error_code = if (started == 0) c.GetLastError() else @as(c.DWORD, 0) };
    };
    if (!launch.started) {
        std.log.err("CreateProcessW failed: {d}", .{launch.error_code});
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
