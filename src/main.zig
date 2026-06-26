const std = @import("std");
const rl = @import("raylib");
const assert = std.debug.assert;
const testing = std.testing;
const print = std.debug.print;

const screen_size = 720;
const grid_height = 20;
const grid_width = 10;
const cell_size = 34;
const line_thick = 2;

const screen_grid_x_off = (screen_size - (grid_width * cell_size)) / 2;
const screen_grid_y_off = (screen_size - (grid_height * cell_size)) / 2;

const fall_tick = 0.3; //fall every x seconds
var time_since_last_fell: f32 = 0;
var current: Piece = undefined;

var prng: std.Random = undefined;

//Rows are represented by u16
//big endian
var grid: [grid_height]u10 = @splat(0);

//each tetromino is 4x4 grid -- represented by a u16
//      1100
//      1100
//      0000
//      0000
const Piece = struct {
    kind: PieceKind,
    rot: u2,
    x: u4,
    y: u8,

    const Row = struct {
        bits: u10,
        height: u4,
    };

    const Iterator = struct {
        row: u4 = 0,
        fn next(self: *Iterator, shape: u16) ?Row {
            while (self.row < n_rows) {
                const r = self.row;
                self.row += 1;
                const nibble: u16 = (shape >> @intCast((n_rows - 1 - r) * 4)) & 0b1111;
                if (nibble != 0) {
                    return .{ .bits = @intCast(nibble), .height = r + 1 };
                }
            }
            return null;
        }
    };
    const size = 16;
    const n_rows = size / 4;

    const PieceKind = enum {
        O,
        S,
        Z,
        I,
        T,
        L,
        J,
    };

    fn baseMask(kind: PieceKind) u16 {
        return switch (kind) {
            .O => 0b1100_1100_0000_0000,
            .S => 0b0110_1100_0000_0000,
            .Z => 0b1100_0110_0000_0000,
            .I => 0b1000_1000_1000_1000,
            .T => 0b1110_0100_0000_0000,
            .L => 0b1000_1110_0000_0000,
            .J => 0b0010_1110_0000_0000,
        };
    }

    fn rotate90(shape: u16) u16 {
        var out: u16 = 0;
        var r: u4 = 0;
        while (r < n_rows) : (r += 1) {
            var c: u4 = 0;
            while (c < n_rows) : (c += 1) {
                const src_shift: u4 = (n_rows - 1 - r) * 4 + (n_rows - 1 - c);
                const bit = (shape >> src_shift) & 0b1;
                if (bit == 1) {
                    const dst_r: u4 = c;
                    const dst_c: u4 = (n_rows - 1 - r);
                    const dst_shift: u4 = (n_rows - 1 - dst_r) * 4 + (n_rows - 1 - dst_c);
                    out |= @as(u16, 1) << dst_shift;
                }
            }
        }
        return out;
    }

    fn normalize(shape: u16) u16 {
        var top: u4 = n_rows;
        var left: u4 = n_rows;
        var r: u4 = 0;
        while (r < n_rows) : (r += 1) {
            var c: u4 = 0;
            while (c < n_rows) : (c += 1) {
                const shift: u4 = (n_rows - 1 - r) * 4 + (n_rows - 1 - c);
                if (((shape >> shift) & 0b1) != 0) {
                    top = @min(top, r);
                    left = @min(left, c);
                }
            }
        }
        if (top == n_rows) return 0;
        var out: u16 = 0;
        r = top;
        while (r < n_rows) : (r += 1) {
            var c: u4 = left;
            while (c < n_rows) : (c += 1) {
                const src_shift: u4 = (n_rows - 1 - r) * 4 + (n_rows - 1 - c);
                if (((shape >> src_shift) & 0b1) != 0) {
                    const dst_r: u4 = r - top;
                    const dst_c: u4 = c - left;
                    const dst_shift: u4 = (n_rows - 1 - dst_r) * 4 + (n_rows - 1 - dst_c);
                    out |= @as(u16, 1) << dst_shift;
                }
            }
        }
        return out;
    }

    fn maskFrom(kind: PieceKind, rot: u2) u16 {
        var m = baseMask(kind);
        var i: u2 = 0;
        while (i < rot) : (i += 1) {
            m = normalize(rotate90(m));
        }
        return m;
    }

    fn translate(shape: u16, x: u8, y: u8) void {
        var shift: u8 = 0;
        while (shift < size) : (shift += 1) {
            if ((shape << @as(u4, @intCast(shift))) & (0b1 << 15) != 0) {
                const row = shift / n_rows;
                const col = shift % n_rows;
                grid[y + row] |= @as(u10, 1) << @intCast(grid_width - 1 - (x + col));
            }
        }
    }

    fn clear(shape: u16, x: u8, y: u8) void {
        var shift: u8 = 0;
        while (shift < size) : (shift += 1) {
            if ((shape << @as(u4, @intCast(shift))) & (0b1 << 15) != 0) {
                const row = shift / n_rows;
                const col = shift % n_rows;
                grid[y + row] ^= @as(u10, 1) << @intCast(grid_width - 1 - (x + col));
            }
        }
    }

    fn width(shape: u16) u4 {
        var it = Iterator{};
        var w: u4 = 0;
        while (it.next(shape)) |row| {
            var shift: u4 = 0;
            while (shift < n_rows) : (shift += 1) {
                if ((row.bits >> shift) & @as(u10, 0b1) != 0) w = @max(n_rows - shift, w);
            }
        }
        return w;
    }
    fn new(rng: std.Random, x: u4) Piece {
        const kind = rng.enumValue(PieceKind);
        const w = width(maskFrom(kind, 0));
        return .{
            .kind = kind,
            .rot = 0,
            .x = if (x + w > grid_width) x - w else x,
            .y = 0,
        };
    }

    fn mask(self: Piece) u16 {
        return maskFrom(self.kind, self.rot);
    }

    fn moveDown(self: *Piece) void {
        clear(self.mask(), self.x, self.y);
        if (self.checkDownCollision(self.y + 1)) {
            translate(self.mask(), self.x, self.y);
            self.* = .new(prng, self.x);
            tetris();
            translate(self.mask(), self.x, self.y);
        } else {
            self.y += 1;
            translate(self.mask(), self.x, self.y);
        }
    }

    fn checkDownCollision(self: Piece, next_y: u8) bool {
        var it = Iterator{};
        const shape = self.mask();
        while (it.next(shape)) |row| {
            if (next_y + row.height > grid_height) return true;
            const shift_i: i8 = (@as(i8, @intCast(grid_width)) - 4) - self.x;
            const shape_mask = if (shift_i >= 0) @as(u10, row.bits) << @intCast(shift_i) else @as(u10, row.bits) >> @intCast(@abs(shift_i));
            if (grid[next_y + row.height - 1] & shape_mask != 0) return true;
        }
        return false;
    }

    fn checkLeftCollision(self: Piece) bool {
        var it = Iterator{};
        const shape = self.mask();
        while (it.next(shape)) |row| {
            const y_row = self.y + row.height - 1;
            const shift_i: i16 = (@as(i16, grid_width) - 4) - @as(i16, self.x);
            const shape_mask = if (shift_i >= 0)
                @as(u10, row.bits) << @intCast(shift_i)
            else
                @as(u10, row.bits) >> @intCast(-shift_i);
            if ((shape_mask & (@as(u10, 1) << (grid_width - 1))) != 0) return true;
            if ((grid[y_row] & (shape_mask << 1)) != 0) return true;
        }
        return false;
    }

    fn checkRightCollision(self: Piece) bool {
        var it = Iterator{};
        const shape = self.mask();
        while (it.next(shape)) |row| {
            const y_row = self.y + row.height - 1;
            const shift_i: i16 = (@as(i16, grid_width) - 4) - @as(i16, self.x);
            const shape_mask = if (shift_i >= 0)
                @as(u10, row.bits) << @intCast(shift_i)
            else
                @as(u10, row.bits) >> @intCast(-shift_i);
            if ((shape_mask & @as(u10, 1)) != 0) return true;
            if ((grid[y_row] & (shape_mask >> 1)) != 0) return true;
        }
        return false;
    }
};

test "width" {
    const o = Piece.maskFrom(.O, 0);
    const i = Piece.maskFrom(.I, 0);
    const s = Piece.maskFrom(.S, 0);
    const z = Piece.maskFrom(.Z, 0);
    const l = Piece.maskFrom(.L, 0);
    const j = Piece.maskFrom(.J, 0);
    try testing.expect(Piece.width(o) == 2);
    try testing.expect(Piece.width(i) == 1);
    try testing.expect(Piece.width(s) == 3);
    try testing.expect(Piece.width(z) == 3);
    try testing.expect(Piece.width(l) == 3);
    try testing.expect(Piece.width(j) == 3);
}

test "row iterator" {
    const o = Piece.maskFrom(.O, 0);
    const i = Piece.maskFrom(.I, 0);
    const s = Piece.maskFrom(.S, 0);
    // const z: PieceKind = .Z;
    var it = Piece.Iterator{};
    try testing.expect(it.next(o).?.bits == 0b1100);
    try testing.expect(it.next(o).?.bits == 0b1100);
    try testing.expect(it.next(o) == null);
    it = Piece.Iterator{};
    try testing.expect(it.next(i).?.bits == 0b1000);
    try testing.expect(it.next(i).?.bits == 0b1000);
    it = Piece.Iterator{};
    try testing.expect(it.next(s).?.bits == 0b0110);
    try testing.expect(it.next(s).?.bits == 0b1100);
    try testing.expect(it.next(s) == null);
}

pub fn main(init: std.process.Init) !void {
    rl.initWindow(screen_size, screen_size, "Tetris Clone");
    defer rl.closeWindow();

    rl.setTargetFPS(15);
    rl.setWindowPosition(0, 0);

    var rand = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(init.io, .real).toMilliseconds()));
    prng = rand.random();

    current = .new(prng, 5);
    Piece.translate(current.mask(), current.x, current.y);

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        time_since_last_fell += dt;

        if (rl.isKeyDown(.left) and current.x > 0) blk: {
            Piece.clear(current.mask(), current.x, current.y);
            if (current.checkLeftCollision()) {
                Piece.translate(current.mask(), current.x, current.y);
                break :blk;
            }
            current.x -= 1;
            Piece.translate(current.mask(), current.x, current.y);
        }
        if (rl.isKeyDown(.right)) blk: {
            const w = Piece.width(current.mask());
            Piece.clear(current.mask(), current.x, current.y);
            if (current.checkRightCollision() or current.x >= grid_width - w) {
                Piece.translate(current.mask(), current.x, current.y);
                break :blk;
            }
            current.x += 1;
            Piece.translate(current.mask(), current.x, current.y);
        }
        if (rl.isKeyPressed(.up)) {
            const prev_rot = current.rot;
            Piece.clear(current.mask(), current.x, current.y);
            current.rot = @as(u2, (current.rot +% 1) & 3);
            const w = Piece.width(current.mask());
            if (current.checkDownCollision(current.y) or current.checkLeftCollision() or current.checkRightCollision() or current.x + w > grid_width) {
                current.rot = prev_rot;
            }
            Piece.translate(current.mask(), current.x, current.y);
        }
        if (rl.isKeyDown(.down)) current.moveDown();

        if (time_since_last_fell >= fall_tick) {
            time_since_last_fell = 0;
            current.moveDown();
        }

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.black);
        drawGridShape();
        drawGridValues();
    }
}

fn tetris() void {
    var i = grid.len - 1;
    while (i > 0) : (i -= 1) {
        while (~grid[i] == 0) {
            grid[i] = 0;
            shiftAll(i - 1);
        }
    }
}

fn shiftAll(i: usize) void {
    if (grid[i + 1] != 0 or grid[i] == 0) return;
    grid[i + 1] = grid[i];
    grid[i] = 0;
    shiftAll(i - 1);
}

fn drawGridShape() void {
    // Borders
    rl.drawLineEx(
        .init(screen_grid_x_off, screen_grid_y_off),
        .init(screen_size - screen_grid_x_off, screen_grid_y_off),
        line_thick,
        .white,
    );
    rl.drawLineEx(
        .init(screen_grid_x_off, screen_grid_y_off),
        .init(screen_grid_x_off, screen_size - screen_grid_y_off),
        line_thick,
        .white,
    );
    rl.drawLineEx(
        .init(screen_grid_x_off, screen_size - screen_grid_y_off),
        .init(screen_size - screen_grid_x_off, screen_size - screen_grid_y_off),
        line_thick,
        .white,
    );
    rl.drawLineEx(
        .init(screen_size - screen_grid_x_off, screen_grid_y_off),
        .init(screen_size - screen_grid_x_off, screen_size - screen_grid_y_off),
        line_thick,
        .white,
    );

    //Grid lines
    for (1..grid_width) |n| {
        const x = screen_grid_x_off + (cell_size * @as(f32, @floatFromInt(n)));
        rl.drawLineEx(.init(x, screen_grid_y_off), .init(x, screen_size - screen_grid_y_off), 2, .dark_gray);
    }
    for (1..grid_height) |n| {
        const y = screen_grid_y_off + (cell_size * @as(f32, @floatFromInt(n)));
        rl.drawLineEx(.init(screen_grid_x_off, y), .init(screen_size - screen_grid_x_off, y), 2, .dark_gray);
    }
}

fn drawGridValues() void {
    for (grid, 0..) |row, n| {
        var col: u8 = 0;
        while (col < grid_width) : (col += 1) {
            if ((row & (@as(u10, 1) << @intCast(grid_width - 1 - col))) != 0) {
                fillCell(col, @intCast(n));
            }
        }
    }
}

fn fillCell(x_off: u8, y_off: u8) void {
    assert(0 <= x_off and x_off < grid_width);
    assert(0 <= y_off and y_off < grid_height);
    rl.drawRectangleV(
        .init(screen_grid_x_off + (cell_size * @as(u16, x_off)) + line_thick, screen_grid_y_off + (cell_size * @as(u16, y_off)) + line_thick),
        .init(cell_size - 2 * line_thick, cell_size - 2 * line_thick),
        .white,
    );
}
