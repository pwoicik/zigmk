const std = @import("std");
const buid_config = @import("build_config");
const microzig = @import("microzig");
const hal = microzig.hal;
const gpio = hal.gpio;
const time = hal.time;
const KeyboardHid = @import("KeyboardHid.zig");
const PioUsart = @import("PioUsart.zig");
const Half = @import("half.zig").Half;
const mx = @import("matrix.zig");
const ks = @import("state.zig");

const half: Half = switch (buid_config.half) {
    .left => .left,
    .right => .right,
};

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_scope_levels = &.{
        .{ .scope = .usb_dev, .level = .warn },
        .{ .scope = .usb_ctrl, .level = .warn },
        .{ .scope = .usb_hid_int_driver, .level = .warn },
    },
    .logFn = hal.uart.log,
});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .PIO0_IRQ_0 = .{ .c = usartRxIrq },
    },
};

comptime {
    microzig.export_startup();
}

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

const pins = if (buid_config.board == .pico2)
    Pins{
        .rows = .{
            gpio.num(6),
            gpio.num(7),
            gpio.num(8),
            gpio.num(9),
        },
        .cols = if (half == .left)
            .{
                gpio.num(15),
                gpio.num(11),
                gpio.num(12),
                gpio.num(13),
                gpio.num(14),
            }
        else
            .{
                gpio.num(14),
                gpio.num(13),
                gpio.num(12),
                gpio.num(11),
                gpio.num(15),
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
        .cols = if (half == .left)
            .{
                gpio.num(6),
                gpio.num(7),
                gpio.num(3),
                gpio.num(4),
                gpio.num(2),
            }
        else
            .{
                gpio.num(2),
                gpio.num(3),
                gpio.num(4),
                gpio.num(7),
                gpio.num(6),
            },
        .serial = .{
            .p0 = gpio.num(0),
            .p1 = gpio.num(1),
        },
        .led = gpio.num(25),
    };

const usart = PioUsart.init(.{
    .rx_pin = if (half == .left) pins.serial.p0 else pins.serial.p1,
    .tx_pin = if (half == .left) pins.serial.p1 else pins.serial.p0,
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

var rx_frame: Matrix.HalfState = undefined;
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
            if (rx_frame_cursor >= rx_frame.len) {
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

    const is_primary = keyboard_hid.isPluggedIn();

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

const Matrix = mx.Matrix(.{
    .col_count = pins.cols.len,
    .row_count = pins.rows.len,
    .half = half,
});

const Layer = enum {
    default,
};

const CustomKey = enum {};

const KeyboardState = ks.KeyboardState(.{
    .Matrix = Matrix,
    .Layer = Layer,
    .CustomKey = CustomKey,
});

const KeyConfig = KeyboardState.KeyConfig;

fn keymap(comptime km: [38]KeyConfig) [KeyboardState.keymap_size]KeyConfig {
    return .{
        // zig fmt: off
        km[0],  km[1],  km[2],  km[3],  km[4],
        km[5],  km[6],  km[7],  km[8],  km[9],
        km[11], km[12], km[13], km[14], km[15],
        km[10], .no,    km[16], km[17], km[18],
        .no,    .no,    .no,    .no,

        km[19], km[20], km[21], km[22], km[23],
        km[24], km[25], km[26], km[27], km[28],
        km[29], km[30], km[31], km[32], km[33],
        km[35], km[36], km[37], .no,    km[34],
        .no,    .no,    .no,    .no,
        // zig fmt: on
    };
}

// zig fmt: off
const default_keymap = keymap(.{
    // left --------------------------------------------------------------------------------------------
               .ps(.b),      .ps(.l),      .ps(.d),      .ps(.c),      .ps(.v),
               .mt(.lc, .n), .mt(.ls, .z), .mt(.lg, .t), .mt(.la, .s), .ps(.g),
    .ps(.esc), .ps(.x),      .ps(.q),      .ps(.m),      .ps(.w),      .no,
                                                         .no,  .        ps(.space), .ps(.delete),

    // right -------------------------------------------------------------------------------------------
               .ps(.j), .ps(.f),      .ps(.o),      .ps(.u),      .ps(.@";"),
               .ps(.y), .mt(.la, .h), .mt(.lg, .a), .mt(.ls, .e), .mt(.lc, .i),
               .ps(.k), .ps(.p),      .ps(.@","),   .ps(.@"."),   .ps(.@"/"),   .ps(.@"\\"),
    .ps(.ent), .ps(.r), .no,
});
// zig fmt: on

fn primaryMain(keyboard_hid: *KeyboardHid) noreturn {
    var keys_changed = false;
    var matrix = Matrix{};
    var state = KeyboardState.init(.{ .default = default_keymap });
    while (true) {
        keyboard_hid.poll();
        if (keys_changed) {
            keys_changed = false;
            const report = buildReport(&state);
            _ = keyboard_hid.sendReport(&report);
        }
        _ = keyboard_hid.receive_report();

        if (is_secondary_ready.load(.acquire)) {
            @branchHint(.likely);
            usartStartMessage(.scan_request);
        }
        scanMatrix(&matrix);
        // there might be partial updates, idk if thats gonna be a problem
        matrix.updateOppositeHalf(&rx_frame);
        keys_changed = state.update(&matrix);
    }
}

fn secondaryMain() noreturn {
    usartStartMessage(.secondary_ready);

    var matrix = Matrix{};
    while (true) {
        asm volatile ("wfi");
        if (scan_requested.load(.acquire)) {
            scan_requested.store(false, .release);
            scanMatrix(&matrix);
            usartStartMessage(.scan_result);
            for (matrix.getThisHalf()) |byte| {
                usart.write(byte);
            }
        }
    }
}

inline fn scanMatrix(matrix: *Matrix) void {
    for (pins.rows, 0..) |row, row_idx| {
        row.put(0);
        time.sleep_us(2);
        for (0..pins.cols.len) |col_idx| {
            const col = pins.cols[col_idx];
            const bit_idx = row_idx * pins.cols.len + col_idx;
            matrix.updateKey(bit_idx, @enumFromInt(col.read()));
        }
        row.put(1);
    }
}

inline fn buildReport(state: *const KeyboardState) KeyboardHid.InReport {
    const report: KeyboardHid.InReport = .{
        .modifiers = state.pressed_keys.mods,
        .keys = state.pressed_keys.keys,
    };
    return report;
}
