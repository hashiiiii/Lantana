const builtin = @import("builtin");

test {
    if (builtin.os.tag == .windows) {
        _ = @import("windows_conpty.zig");
    } else {
        _ = @import("posix_pty.zig");
    }
}
