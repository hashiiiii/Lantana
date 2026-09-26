const builtin = @import("builtin");

test {
    _ = @import("cli.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("windows_conpty.zig");
    } else {
        _ = @import("posix_pty.zig");
    }
}
