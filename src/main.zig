const std = @import("std");
const config = @import("build_config");
const microzig = @import("microzig");
const hal = microzig.hal;
const gpio = hal.gpio;
const time = hal.time;
const KeyboardHid = @import("KeyboardHid.zig");
const ScanCode = KeyboardHid.ScanCode;
const PioUsart = @import("PioUsart.zig");

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

const MATRIX = [_]ScanCode{
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

inline fn getMatrixThisHalf(matrix: *[matrix_arr_len]u8) *[matrix_arr_half_len]u8 {
    return if (config.half == .left) getMatrixLeftHalf(matrix) else getMatrixRightHalf(matrix);
}

inline fn getMatrixOppositeHalf(matrix: *[matrix_arr_len]u8) *[matrix_arr_half_len]u8 {
    return if (config.half == .left) getMatrixRightHalf(matrix) else getMatrixLeftHalf(matrix);
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
    .rx_pin = if (config.half == .left) pins.serial.p0 else pins.serial.p1,
    .tx_pin = if (config.half == .left) pins.serial.p1 else pins.serial.p0,
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
                tx_state = .header;
            }
        },
    }
}

fn usartStartMessage(msg_type: MessageType) void {
    usart.write(SYNC_BYTE);
    usart.write(@intFromEnum(msg_type));
}

pub fn main() !void {
    var keyboard_hid = KeyboardHid.init();

    initUartLogger();
    pins.init();
    microzig.interrupt.enable(.PIO0_IRQ_0);
    usart.setup();

    is_primary = keyboard_hid.isPluggedIn();

    if (is_primary) {
        primaryMain(&keyboard_hid);
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

fn primaryMain(keyboard_hid: *KeyboardHid) void {
    var changed = false;
    var matrix = [_]u8{0xff} ** matrix_arr_len;
    var new_matrix = [_]u8{0xff} ** matrix_arr_len;
    const new_matrix_this = getMatrixThisHalf(&new_matrix);
    const new_matrix_opposite = getMatrixOppositeHalf(&new_matrix);
    while (true) {
        keyboard_hid.poll();
        if (changed) {
            changed = false;
            const report = buildReport(&matrix);
            _ = keyboard_hid.sendReport(&report);
        }
        _ = keyboard_hid.receive_report();

        if (!is_secondary_ready.load(.acquire)) {
            @branchHint(.unlikely);
            continue;
        }

        usartStartMessage(.scan_request);
        scanMatrix(new_matrix_this);
        // there might be partial updates, idk if thats gonna be a problem
        @memcpy(new_matrix_opposite, &rx_frame);
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

fn buildReport(matrix: *const [matrix_arr_len]u8) KeyboardHid.InReport {
    var report_keys = [_]ScanCode{.reserved} ** 6;
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
    return .{
        .modifiers = .none,
        .keys = report_keys,
    };
}
