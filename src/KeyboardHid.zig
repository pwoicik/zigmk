const std = @import("std");
const microzig = @import("microzig");
const usb = microzig.core.usb;
const hal = microzig.hal;
const time = hal.time;
const peripherals = microzig.chip.peripherals;

const Self = @This();

pub const Modifiers = packed struct(u8) {
    lctrl: bool,
    lshift: bool,
    lalt: bool,
    lgui: bool,
    rctrl: bool,
    rshift: bool,
    ralt: bool,
    rgui: bool,

    pub const none: @This() = @bitCast(@as(u8, 0));
};

pub const ScanCode = enum(u8) {
    // Codes taken from https://gist.github.com/mildsunrise/4e231346e2078f440969cdefb6d4caa3
    // zig fmt: off
        reserved = 0x00, error_roll_over, post_fail, error_undefined,
        a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
        top_1, top_2, top_3, top_4, top_5, top_6, top_7, top_8, top_9, top_0,
        enter, escape, delete, tab, space,
        @"-", @"=", @"[", @"]", @"\\", @"non_us_#", @";", @"'", @"`", @",", @".", @"/",
        caps_lock,
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
        print_screen, scroll_lock, pause, insert, home, page_up, delete_forward, end, page_down,
        right_arrow, left_arrow, down_arrow, up_arrow, num_lock,
        kpad_div, kpad_mul, kpad_sub, kpad_add, kpad_enter,
        kpad_1, kpad_2, kpad_3, kpad_4, kpad_5, kpad_6, kpad_7, kpad_8, kpad_9, kpad_0,
        kpad_delete, @"non_us_\\", application, power, @"kpad_=",
        f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24,
        lctrl = 224, lshift, lalt, lgui, rctrl, rshift, ralt, rgui,
        // zig fmt: on
    _,
};

pub const InReport = extern struct {
    modifiers: Modifiers,
    reserved: u8 = 0,
    keys: [6]ScanCode,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 8);
    }

    pub const empty: @This() = .{
        .modifiers = .none,
        .keys = @splat(.reserved),
    };
};

pub const OutReport = packed struct(u8) {
    num_lock: bool,
    caps_lock: bool,
    scroll_lock: bool,
    padding: u5 = 0,
};

usb_ctrl: UsbController,
usb_dev: UsbDevice,

pub fn init() Self {
    return .{
        .usb_ctrl = .init,
        .usb_dev = .init(),
    };
}

pub fn isPluggedIn(_: *const Self) bool {
    var attempts: u32 = 0;
    while (attempts < 25_000) : (attempts += 1) {
        const sie_status = peripherals.USB.SIE_STATUS.read();
        if (sie_status.CONNECTED == 1) {
            return true;
        }
        time.sleep_us(10);
    }
    return false;
}

pub inline fn poll(self: *Self) void {
    self.usb_dev.poll(&self.usb_ctrl);
}

pub inline fn sendReport(self: *Self, report: *const InReport) bool {
    if (self.drivers()) |d| {
        @branchHint(.likely);
        return d.keyboard.send_report(report);
    }
    return false;
}

pub inline fn receive_report(self: *Self) ?OutReport {
    if (self.drivers()) |d| {
        @branchHint(.likely);
        return d.keyboard.receive_report();
    }
    return null;
}

inline fn drivers(self: *Self) ?*KeyboardDrivers {
    return self.usb_ctrl.drivers();
}

const UsbDevice = hal.usb.Polled(.{});

const Keyboard = usb.drivers.hid.InterruptDriver(.{
    .subclass = .Boot,
    .protocol = .Boot,
    .InReport = InReport,
    .OutReport = OutReport,
    .report_descriptor = &.{
        .{ .global_usage_page = .generic_desktop },
        .local_usage_enum(.{ .generic_desktop = .keyboard }),
        .{ .main_collection = .Application },
        .{
            .data = .{
                .usage = .{ .global_page = .keyboard },
                .usage_range = .{ 0xE0, 0xE7 },
                .count = 8,
                .Child = bool,
                .dir = .In,
                .type = .dynamic,
            },
        },
        .{ .data_static = .{ .In, u8 } },
        .{
            .data = .{
                .usage = .{ .global_page = .led },
                .usage_range = .{ 1, 5 },
                .count = 5,
                .Child = bool,
                .dir = .Out,
                .type = .dynamic,
            },
        },
        .{ .data_static = .{ .Out, u3 } },
        .{
            .data = .{
                .usage = .{ .global_page = .keyboard },
                .usage_range = .{ 0x00, 0xFF },
                .count = 6,
                .Child = u8,
                .dir = .In,
                .type = .selector,
            },
        },
        .main_collection_end,
    },
});

const KeyboardDrivers = struct {
    keyboard: Keyboard,
    reset: hal.usb.ResetDriver(null, 0),
};

const UsbController = usb.DeviceController(
    .{
        .bcd_usb = UsbDevice.max_supported_bcd_usb,
        .device_triple = .unspecified,
        .vendor = UsbDevice.default_vendor_id,
        .product = UsbDevice.default_product_id,
        .bcd_device = .v2_00,
        .serial = "1",
        .max_supported_packet_size = UsbDevice.max_supported_packet_size,
        .configurations = &.{
            .{
                .Drivers = KeyboardDrivers,
                .attributes = .{ .self_powered = false },
                .max_current_ma = 50,
            },
        },
    },
    .{.{
        .keyboard = .{ .itf_string = "Boot Keyboard", .poll_interval = 1 },
        .reset = "",
    }},
);
