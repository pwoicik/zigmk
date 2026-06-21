const std = @import("std");
const Half = @import("half.zig").Half;

pub const Config = struct {
    col_count: usize,
    row_count: usize,
    half: Half,
};

pub const KeyState = enum(u1) {
    pressed = 0,
    not_pressed = 1,
};

pub fn Matrix(comptime config: Config) type {
    const row_count = config.row_count;
    const col_count = config.col_count;
    const key_count = row_count * col_count;
    const state_half_len = (key_count + 7) / 8;
    const state_len = state_half_len * 2;

    return struct {
        pub const HalfState = [state_half_len]u8;
        pub const State = [state_len]u8;

        state: State = [_]u8{0xff} ** state_len,
        new_state: State = [_]u8{0xff} ** state_len,

        pub inline fn updateKey(self: *@This(), idx: usize, value: KeyState) void {
            setBit(getThisHalfOf(&self.new_state), idx, value);
        }

        pub inline fn updateOppositeHalf(self: *@This(), value: *const HalfState) void {
            @memcpy(getOppositeHalfOf(&self.new_state), value);
        }

        pub inline fn commitUpdates(self: *@This()) bool {
            const changed = std.mem.eql(u8, &self.new_state, &self.state);
            self.state = self.new_state;
            return changed;
        }

        pub inline fn getKeyState(byte: u8, idx: u3) KeyState {
            return if (byte & (@as(u8, 1) << @truncate(idx)) == 0)
                .pressed
            else
                .not_pressed;
        }

        pub inline fn getThisHalf(self: *@This()) *HalfState {
            return getThisHalfOf(&self.state);
        }

        inline fn getLeftHalf(matrix: *State) *HalfState {
            return matrix[0..state_half_len];
        }

        inline fn getRightHalf(matrix: *State) *HalfState {
            return matrix[state_half_len..];
        }

        inline fn getThisHalfOf(matrix: *State) *HalfState {
            return if (config.half == .left) getLeftHalf(matrix) else getRightHalf(matrix);
        }

        inline fn getOppositeHalfOf(matrix: *State) *HalfState {
            return if (config.half == .left) getRightHalf(matrix) else getLeftHalf(matrix);
        }

        inline fn setBit(matrix: *HalfState, bit_idx: usize, new_val: KeyState) void {
            const idx = bit_idx >> 3;
            const offset = bit_idx & 7;
            const mask = @as(u8, 1) << @truncate(offset);
            if (@intFromEnum(new_val) == 1) {
                matrix[idx] |= mask;
            } else {
                matrix[idx] &= ~mask;
            }
        }
    };
}
