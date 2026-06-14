const std = @import("std");
const config = @import("build_config");
const microzig = @import("microzig");
const hal = microzig.hal;
const time = hal.time;
const usb = microzig.core.usb;
const UsbDevice = hal.usb.Polled(.{});

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

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

pub const Code = enum(u8) {
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

pub const KeyboardInReport = extern struct {
    modifiers: Modifiers,
    reserved: u8 = 0,
    keys: [6]Code,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 8);
    }

    pub const empty: @This() = .{ .modifiers = .none, .keys = @splat(.reserved) };
};

pub const KeyboardOutReport = packed struct(u8) {
    num_lock: bool,
    caps_lock: bool,
    scroll_lock: bool,
    padding: u5 = 0,
};

const Keyboard = usb.drivers.hid.InterruptDriver(.{
    .subclass = .Boot,
    .protocol = .Boot,
    .InReport = KeyboardInReport,
    .OutReport = KeyboardOutReport,
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

const Drivers = struct { keyboard: Keyboard, reset: hal.usb.ResetDriver(null, 0) };

const Pins = struct {
    led: hal.gpio.Pin,
    serial: SerialPins,
    rows: [4]hal.gpio.Pin,
    cols: [5]hal.gpio.Pin,
};

const SerialPins = struct {
    rx: hal.gpio.Pin,
    tx: hal.gpio.Pin,
};

fn initPins() Pins {
    _ = microzig.board.pin_config.apply();

    const pins = if (config.board == .pico2)
        Pins{
            .led = hal.gpio.num(25),
            .serial = .{
                .rx = hal.gpio.num(if (config.half == .left) 16 else 17),
                .tx = hal.gpio.num(if (config.half == .left) 17 else 16),
            },
            .rows = .{
                hal.gpio.num(6),
                hal.gpio.num(7),
                hal.gpio.num(8),
                hal.gpio.num(9),
            },
            .cols = .{
                hal.gpio.num(15),
                hal.gpio.num(11),
                hal.gpio.num(12),
                hal.gpio.num(13),
                hal.gpio.num(14),
            },
        }
    else
        Pins{
            .led = hal.gpio.num(25),
            .rows = .{
                hal.gpio.num(26),
                hal.gpio.num(27),
                hal.gpio.num(28),
                hal.gpio.num(29),
            },
            .cols = .{
                hal.gpio.num(6),
                hal.gpio.num(7),
                hal.gpio.num(3),
                hal.gpio.num(4),
                hal.gpio.num(2),
            },
        };

    pins.led.set_direction(.out);

    pins.serial.rx.set_function(.sio);
    pins.serial.rx.set_direction(.in);
    pins.serial.rx.set_pull(.up);
    pins.serial.tx.set_function(.sio);
    pins.serial.tx.set_direction(.out);
    pins.serial.rx.put(1);

    for (pins.rows) |pin| {
        pin.set_function(.sio);
        pin.set_direction(.out);
        pin.put(1);
    }
    for (pins.cols) |pin| {
        pin.set_function(.sio);
        pin.set_direction(.in);
        pin.set_pull(.up);
    }

    return pins;
}

const MATRIX = [_]Code{
    // zig fmt: off
    .b,      .l,        .d,        .c,        .v,        .j,        .f,        .o,        .u,        .@";",
    .n,      .z,        .t,        .s,        .g,        .y,        .h,        .a,        .e,        .i,
    .x,      .q,        .m,        .w,        .reserved, .k,        .p,        .@",",     .@".",     .@"/",
    .escape, .reserved, .reserved, .reserved, .reserved, .reserved, .r,        .reserved, .reserved, .reserved,
    // zig fmt: on
};

pub fn main() !void {
    const pins = initPins();
    pins.led.put(1);

    var usb_ctrl: usb.DeviceController(
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
                    .Drivers = Drivers,
                    .attributes = .{ .self_powered = false },
                    .max_current_ma = 50,
                },
            },
        },
        .{.{
            .keyboard = .{ .itf_string = "Boot Keyboard", .poll_interval = 1 },
            .reset = "",
        }},
    ) = .init;
    var usb_dev = UsbDevice.init();

    const matrix_h = pins.rows.len;
    const col_count = pins.cols.len;
    const matrix_w = col_count * 2;
    const matrix_s = matrix_h * matrix_w;

    var changed = false;
    var matrix = [_]u1{1} ** matrix_s;
    var new_matrix = [_]u1{1} ** matrix_s;
    while (true) {
        usb_dev.poll(&usb_ctrl);
        if (usb_ctrl.drivers()) |d| {
            const drivers: *Drivers = @ptrCast(d);

            if (changed) {
                changed = false;
                var report_keys = [_]Code{.reserved} ** 6;
                var report_idx: usize = 0;
                for (matrix, 0..) |key_state, key_idx| {
                    if (key_state == 0) {
                        const keycode = MATRIX[key_idx];
                        report_keys[report_idx] = keycode;
                        report_idx += 1;
                        if (report_idx >= report_keys.len) {
                            break;
                        }
                    }
                }
                const report: KeyboardInReport = .{
                    .modifiers = .none,
                    .keys = report_keys,
                };
                _ = drivers.keyboard.send_report(&report);
            }

            _ = drivers.keyboard.receive_report();
        }

        for (pins.rows, 0..) |row, row_idx| {
            row.put(0);
            time.sleep_us(2);
            switch (config.half) {
                .left => {
                    for (0..col_count) |col_idx| {
                        const col = pins.cols[col_idx];
                        new_matrix[matrix_w * row_idx + col_idx] = col.read();
                    }
                },
                .right => {
                    for (0..col_count) |col_idx| {
                        const col = pins.cols[col_idx];
                        new_matrix[matrix_w * (row_idx + 1) - (col_idx + 1)] = col.read();
                    }
                },
            }
            row.put(1);
        }
        changed = !std.mem.eql(u1, &new_matrix, &matrix);
        matrix = new_matrix;
    }
}
