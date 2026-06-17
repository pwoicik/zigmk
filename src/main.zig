const std = @import("std");
const config = @import("build_config");
const microzig = @import("microzig");
const hal = microzig.hal;
const gpio = hal.gpio;
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

    fn init(self: *const Pins) void {
        _ = microzig.board.pin_config.apply();
        self.led.set_direction(.out);

        self.serial.clk.set_function(.sio);
        self.serial.data.set_function(.sio);

        for (self.rows) |pin| {
            pin.set_function(.sio);
            pin.set_direction(.out);
            pin.put(1);
        }
        for (self.cols) |pin| {
            pin.set_function(.sio);
            pin.set_direction(.in);
            pin.set_pull(.up);
        }
    }
};

const SerialPins = struct {
    clk: hal.gpio.Pin,
    data: hal.gpio.Pin,
};

const pins = if (config.board == .pico2)
    Pins{
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
        .serial = .{
            .clk = hal.gpio.num(16),
            .data = hal.gpio.num(17),
        },
        .led = hal.gpio.num(25),
    }
else
    Pins{
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
        .serial = .{
            .clk = hal.gpio.num(16),
            .data = hal.gpio.num(17),
        },
        .led = hal.gpio.num(25),
    };

const MATRIX = [_]Code{
    // zig fmt: off
    .b,        .l,        .d,        .c,        .v,
    .n,        .z,        .t,        .s,        .g,
    .x,        .q,        .m,        .w,        .reserved,
    .escape,   .reserved, .reserved, .reserved, .reserved,
    .reserved, .reserved, .reserved, .reserved,

    .j,        .f,        .o,        .u,        .@";",
    .y,        .h,        .a,        .e,        .i,
    .k,        .p,        .@",",     .@".",     .@"/",
    .reserved, .r,        .reserved, .reserved, .reserved,
    .reserved, .reserved, .reserved, .reserved,
    // zig fmt: on
};

const row_count = pins.rows.len;
const col_count = pins.cols.len;
const matrix_half_s = row_count * col_count;
const matrix_arr_half_len = (matrix_half_s + 7) / 8;
const matrix_arr_len = matrix_arr_half_len * 2;

inline fn getMatrixLeftHalf(matrix: *[matrix_arr_len]u8) *[matrix_arr_half_len]u8 {
    return matrix[0..matrix_arr_half_len];
}

inline fn getMatrixRightHalf(matrix: *[matrix_arr_len]u8) *[matrix_arr_half_len]u8 {
    return matrix[matrix_arr_half_len..];
}

inline fn setMatrixBit(matrix: *[matrix_arr_half_len]u8, bit_idx: u8, new_val: u1) void {
    const idx = bit_idx >> 3;
    const offset = bit_idx & 7;
    const mask = @as(u8, 1) << @truncate(offset);
    if (new_val == 1) {
        matrix[idx] |= mask;
    } else {
        matrix[idx] &= ~mask;
    }
}

fn detectMaster() bool {
    var attempts: u32 = 0;
    while (attempts < 500_000) : (attempts += 1) {
        const sie_status = microzig.chip.peripherals.USB.SIE_STATUS.read();
        if (sie_status.CONNECTED == 1) {
            return true;
        }
        time.sleep_us(1);
    }
    return false;
}

pub fn main() !void {
    pins.init();

    var usb_ctrl = usb.DeviceController(
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
    ).init;
    var usb_dev = UsbDevice.init();

    const isMaster = detectMaster();

    if (isMaster) {
        Link.Master.init();
    } else {
        Link.Slave.init();
    }

    var changed = false;
    var matrix = [_]u8{0xff} ** matrix_arr_len;
    var new_matrix = [_]u8{0xff} ** matrix_arr_len;
    const new_matrix_left = getMatrixLeftHalf(&new_matrix);
    const new_matrix_right = getMatrixRightHalf(&new_matrix);
    const new_matrix_this = if (config.half == .left) new_matrix_left else new_matrix_right;
    const new_matrix_opposite = if (config.half == .left) new_matrix_right else new_matrix_left;
    while (true) {
        if (isMaster) {
            usb_dev.poll(&usb_ctrl);
            if (usb_ctrl.drivers()) |d| {
                const drivers: *Drivers = @ptrCast(d);

                if (changed) {
                    changed = false;
                    var report_keys = [_]Code{.reserved} ** 6;
                    var report_idx: usize = 0;
                    var key_idx: usize = 0;
                    for (0..2) |half_idx| outer: {
                        for(0..matrix_arr_half_len) |byte_idx| {
                            const byte = matrix[half_idx * matrix_arr_half_len + byte_idx];
                            for (0..8) |bit_idx| {
                                const key_state = byte & (@as(u8, 1) << @truncate(bit_idx)) == 0;
                                if (key_state) {
                                    const keycode = MATRIX[key_idx];
                                    report_keys[report_idx] = keycode;
                                    report_idx += 1;
                                    if (report_idx >= report_keys.len) {
                                        break :outer;
                                    }
                                }
                                key_idx += 1;
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
        }

        for (pins.rows, 0..) |row, row_idx| {
            row.put(0);
            time.sleep_us(2);
            for (0..col_count) |col_idx| {
                const col = if (config.half == .left)
                    pins.cols[col_idx]
                else
                    pins.cols[col_count - col_idx - 1];
                const bit_idx = row_idx * col_count + col_idx;
                setMatrixBit(
                    new_matrix_this,
                    @truncate(bit_idx),
                    col.read(),
                );
            }
            row.put(1);
        }
        if (isMaster) {
            const slice = new_matrix_opposite;
            Link.Master.read_matrix(slice) catch {};
            changed = !std.mem.eql(u8, &new_matrix, &matrix);
            matrix = new_matrix;
        } else {
            const slice = new_matrix_this;
            Link.Slave.send_matrix(slice);
        }
    }
}

const Link = struct {
    /// Half clock period, in microseconds. 5 µs -> ~100 kHz bit rate, which is
    /// far more than enough for a keyboard matrix and tolerates noisy TRRS wiring.
    /// Lower this if you want a faster scan.
    const HALF_PERIOD_US: u32 = 3;

    /// Maximum time (in microseconds) the master will wait for the slave to
    /// produce a frame before giving up and returning a timeout error.
    const FRAME_TIMEOUT_US: u32 = 2_000;

    // 1 start + matrix + 8 crc + 1 stop
    const FRAME_BITS: usize = 1 + matrix_half_s + 8 + 1;

    pub const Matrix = [matrix_arr_half_len]u8;

    pub const Error = error{
        Timeout,
        BadStartBit,
        BadStopBit,
        CrcMismatch,
    };

    inline fn get_bit(m: *const [matrix_arr_half_len]u8, row: u8, col: u8) u1 {
        const idx = @as(usize, row) * pins.cols.len + col;
        const byte = m[idx / 8];
        const shift: u3 = @intCast(7 - (idx % 8));
        return @intCast((byte >> shift) & 1);
    }

    inline fn set_bit(m: *[matrix_arr_half_len]u8, row: u8, col: u8, value: u1) void {
        const idx = @as(usize, row) * pins.cols.len + col;
        const shift: u3 = @intCast(7 - (idx % 8));
        const mask: u8 = @as(u8, 1) << shift;
        if (value == 1) m[idx / 8] |= mask else m[idx / 8] &= ~mask;
    }

    // ---- CRC-8 (poly 0x07, init 0x00) over the matrix bytes ------------

    fn crc8(bytes: []const u8) u8 {
        var crc: u8 = 0;
        for (bytes) |b| {
            crc ^= b;
            var i: u3 = 0;
            while (i < 7) : (i += 1) {
                crc = if ((crc & 0x80) != 0) (crc << 1) ^ 0x07 else crc << 1;
            }
            // last iteration unrolled to avoid u3 overflow
            crc = if ((crc & 0x80) != 0) (crc << 1) ^ 0x07 else crc << 1;
        }
        return crc;
    }

    // =====================================================================
    // Master side
    // =====================================================================

    pub const Master = struct {
        clk: gpio.Pin = pins.serial.clk,
        data: gpio.Pin = pins.serial.clk,

        pub fn init() void {
            pins.serial.clk.set_function(.sio);
            pins.serial.data.set_function(.sio);

            // CLK: master output, start low
            pins.serial.clk.put(0);
            pins.serial.clk.set_direction(.out);

            // DATA: master input with pull-down so a missing/unpowered
            // slave reads as all-zeros instead of floating.
            pins.serial.data.set_direction(.in);
            pins.serial.data.set_pull(.down);
        }

        inline fn half_period() void {
            time.sleep_us(HALF_PERIOD_US);
        }

        /// Clock out one bit period and return the bit the slave drove.
        /// Slave updates DATA on rising edge; master samples just before
        /// the falling edge.
        inline fn clock_one_bit() u1 {
            pins.serial.clk.put(1);
            half_period();
            const bit = pins.serial.data.read();
            pins.serial.clk.put(0);
            half_period();
            return bit;
        }

        /// Run a full transaction: clock out an entire frame, validate
        /// it, and write the matrix bytes into `out`.
        pub fn read_matrix(out: *[matrix_arr_half_len]u8) Error!void {
            // Wait (with timeout) for the slave to assert the start bit.
            // The slave pulls DATA high after seeing the first rising
            // edge. We retry up to FRAME_TIMEOUT_US worth of clocks.
            const max_start_attempts: u32 =
                FRAME_TIMEOUT_US / (2 * HALF_PERIOD_US) + 1;

            var start_bit: u1 = 0;
            var attempt: u32 = 0;
            while (attempt < max_start_attempts) : (attempt += 1) {
                start_bit = clock_one_bit();
                if (start_bit == 1) break;
            }
            if (start_bit != 1) return Error.Timeout;

            // Matrix payload, MSB first.
            @memset(out, 0);
            var i: usize = 0;
            while (i < matrix_half_s) : (i += 1) {
                const bit = clock_one_bit();
                const shift: u3 = @intCast(7 - (i % 8));
                out[i / 8] |= @as(u8, bit) << shift;
            }

            // CRC-8 (MSB first).
            var rx_crc: u8 = 0;
            var j: u4 = 0;
            while (j < 8) : (j += 1) {
                const bit = clock_one_bit();
                rx_crc = (rx_crc << 1) | @as(u8, bit);
            }

            // Stop bit must be 0.
            const stop = clock_one_bit();
            if (stop != 0) return Error.BadStopBit;

            if (rx_crc != crc8(out[0..])) return Error.CrcMismatch;
        }
    };

    // =====================================================================
    // Slave side
    // =====================================================================

    pub const Slave = struct {
        clk: gpio.Pin = pins.serial.clk,
        data: gpio.Pin = pins.serial.data,

        pub fn init() void {
            pins.serial.clk.set_function(.sio);
            pins.serial.data.set_function(.sio);

            // CLK: slave input. Pull-down so an unconnected master reads
            // as idle instead of floating.
            pins.serial.clk.set_direction(.in);
            pins.serial.clk.set_pull(.down);

            // DATA: slave output, start low (idle).
            pins.serial.data.put(0);
            pins.serial.data.set_direction(.out);
        }

        inline fn wait_clk_high() void {
            while (pins.serial.clk.read() == 0) {}
        }

        inline fn wait_clk_low() void {
            while (pins.serial.clk.read() == 1) {}
        }

        /// Drive `bit` on DATA on the rising edge of CLK, hold it through
        /// the full clock period.
        inline fn shift_one_bit(bit: u1) void {
            wait_clk_high();
            pins.serial.data.put(bit);
            wait_clk_low();
        }

        /// Send the matrix to the master. Blocks until the master drives
        /// a full frame's worth of clocks. Call this in your main loop
        /// after every matrix scan.
        pub fn send_matrix(m: *const [matrix_arr_half_len]u8) void {
            // Start bit
            shift_one_bit(1);

            // Matrix payload, MSB first
            var i: usize = 0;
            while (i < matrix_half_s) : (i += 1) {
                const shift: u3 = @intCast(7 - (i % 8));
                const bit: u1 = @intCast((m[i / 8] >> shift) & 1);
                shift_one_bit(bit);
            }

            // CRC-8
            const crc = crc8(m[0..]);
            var j: i32 = 7;
            while (j >= 0) : (j -= 1) {
                const bit: u1 = @intCast((crc >> @intCast(j)) & 1);
                shift_one_bit(bit);
            }

            // Stop bit
            shift_one_bit(0);
        }
    };
};
