const windows = @import("std").os.windows;
const OVERLAPPED = opaque {};

pub const DWORD = windows.DWORD;
pub const HANDLE = ?windows.HANDLE;
pub const HPCON = HANDLE;
pub const LPPROC_THREAD_ATTRIBUTE_LIST = *opaque {};
pub const PROCESS_INFORMATION = windows.PROCESS.INFORMATION;
pub const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST,
};

pub const STD_INPUT_HANDLE: DWORD = 0xfffffff6;
pub const STD_OUTPUT_HANDLE: DWORD = 0xfffffff5;
pub const STD_ERROR_HANDLE: DWORD = 0xfffffff4;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const CSTR_LESS_THAN = 1;

pub const CreateProcessW = windows.kernel32.CreateProcessW;

pub extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, attributes: ?*windows.SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn ReadFile(handle: HANDLE, buffer: [*]u8, size: DWORD, read: *DWORD, overlapped: ?*OVERLAPPED) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn WriteFile(handle: HANDLE, buffer: [*]const u8, size: DWORD, written: *DWORD, overlapped: ?*OVERLAPPED) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn PeekNamedPipe(handle: HANDLE, buffer: ?[*]u8, size: DWORD, read: ?*DWORD, available: ?*DWORD, left: ?*DWORD) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn CreatePseudoConsole(size: windows.COORD, input: HANDLE, output: HANDLE, flags: DWORD, console: *HPCON) callconv(.winapi) i32;
pub extern "kernel32" fn ClosePseudoConsole(console: HPCON) callconv(.winapi) void;
pub extern "kernel32" fn InitializeProcThreadAttributeList(list: ?LPPROC_THREAD_ATTRIBUTE_LIST, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(list: LPPROC_THREAD_ATTRIBUTE_LIST) callconv(.winapi) void;
pub extern "kernel32" fn UpdateProcThreadAttribute(list: LPPROC_THREAD_ATTRIBUTE_LIST, flags: DWORD, attribute: usize, value: ?*anyopaque, size: usize, previous: ?*anyopaque, returned_size: ?*usize) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn CompareStringOrdinal(left: [*]const u16, left_len: c_int, right: [*]const u16, right_len: c_int, ignore_case: windows.BOOL) callconv(.winapi) c_int;
pub extern "kernel32" fn GetStdHandle(kind: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn SetStdHandle(kind: DWORD, handle: HANDLE) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn TerminateProcess(process: HANDLE, code: u32) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn WaitForSingleObject(handle: HANDLE, timeout_ms: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *DWORD) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn Sleep(milliseconds: DWORD) callconv(.winapi) void;
