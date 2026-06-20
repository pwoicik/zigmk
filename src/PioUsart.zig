const microzig = @import("microzig");
const cpu = microzig.cpu;
const hal = microzig.hal;
const gpio = hal.gpio;

const Self = @This();

const Lane = struct {
    pin: gpio.Pin,
    pio: hal.pio.Pio,
    sm: hal.pio.StateMachine,
};

baud_rate: u32,
rx: Lane,
tx: Lane,

pub const Config = struct {
    baud_rate: u32 = 115_200,
    rx_pin: gpio.Pin,
    tx_pin: gpio.Pin,
};

pub fn init(comptime config: Config) Self {
    return .{
        .baud_rate = config.baud_rate,
        .rx = .{ .pin = config.rx_pin, .pio = .pio0, .sm = .sm0 },
        .tx = .{ .pin = config.tx_pin, .pio = .pio0, .sm = .sm1 },
    };
}

pub fn setup(self: *const Self) void {
    const div = self.calcDiv();
    initRx(self.rx, div) catch unreachable;
    initTx(self.tx, div) catch unreachable;
}

pub inline fn write(self: *const Self, value: u8) void {
    self.tx.pio.sm_blocking_write(self.tx.sm, value);
}

pub inline fn read(self: *const Self) u8 {
    const ptr = @as([*]volatile u8, @ptrCast(self.rx.pio.sm_get_rx_fifo(self.rx.sm))) + 3;
    const value = @as(*volatile u8, @ptrCast(ptr)).*;
    return value;
}

fn calcDiv(self: *const Self) hal.pio.ClkDivOptions {
    const cpu_clk: f32 = @floatFromInt(hal.clock_config.sys.?.frequency());
    const target_clk: f32 = @floatFromInt(8 * self.baud_rate);
    return hal.pio.ClkDivOptions.from_float(cpu_clk / target_clk);
}

fn initRx(lane: Lane, div: hal.pio.ClkDivOptions) !void {
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

fn initTx(lane: Lane, div: hal.pio.ClkDivOptions) !void {
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
