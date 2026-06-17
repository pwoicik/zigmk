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

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .PIO0_IRQ_0 = .{ .c = interrupt_handler },
    },
};

fn interrupt_handler() callconv(.c) void {
    pins.led.put(1);
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

        self.serial.p0.set_function(.sio);
        self.serial.p1.set_function(.sio);

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
    p0: gpio.Pin,
    p1: gpio.Pin,
};

const pins = if (config.board == .pico2)
    Pins{
        .rows = .{
            gpio.num(6),
            gpio.num(7),
            gpio.num(8),
            gpio.num(9),
        },
        .cols = .{
            gpio.num(15),
            gpio.num(11),
            gpio.num(12),
            gpio.num(13),
            gpio.num(14),
        },
        .serial = .{
            .p0 = gpio.num(16),
            .p1 = gpio.num(17),
        },
        .led = gpio.num(25),
    }
else
    Pins{
        .rows = .{
            gpio.num(26),
            gpio.num(27),
            gpio.num(28),
            gpio.num(29),
        },
        .cols = .{
            gpio.num(6),
            gpio.num(7),
            gpio.num(3),
            gpio.num(4),
            gpio.num(2),
        },
        .serial = .{
            .p0 = gpio.num(0),
            .p1 = gpio.num(1),
        },
        .led = gpio.num(25),
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
    _ = PioUart.init(.{ .rx = gpio.num(0), .tx = gpio.num(1) });

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
    const HALF_PERIOD_US: u32 = 4;

    const FRAME_TIMEOUT_US: u32 = 2_000;

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

    fn crc8(bytes: []const u8) u8 {
        var crc: u8 = 0;
        for (bytes) |b| {
            crc ^= b;
            var i: u3 = 0;
            while (i < 7) : (i += 1) {
                crc = if ((crc & 0x80) != 0) (crc << 1) ^ 0x07 else crc << 1;
            }
            crc = if ((crc & 0x80) != 0) (crc << 1) ^ 0x07 else crc << 1;
        }
        return crc;
    }

    pub const Master = struct {
        clk: gpio.Pin = pins.serial.p0,
        data: gpio.Pin = pins.serial.p0,

        pub fn init() void {
            pins.serial.p0.set_function(.sio);
            pins.serial.p1.set_function(.sio);

            pins.serial.p0.put(0);
            pins.serial.p0.set_direction(.out);

            pins.serial.p1.set_direction(.in);
            pins.serial.p1.set_pull(.down);
        }

        inline fn half_period() void {
            time.sleep_us(HALF_PERIOD_US);
        }

        inline fn clock_one_bit() u1 {
            pins.serial.p0.put(1);
            half_period();
            const bit = pins.serial.p1.read();
            pins.serial.p0.put(0);
            half_period();
            return bit;
        }

        pub fn read_matrix(out: *[matrix_arr_half_len]u8) Error!void {
            const max_start_attempts: u32 =
                FRAME_TIMEOUT_US / (2 * HALF_PERIOD_US) + 1;

            var start_bit: u1 = 0;
            var attempt: u32 = 0;
            while (attempt < max_start_attempts) : (attempt += 1) {
                start_bit = clock_one_bit();
                if (start_bit == 1) break;
            }
            if (start_bit != 1) return Error.Timeout;

            var i: usize = 0;
            while (i < matrix_half_s) : (i += 1) {
                const bit = clock_one_bit();
                const shift: u3 = @intCast(7 - (i % 8));
                out[i / 8] |= @as(u8, bit) << shift;
            }

            var rx_crc: u8 = 0;
            var j: u4 = 0;
            while (j < 8) : (j += 1) {
                const bit = clock_one_bit();
                rx_crc = (rx_crc << 1) | @as(u8, bit);
            }

            const stop = clock_one_bit();
            if (stop != 0) return Error.BadStopBit;

            if (rx_crc != crc8(out[0..])) return Error.CrcMismatch;
        }
    };

    pub const Slave = struct {
        clk: gpio.Pin = pins.serial.p0,
        data: gpio.Pin = pins.serial.p1,

        pub fn init() void {
            pins.serial.p0.set_function(.sio);
            pins.serial.p1.set_function(.sio);

            pins.serial.p0.set_direction(.in);
            pins.serial.p0.set_pull(.down);

            pins.serial.p1.put(0);
            pins.serial.p1.set_direction(.out);
        }

        inline fn wait_clk_high() void {
            while (pins.serial.p0.read() == 0) {}
        }

        inline fn wait_clk_low() void {
            while (pins.serial.p0.read() == 1) {}
        }

        inline fn shift_one_bit(bit: u1) void {
            wait_clk_high();
            pins.serial.p1.put(bit);
            wait_clk_low();
        }

        pub fn send_matrix(m: *const [matrix_arr_half_len]u8) void {
            shift_one_bit(1);

            var i: usize = 0;
            while (i < matrix_half_s) : (i += 1) {
                const shift: u3 = @intCast(7 - (i % 8));
                const bit: u1 = @intCast((m[i / 8] >> shift) & 1);
                shift_one_bit(bit);
            }

            const crc = crc8(m[0..]);
            var j: i32 = 7;
            while (j >= 0) : (j -= 1) {
                const bit: u1 = @intCast((crc >> @intCast(j)) & 1);
                shift_one_bit(bit);
            }

            shift_one_bit(0);
        }
    };
};

const PioUart = struct {
    const BAUD = 115_200;

    const Lane = struct {
        pio: hal.pio.Pio,
        sm: hal.pio.StateMachine,
    };

    rx: Lane,
    tx: Lane,

    fn init(_pins: struct { rx: gpio.Pin, tx: gpio.Pin }) PioUart {
        const self = PioUart{
            .rx = .{ .pio = .pio0, .sm = .sm0 },
            .tx = .{ .pio = .pio0, .sm = .sm1 },
        };
        const div = hal.pio.ClkDivOptions.from_float(
            @as(f32, @floatFromInt(hal.clock_config.sys.?.frequency())) / (8 * BAUD),
        );
        __initRx(_pins.rx, self.rx, div) catch unreachable;
        __initTx(_pins.tx, self.tx, div) catch unreachable;
        return self;
    }

    inline fn write(self: *const PioUart, value: u8) void {
        self.tx.pio.sm_blocking_write(self.tx.sm, value);
    }

    inline fn read(self: *const PioUart) u8 {
        const value = @as([*]volatile u8, @ptrCast(self.rx.pio.sm_get_rx_fifo(self.rx.sm))) + 3;
        while (self.rx.pio.sm_is_rx_fifo_empty(self.rx.sm)) {}
        return @as(*volatile u8, @ptrCast(value)).*;
    }

    fn __initRx(pin: gpio.Pin, lane: Lane, div: hal.pio.ClkDivOptions) !void {
        const pio = lane.pio;
        const sm = lane.sm;

        try pio.sm_set_pindir(sm, pin, 1, .in);
        pio.gpio_init(pin);
        pin.set_pull(.up);

        pio.sm_load_and_start_program(
            sm,
            rx_prog,
            .{
                .clkdiv = div,
                .shift = .{
                    .in_shiftdir = .right,
                    .autopush = false,
                    .push_threshold = 0,
                    .join_rx = true,
                },
                .pin_mappings = .{
                    .in_base = pin,
                },
                .exec = .{
                    .jmp_pin = pin,
                },
            },
        ) catch unreachable;
        pio.sm_set_enabled(sm, true);
        pio.sm_enable_interrupt(sm, .irq0, .rx_not_empty);
    }

    const rx_prog = blk: {
        @setEvalBranchQuota(10_000);
        break :blk hal.pio.assemble(
            \\ .program uart_rx
            \\ start:
            \\     wait 0 pin 0        ; Stall until start bit is asserted
            \\     set x, 7    [10]    ; Preload bit counter, then delay until halfway through
            \\ bitloop:                ; the first data bit (12 cycles incl wait, set).
            \\     in pins, 1          ; Shift data bit into ISR
            \\     jmp x-- bitloop [6] ; Loop 8 times, each loop iteration is 8 cycles
            \\     jmp pin good_stop   ; Check stop bit (should be high)
            \\
            \\     irq wait 0          ; Either a framing error or a break. Set a sticky flag,
            \\     wait 1 pin 0        ; and wait for line to return to idle state.
            \\     jmp start           ; Don't push data if we didn't see good framing.
            \\
            \\ good_stop:              ; No delay before returning to start; a little slack is
            \\     push                ; important in case the TX clock is slightly too fast.
        , .{}).get_program_by_name("uart_rx");
    };

    fn __initTx(pin: gpio.Pin, lane: Lane, div: hal.pio.ClkDivOptions) !void {
        const pio = lane.pio;
        const sm = lane.sm;

        try pio.sm_set_pin(sm, pin, 1, 1);
        try pio.sm_set_pindir(sm, pin, 1, .out);
        pio.gpio_init(pin);

        pio.sm_load_and_start_program(
            sm,
            tx_prog,
            .{
                .clkdiv = div,
                .shift = .{
                    .out_shiftdir = .right,
                    .autopull = false,
                    .pull_threshold = 0,
                    .join_tx = true,
                },
                .pin_mappings = .{
                    .out = .single(pin),
                    .side_set = .single(pin),
                },
                .exec = .{
                    .side_set_optional = true,
                },
            },
        ) catch unreachable;
        pio.sm_set_enabled(sm, true);
    }

    const tx_prog = blk: {
        @setEvalBranchQuota(10_000);
        break :blk hal.pio.assemble(
            \\ .program uart_tx
            \\ .side_set 1 opt
            \\     pull       side 1 [7]  ; Assert stop bit, or stall with line in idle state
            \\     set x, 7   side 0 [7]  ; Preload bit counter, assert start bit for 8 clocks
            \\ bitloop:                   ; This loop will run 8 times (8n1 UART)
            \\     out pins, 1            ; Shift 1 bit from OSR to the first OUT pin
            \\     jmp x-- bitloop   [6]  ; Each loop iteration is 8 cycles.
        , .{}).get_program_by_name("uart_tx");
    };
};
