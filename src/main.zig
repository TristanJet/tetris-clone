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
var current: Current = undefined;

var prng: std.Random = undefined;

//big endian
var grid: [grid_height]u10 = @splat(0);

//each tetromino is 4x4 grid -- represented by a u16
//      1100
//      1100
//      0000
//      0000
const Tetr = enum(u16) {
    const Row = struct {
        bits: u10,
        height: u4,
    };

    const Iterator = struct {
        index: u4 = 0,
        fn next(self: *Iterator, tetr: Tetr) ?u4 {
            if (self.index >= side_length) return null;
            const nibble = tetr.indexRow(@intCast(self.index));
            return if (nibble != 0) blk: {
                self.index += 1;
                break :blk nibble;
            } else null;
        }
    };
    const size = 16;
    const side_length = size / 4;
    O = 0b1100_1100_0000_0000,
    S = 0b0110_1100_0000_0000,
    Z = 0b1100_0110_0000_0000,
    I = 0b1000_1000_1000_1000,
    T = 0b1110_0100_0000_0000,
    L = 0b1000_1110_0000_0000,
    J = 0b0010_1110_0000_0000,

    fn indexRow(self: Tetr, index: u2) u4 {
        const shift: u4 = side_length - 1 - index;
        const nibble = (@intFromEnum(self) >> (side_length * shift)) & 0b1111;
        return @intCast(nibble);
    }

    fn translate(self: Tetr, x: u8, y: u8) void {
        var shift: u8 = 0;
        while (shift < size) : (shift += 1) {
            if ((@intFromEnum(self) << @as(u4, @intCast(shift))) & (0b1 << 15) != 0) {
                const row = shift / side_length;
                const col = shift % side_length;
                grid[y + row] |= @as(u10, 1) << @intCast(grid_width - 1 - (x + col));
            }
        }
    }

    fn clear(self: Tetr, x: u8, y: u8) void {
        var shift: u8 = 0;
        while (shift < size) : (shift += 1) {
            if ((@intFromEnum(self) << @as(u4, @intCast(shift))) & (0b1 << 15) != 0) {
                const row = shift / side_length;
                const col = shift % side_length;
                grid[y + row] ^= @as(u10, 1) << @intCast(grid_width - 1 - (x + col));
            }
        }
    }

    fn width(self: Tetr) u4 {
        var it = Iterator{};
        var w: u4 = 0;
        while (it.next(self)) |row| {
            var shift: u4 = 0;
            while (shift < side_length) : (shift += 1) {
                if ((row >> @intCast(shift)) & @as(u10, 0b1) != 0) w = @max(side_length - @as(u4, shift), w);
            }
        }
        return w;
    }
};

test "row iterator" {
    const o: Tetr = .O;
    const i: Tetr = .I;
    const t: Tetr = .T;
    var it = Tetr.Iterator{};
    try testing.expect(o.indexRow(0) == 0b1100);
    try testing.expect(o.indexRow(1) == 0b1100);
    try testing.expect(o.indexRow(2) == 0b0000);
    try testing.expect(o.indexRow(3) == 0b0000);
    try testing.expect(it.next(o).? == 0b1100);
    try testing.expect(it.next(o).? == 0b1100);
    try testing.expect(it.next(o) == null);
    try testing.expect(it.next(o) == null);
    try testing.expect(it.next(o) == null);
    it = Tetr.Iterator{};
    for (0..4) |_| try testing.expect(it.next(i) == 0b1000);
    it = Tetr.Iterator{};
    try testing.expect(it.next(t).? == 0b1110);
    try testing.expect(it.next(t).? == 0b0100);
}

test "width" {
    const o: Tetr = .O;
    const i: Tetr = .I;
    const s: Tetr = .S;
    const z: Tetr = .Z;
    const l: Tetr = .L;
    const j: Tetr = .J;
    const t: Tetr = .T;
    try testing.expect(o.width() == 2);
    try testing.expect(i.width() == 1);
    try testing.expect(s.width() == 3);
    try testing.expect(z.width() == 3);
    try testing.expect(l.width() == 3);
    try testing.expect(t.width() == 3);
    try testing.expect(j.width() == 3);
}

const Current = struct {
    kind: Tetr,
    x: u4,
    y: u8,

    fn new(rng: std.Random, x: u4) Current {
        const kind = rng.enumValue(Tetr);
        const w = kind.width();
        return .{
            .kind = kind,
            .x = if (x + w > grid_width) x - kind.width() else x,
            .y = 0,
        };
    }

    fn moveDown(self: *Current) void {
        self.kind.clear(self.x, self.y);
        if (self.checkDownCollision(self.y + 1)) {
            self.kind.translate(self.x, self.y);
            self.* = .new(prng, self.x);
            tetris();
            self.kind.translate(self.x, self.y);
        } else {
            self.y += 1;
            self.kind.translate(self.x, self.y);
        }
    }

    fn checkDownCollision(self: Current, next_y: u8) bool {
        var it = Tetr.Iterator{};
        while (it.next(self.kind)) |row| {
            if (next_y + it.index > grid_height) return true;
            const shift_i: i8 = (@as(i8, @intCast(grid_width)) - 4) - self.x;
            const shape_mask = if (shift_i >= 0) @as(u10, row) << @intCast(shift_i) else @as(u10, row) >> @intCast(@abs(shift_i));
            if (grid[next_y + it.index - 1] & shape_mask != 0) return true;
        }
        return false;
    }
};

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

pub fn main(init: std.process.Init) !void {
    rl.initWindow(screen_size, screen_size, "Tetris Clone");
    defer rl.closeWindow();

    rl.setTargetFPS(15);
    rl.setWindowPosition(0, 0);

    var rand = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(init.io, .real).toMilliseconds()));
    prng = rand.random();

    current = .new(prng, 5);
    current.kind.translate(current.x, current.y);

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        time_since_last_fell += dt;

        if (rl.isKeyDown(.left) and current.x > 0) {
            current.kind.clear(current.x, current.y);
            current.x -= 1;
            current.kind.translate(current.x, current.y);
        }
        if (rl.isKeyDown(.right)) blk: {
            const width: u10 = current.kind.width();
            if (current.x >= grid_width - width) break :blk;
            current.kind.clear(current.x, current.y);
            current.x += 1;
            current.kind.translate(current.x, current.y);
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
