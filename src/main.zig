const std = @import("std");
const config = @import("build_config");
const microzig = @import("microzig");
const hal = microzig.hal;
const gpio = hal.gpio;
const time = hal.time;
const usb = microzig.core.usb;
const UsbDevice = hal.usb.Polled(.{});

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_level = .debug,
    .logFn = hal.uart.log,
});

comptime {
    _ = microzig.export_startup();
}

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .PIO0_IRQ_0 = .{ .c = usartRxIrq },
    },
};

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
);

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

var is_primary = false;

const usart = PioUsart.init(.{
    .rx = if (config.half == .left) pins.serial.p0 else pins.serial.p1,
    .tx = if (config.half == .left) pins.serial.p1 else pins.serial.p0,
});

fn usartRxIrq() callconv(.c) void {
    usartReceive();
}

const SYNC_BYTE: u8 = 0x80;

const MessageType = enum(u8) {
    secondary_ready = 0x1,
    scan_request = 0x2,
    scan_result = 0x3,
    _,
};

const UsartTxState = enum {
    header,
    msg_type,
    matrix_data,
};

var tx_state: UsartTxState = .header;

var is_secondary_ready = std.atomic.Value(bool).init(false);
var scan_requested = std.atomic.Value(bool).init(false);

var rx_frame: [matrix_arr_half_len]u8 = undefined;
var rx_frame_cursor: usize = 0;
var rx_frame_ready = std.atomic.Value(bool).init(false);

fn usartReceive() void {
    const byte = usart.read();
    switch (tx_state) {
        .header => {
            if (byte == SYNC_BYTE) {
                tx_state = .msg_type;
            }
        },
        .msg_type => {
            const msg_type: MessageType = @enumFromInt(byte);
            switch (msg_type) {
                .secondary_ready => {
                    @branchHint(.unlikely);
                    is_secondary_ready.store(true, .release);
                    tx_state = .header;
                },
                .scan_request => {
                    scan_requested.store(true, .release);
                    tx_state = .header;
                },
                .scan_result => {
                    tx_state = .matrix_data;
                },
                _ => {
                    tx_state = .header;
                },
            }
        },
        .matrix_data => {
            rx_frame[rx_frame_cursor] = byte;
            rx_frame_cursor += 1;
            if (rx_frame_cursor >= matrix_arr_half_len) {
                rx_frame_cursor = 0;
                rx_frame_ready.store(true, .release);
                tx_state = .header;
            }
        },
    }
}

fn usartStartMessage(msg_type: MessageType) void {
    usart.write(SYNC_BYTE);
    usart.write(@intFromEnum(msg_type));
}

fn detectIsPrimary() bool {
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
    var usb_ctrl = UsbController.init;
    var usb_dev = UsbDevice.init();

    initUartLogger();
    pins.init();
    microzig.interrupt.enable(.PIO0_IRQ_0);
    usart.setup();

    is_primary = detectIsPrimary();

    if (is_primary) {
        primaryMain(&usb_ctrl, &usb_dev);
    } else {
        secondaryMain();
    }
}

fn initUartLogger() void {
    const uart = hal.uart.instance.num(0);
    uart.apply(.{ .clock_config = hal.clock_config });
    gpio.num(0).set_function(.uart);
    hal.uart.init_logger(uart);
}

fn primaryMain(usb_ctrl: *UsbController, usb_dev: *UsbDevice) void {
    var changed = false;
    var matrix = [_]u8{0xff} ** matrix_arr_len;
    var new_matrix = [_]u8{0xff} ** matrix_arr_len;
    const new_matrix_left = getMatrixLeftHalf(&new_matrix);
    const new_matrix_right = getMatrixRightHalf(&new_matrix);
    const new_matrix_this = if (config.half == .left) new_matrix_left else new_matrix_right;
    const new_matrix_opposite = if (config.half == .left) new_matrix_right else new_matrix_left;
    while (true) {
        usb_dev.poll(usb_ctrl);
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

        if (!is_secondary_ready.load(.acquire)) {
            @branchHint(.unlikely);
            continue;
        }

        usartStartMessage(.scan_request);
        scanMatrix(new_matrix_this);
        if (rx_frame_ready.load(.acquire)) {
            rx_frame_ready.store(false, .release);
            @memcpy(new_matrix_opposite, &rx_frame);
        }
        changed = !std.mem.eql(u8, &new_matrix, &matrix);
        matrix = new_matrix;
    }
}

fn secondaryMain() void {
    usartStartMessage(.secondary_ready);

    var matrix = [_]u8{0xff} ** matrix_arr_half_len;
    while (true) {
        asm volatile ("wfi");
        if (scan_requested.load(.acquire)) {
            scan_requested.store(false, .release);
            scanMatrix(&matrix);
            usartStartMessage(.scan_result);
            for (matrix) |byte| {
                usart.write(byte);
            }
        }
    }
}

fn scanMatrix(matrix: *[matrix_arr_half_len]u8) void {
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
                matrix,
                @truncate(bit_idx),
                col.read(),
            );
        }
        row.put(1);
    }
}

const PioUsart = struct {
    const BAUD = 115_200;

    const Lane = struct {
        pin: gpio.Pin,
        pio: hal.pio.Pio,
        sm: hal.pio.StateMachine,
    };

    rx: Lane,
    tx: Lane,

    fn init(_pins: struct { rx: gpio.Pin, tx: gpio.Pin }) PioUsart {
        return .{
            .rx = .{ .pin = _pins.rx, .pio = .pio0, .sm = .sm0 },
            .tx = .{ .pin = _pins.tx, .pio = .pio0, .sm = .sm1 },
        };
    }

    fn setup(self: *const PioUsart) void {
        const div = hal.pio.ClkDivOptions.from_float(
            @as(f32, @floatFromInt(hal.clock_config.sys.?.frequency())) / (8 * BAUD),
        );
        __initRx(self.rx, div) catch unreachable;
        __initTx(self.tx, div) catch unreachable;
    }

    inline fn write(self: *const PioUsart, value: u8) void {
        self.tx.pio.sm_blocking_write(self.tx.sm, value);
    }

    inline fn hasData(self: *const PioUsart) bool {
        return !self.rx.pio.sm_is_rx_fifo_empty(self.rx.sm);
    }

    inline fn read(self: *const PioUsart) u8 {
        const ptr = @as([*]volatile u8, @ptrCast(self.rx.pio.sm_get_rx_fifo(self.rx.sm))) + 3;
        const value = @as(*volatile u8, @ptrCast(ptr)).*;
        return value;
    }

    fn __initRx(lane: Lane, div: hal.pio.ClkDivOptions) !void {
        const pin = lane.pin;
        const pio = lane.pio;
        const sm = lane.sm;

        pin.set_function(.pio0);
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
                    // .autopush = true,
                    .push_threshold = 0,
                    // .push_threshold = 8,
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
            \\ .wrap_target
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
            \\ .wrap
        , .{}).get_program_by_name("uart_rx");
    };

    fn __initTx(lane: Lane, div: hal.pio.ClkDivOptions) !void {
        const pin = lane.pin;
        const pio = lane.pio;
        const sm = lane.sm;

        pin.set_function(.pio0);
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
            \\ .wrap_target
            \\     pull       side 1 [7]  ; Assert stop bit, or stall with line in idle state
            \\     set x, 7   side 0 [7]  ; Preload bit counter, assert start bit for 8 clocks
            \\ bitloop:                   ; This loop will run 8 times (8n1 UART)
            \\     out pins, 1            ; Shift 1 bit from OSR to the first OUT pin
            \\     jmp x-- bitloop   [6]  ; Each loop iteration is 8 cycles.
            \\ .wrap
        , .{}).get_program_by_name("uart_tx");
    };
};
