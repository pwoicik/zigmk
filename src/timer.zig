const builtin = @import("builtin");

pub var __time: u32 = 0;

pub fn currentTime() u32 {
    if (builtin.is_test) {
        return __time;
    } else {
        const timer = @import("microzig").hal.system_timer.num(0);
        return @truncate(timer.read() / 1_000);
    }
}
