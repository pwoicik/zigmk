const std = @import("std");
const tst = std.testing;
const timer = @import("timer.zig");
const kc = @import("key_codes.zig");

pub const types = struct {
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

    pub const PressedKeys = struct {
        keys: [6]u8,
        mods: Modifiers,

        const empty: @This() = .{
            .keys = [_]u8{@intFromEnum(kc.StandardKey.no)} ** 6,
            .mods = .none,
        };
    };

    pub fn Key(comptime CustomKey: type) type {
        return union(enum) {
            standard: kc.StandardKey,
            custom: CustomKey,
        };
    }

    pub fn KeyConfig(comptime TKey: type) type {
        return union(enum) {
            press: TKey,
            mod_tap: struct { mod: kc.ModKey, key: kc.StandardKey },

            pub const no: @This() = .{ .press = .{ .standard = .no } };

            pub fn ps(comptime key: kc.StandardKey) @This() {
                return .{ .press = .{ .standard = key } };
            }

            pub fn pc(comptime key: @typeInfo(TKey).@"union".fields[1].type) @This() {
                return .{ .press = .{ .custom = key } };
            }

            pub fn mt(comptime mod: kc.ModKey, comptime key: kc.StandardKey) @This() {
                return .{ .mod_tap = .{ .mod = mod, .key = key } };
            }
        };
    }

    fn Layers(comptime Layer: type, comptime Keymap: type) type {
        const t_info = @typeInfo(Layer).@"enum";

        var ret_fields: []const std.builtin.Type.StructField = &.{};

        for (t_info.fields) |field| {
            ret_fields = ret_fields ++ .{std.builtin.Type.StructField{
                .name = field.name,
                .type = Keymap,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(Keymap),
            }};
        }

        return @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = ret_fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    }

    fn KeyState(comptime Layer: type) type {
        return packed struct(u64) {
            timestamp: u32,
            layer: @typeInfo(Layer).@"enum".tag_type,
            is_pressed: bool,
            __padding: @Type(.{
                .int = .{
                    .signedness = .unsigned,
                    .bits = 31 - @sizeOf(Layer),
                },
            }) = 0,

            const empty: @This() = @bitCast(@as(u64, 0));
        };
    }
};

const Config = struct {
    tap_term: u16 = 200,
    Matrix: type,
    Layer: type,
    CustomKey: type = enum {},
};

pub fn KeyboardState(comptime config: Config) type {
    if (@typeInfo(config.Layer) != .@"enum") {
        @compileError("Layer has to be an enum");
    }

    const layer_count = @typeInfo(config.Layer).@"enum".fields.len;
    if (layer_count == 0) {
        @compileError("Layer must have at least one field");
    }

    return struct {
        pub const tap_term = config.tap_term;
        pub const keymap_size = @typeInfo(config.Matrix.State).array.len * 8;

        const Key = types.Key(config.CustomKey);
        pub const KeyConfig = types.KeyConfig(Key);
        pub const Keymap = [keymap_size]KeyConfig;

        const Layer = config.Layer;
        const Layers = types.Layers(Layer, [keymap_size]KeyConfig);

        const KeyState = types.KeyState(Layer);

        key_states: [keymap_size]KeyState,
        layer_state: @Type(.{
            .int = .{
                .signedness = .unsigned,
                .bits = layer_count,
            },
        }),
        layers: Layers,
        pressed_keys: types.PressedKeys,

        pub fn init(comptime layers: Layers) @This() {
            const self = @This(){
                .key_states = [_]KeyState{.empty} ** keymap_size,
                .layer_state = 1,
                .layers = layers,
                .pressed_keys = types.PressedKeys.empty,
            };
            return self;
        }

        pub inline fn update(self: *@This(), matrix: *const config.Matrix) bool {
            self.updateKeyStates(matrix);
            return self.updatePressedKeys();
        }

        inline fn updateKeyStates(self: *@This(), matrix: *const config.Matrix) void {
            const timestamp = timer.currentTime();
            const active_layer = self.getHighestAciveLayer();
            var key_idx: usize = 0;
            for (matrix.state) |byte| {
                for (0..8) |bit_idx| {
                    defer key_idx += 1;
                    const was_pressed = self.key_states[key_idx].is_pressed;
                    const is_pressed = config.Matrix.getKeyState(byte, @truncate(bit_idx)) == .pressed;
                    if (is_pressed != was_pressed) {
                        self.key_states[key_idx] = if (is_pressed)
                            .{
                                .is_pressed = true,
                                .timestamp = timestamp,
                                .layer = @intFromEnum(active_layer),
                            }
                        else
                            .empty;
                    }
                }
            }
        }

        inline fn updatePressedKeys(self: *@This()) bool {
            const pressed_keys = self.scanPressedKeys();
            const changed = !std.mem.eql(
                u8,
                std.mem.asBytes(&pressed_keys),
                std.mem.asBytes(&self.pressed_keys),
            );
            self.pressed_keys = pressed_keys;
            return changed;
        }

        // TODO: rollover handling
        inline fn scanPressedKeys(self: *const @This()) types.PressedKeys {
            var pressed_idx: usize = 0;
            var pressed_keys = types.PressedKeys.empty;
            const timestamp = timer.currentTime();
            for (self.key_states, 0..) |key, idx| {
                if (key.is_pressed) {
                    const keymap = self.getKeymap(@enumFromInt(key.layer));
                    const key_config = keymap[idx];
                    switch (key_config) {
                        .press => |p| switch (p) {
                            .standard => |s| {
                                if (s != .no and pressed_idx < pressed_keys.keys.len) {
                                    pressed_keys.keys[pressed_idx] = @intFromEnum(s);
                                    pressed_idx += 1;
                                }
                            },
                            .custom => {
                                unreachable;
                            },
                        },
                        .mod_tap => |mt| {
                            const time_elapsed = key.timestamp + tap_term >= timestamp;
                            if (time_elapsed) {
                                switch (mt.mod) {
                                    .lctrl => pressed_keys.mods.lctrl = true,
                                    .lshift => pressed_keys.mods.lshift = true,
                                    .lalt => pressed_keys.mods.lalt = true,
                                    .lgui => pressed_keys.mods.lgui = true,
                                    .rctrl => pressed_keys.mods.rctrl = true,
                                    .rshift => pressed_keys.mods.rshift = true,
                                    .ralt => pressed_keys.mods.ralt = true,
                                    .rgui => pressed_keys.mods.rgui = true,
                                }
                            } else {
                                // TODO: this should execute if released before the timer elapses
                                if (mt.key != .no and pressed_idx < pressed_keys.keys.len) {
                                    pressed_keys.keys[pressed_idx] = @intFromEnum(mt.key);
                                    pressed_idx += 1;
                                }
                            }
                        },
                    }
                }
            }
            return pressed_keys;
        }

        inline fn getKeymap(self: *const @This(), layer: Layer) Keymap {
            const ptr: [*]const Keymap = @ptrCast(&self.layers);
            return ptr[@intFromEnum(layer)];
        }

        pub fn getHighestAciveLayer(self: *const @This()) Layer {
            if (layer_count == 1) {
                return @enumFromInt(0);
            }
            const IntType = @TypeOf(self.layer_state);
            const bit_size = @bitSizeOf(IntType);
            var mask: IntType = 1 << (bit_size - 1);
            var offset: IntType = 0;
            while (mask > 0) : (mask >>= 1) {
                defer offset += 1;
                if (self.layer_state & mask != 0) {
                    const idx = bit_size - 1 - offset;
                    return @enumFromInt(idx);
                }
            }
            unreachable;
        }
    };
}

test "init" {
    const mx = @import("matrix.zig");
    const M = mx.Matrix(.{
        .col_count = 16,
        .row_count = 16,
        .half = .left,
    });
    const L = enum { default };
    const KS = KeyboardState(.{
        .Layer = L,
        .Matrix = M,
    });
    const state = KS.init(.{
        .default = [_]KS.KeyConfig{.ps(.a)} ** KS.keymap_size,
    });

    try tst.expectEqualDeep(state.pressed_keys, types.PressedKeys.empty);
}

test "update" {
    const mx = @import("matrix.zig");
    const M = mx.Matrix(.{
        .col_count = 4,
        .row_count = 4,
        .half = .left,
    });
    const L = enum { default };
    const KS = KeyboardState(.{
        .Layer = L,
        .Matrix = M,
    });
    const sk = kc.StandardKey.a;
    var state = KS.init(.{
        .default = [_]KS.KeyConfig{.ps(sk)} ** KS.keymap_size,
    });
    var matrix: M = .{};

    matrix.state[0] = 0x3f;
    const changed = state.update(&matrix);

    try tst.expect(changed);
    try tst.expectEqual(0, @as(u8, @bitCast(state.pressed_keys.mods)));

    const expected_keys: [6]u8 = .{ @intFromEnum(sk), @intFromEnum(sk), 0, 0, 0, 0 };
    try tst.expectEqual(expected_keys, state.pressed_keys.keys);
}
