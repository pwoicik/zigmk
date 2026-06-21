const builtin = @import("builtin");

pub fn currentTime() u32 {
    if (builtin.is_test) {
        return @truncate(@import("std").time.milliTimestamp());
    } else {
        const timer = @import("microzig").hal.system_timer.num(0);
        return @truncate(timer.read() / 1_000);
    }
}
