const std = @import("std");
const rl = @import("raylib");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const print = std.debug.print;

const emscripten = std.os.emscripten;
const loop_callconv: std.builtin.CallingConvention = if (builtin.os.tag == .emscripten) .c else .auto;

const Screen = enum {
    game,
    end,
};

var screen = Screen.game;
const screen_size = 720;
const grid_height = 20;
const grid_width = 10;
const cell_size = 34;
const line_thick = 2;

var click: rl.Sound = undefined;
var beepboop: rl.Sound = undefined;
var fin: rl.Sound = undefined;

const screen_grid_x_off = (screen_size - (grid_width * cell_size)) / 2;
const screen_grid_y_off = (screen_size - (grid_height * cell_size)) / 2;

const fall_tick = 0.3; //fall every x seconds
var time_since_last_fell: f32 = 0;
var current: Current = undefined;

var score: u32 = 0;
const score_increase_base: f32 = 100;
const compound_factor: f32 = 1.2;

var prng: std.Random = undefined;

//big endian
var grid: [grid_height]u10 = @splat(0);

//each tetromino is 4x4 grid -- represented by a u16
//      1100
//      1100
//      0000
//      0000
const Tetr = enum {
    const size = 16;
    const side_length = size / 4;
    const rot_table = RotTable{};
    O,
    S,
    Z,
    I,
    T,
    L,
    J,
    fn rotation(self: Tetr, rot_index: u2) u16 {
        return switch (self) {
            .O => rot_table.O[0],
            .I => rot_table.I[rot_index % 2],
            .S => rot_table.S[rot_index % 2],
            .Z => rot_table.Z[rot_index % 2],
            .T => rot_table.T[rot_index],
            .L => rot_table.L[rot_index],
            .J => rot_table.J[rot_index],
        };
    }
};

const RotTable = struct {
    O: [1]u16 = .{0b1100_1100_0000_0000},
    I: [2]u16 = .{ 0b1000_1000_1000_1000, 0b1111_0000_0000_0000 },
    S: [2]u16 = .{ 0b0110_1100_0000_0000, 0b1000_1100_0100_0000 },
    Z: [2]u16 = .{ 0b1100_0110_0000_0000, 0b0100_1100_1000_0000 },
    T: [4]u16 = .{ 0b1110_0100_0000_0000, 0b0100_1100_0100_0000, 0b0100_1110_0000_0000, 0b1000_1100_1000_0000 },
    L: [4]u16 = .{ 0b1000_1000_1100_0000, 0b1110_1000_0000_0000, 0b1100_0100_0100_0000, 0b0010_1110_0000_0000 },
    J: [4]u16 = .{ 0b0100_0100_1100_0000, 0b1000_1110_0000_0000, 0b1100_1000_1000_0000, 0b1110_0010_0000_0000 },
};

fn indexRow(shape: u16, index: u2) u4 {
    const shift: u4 = Tetr.side_length - 1 - index;
    const nibble = (shape >> (Tetr.side_length * shift)) & 0b1111;
    return @intCast(nibble);
}

const ShapeRowIterator = struct {
    index: u4 = 0,
    fn next(self: *ShapeRowIterator, shape: u16) ?u4 {
        if (self.index >= Tetr.side_length) return null;
        const nibble = indexRow(shape, @intCast(self.index));
        return if (nibble != 0) blk: {
            self.index += 1;
            break :blk nibble;
        } else null;
    }
};

test "rotate" {
    var o = Current{ .kind = .O, .rot_index = 0 };
    var i = Current{ .kind = .I, .rot_index = 0 };
    try testing.expect(o.shape() == 0b1100_1100_0000_0000);
    o.rotate();
    try testing.expect(o.shape() == 0b1100_1100_0000_0000);
    try testing.expect(i.shape() == 0b1000_1000_1000_1000);
    i.rotate();
    try testing.expect(i.shape() == 0b1111_0000_0000_0000);
    i.rotate();
    try testing.expect(i.shape() == 0b1000_1000_1000_1000);
}

test "row iterator" {
    var l = Current{ .kind = .L };
    try testing.expect(l.shape() == Tetr.rot_table.L[0]);
    try testing.expect(l.width() == 2);
    l.rotate();
    try testing.expect(l.shape() == Tetr.rot_table.L[1]);
    try testing.expect(l.width() == 3);
    l.rotate();
    try testing.expect(l.shape() == Tetr.rot_table.L[2]);
    try testing.expect(l.width() == 2);
    l.rotate();
    try testing.expect(l.shape() == Tetr.rot_table.L[3]);
    try testing.expect(l.width() == 3);
}
const Current = struct {
    kind: Tetr,
    rot_index: u2 = 0,
    x: u4 = 0,
    y: u8 = 0,

    fn new(rng: std.Random, x: u4, rot_i: u2, prev_tetr: ?Tetr) Current {
        const kind = if (prev_tetr) |prev| choice(rng, prev) else rng.enumValue(Tetr);
        const w = shapeWidth(kind.rotation(rot_i));
        return .{
            .kind = kind,
            .x = if (x + w > grid_width) x - w else x,
            .y = 0,
            .rot_index = rot_i,
        };
    }

    fn shape(self: Current) u16 {
        return self.kind.rotation(self.rot_index);
    }

    fn isOverlapping(self: Current) bool {
        var rot = self;
        rot.rot_index +%= 1;
        const s = rot.shape();
        if (rot.x + rot.width() > grid_width) return true;
        if (rot.y + rot.height() > grid_height) return true;
        var shape_it = ShapeRowIterator{};
        for (0..Tetr.side_length) |i| {
            const shape_row = shape_it.next(s) orelse continue;
            const start = (grid_width - Tetr.side_length);
            if (start > self.x) {
                if (grid[rot.y + i] & (@as(u10, shape_row) << start - self.x) != 0) return true;
            } else {
                if (grid[rot.y + i] & (@as(u10, shape_row) >> self.x - start) != 0) return true;
            }
        }
        return false;
    }
    fn rotate(self: *Current) void {
        if (self.isOverlapping()) return;
        self.rot_index +%= 1;
    }

    fn translate(self: Current) void {
        var shift: u8 = 0;
        while (shift < Tetr.size) : (shift += 1) {
            if ((self.shape() << @as(u4, @intCast(shift))) & (0b1 << 15) != 0) {
                const row = shift / Tetr.side_length;
                const col = shift % Tetr.side_length;
                grid[self.y + row] |= @as(u10, 1) << @intCast(grid_width - 1 - (self.x + col));
            }
        }
    }

    fn clear(self: Current) void {
        var shift: u8 = 0;
        while (shift < Tetr.size) : (shift += 1) {
            if ((self.shape() << @as(u4, @intCast(shift))) & (0b1 << 15) != 0) {
                const row = shift / Tetr.side_length;
                const col = shift % Tetr.side_length;
                grid[self.y + row] ^= @as(u10, 1) << @intCast(grid_width - 1 - (self.x + col));
            }
        }
    }

    fn width(self: Current) u4 {
        return shapeWidth(self.shape());
    }

    fn height(self: Current) u4 {
        return shapeHeight(self.shape());
    }

    fn moveDown(self: *Current) void {
        self.clear();
        if (self.checkDownCollision(self.y + 1)) {
            self.translate();
            self.* = .new(prng, self.x, self.rot_index, self.kind);
            tetris();
            if (grid[0] != 0) endGame();
            self.translate();
        } else {
            self.y += 1;
            self.translate();
        }
    }

    fn checkDownCollision(self: Current, next_y: u8) bool {
        var it = ShapeRowIterator{};
        const s = self.shape();
        while (it.next(s)) |row| {
            if (next_y + it.index > grid_height) return true;
            const shift_i: i8 = (@as(i8, @intCast(grid_width)) - 4) - self.x;
            const shape_mask = if (shift_i >= 0) @as(u10, row) << @intCast(shift_i) else @as(u10, row) >> @intCast(@abs(shift_i));
            if (grid[next_y + it.index - 1] & shape_mask != 0) return true;
        }
        return false;
    }

    fn checkLeftCollision(self: Current) bool {
        var it = ShapeRowIterator{};
        const s = self.shape();
        while (it.next(s)) |row| {
            const leftmost = leftmostBit(row) orelse continue;
            if (grid[self.y + it.index - 1] & @as(u10, 1) << (grid_width - (self.x + leftmost)) != 0) return true;
        }
        return false;
    }
    //why does this need magic value 2?
    fn checkRightCollision(self: Current) bool {
        var it = ShapeRowIterator{};
        const s = self.shape();
        while (it.next(s)) |row| {
            const rightmost = rightmostBit(row) orelse continue;
            if (grid[self.y + it.index - 1] & @as(u10, 1) << (grid_width - 2 - (self.x + rightmost)) != 0) return true;
        }
        return false;
    }
};

//returns the index from the left, msb being 0
fn leftmostBit(row: u4) ?u2 {
    const max = 3;
    for (0..@bitSizeOf(u4)) |i| {
        if (row & @as(u4, 1) << max - @as(u2, @intCast(i)) != 0) return @intCast(i);
    }
    return null;
}

//returns the index from the left, msb being 0
fn rightmostBit(row: u4) ?u2 {
    const max = 3;
    for (0..@bitSizeOf(u4)) |i| {
        if (row & @as(u4, 1) << @as(u2, @intCast(i)) != 0) return @intCast(max - i);
    }
    return null;
}

test "mostbit" {
    try testing.expect(leftmostBit(0b0100) == 1);
    try testing.expect(leftmostBit(0b0111) == 1);
    try testing.expect(leftmostBit(0b1000) == 0);
    try testing.expect(leftmostBit(0b0001) == 3);
    try testing.expect(leftmostBit(0b0011) == 2);
    try testing.expect(leftmostBit(0b0000) == null);
    try testing.expect(rightmostBit(0b0101) == 3);
    try testing.expect(rightmostBit(0b0111) == 3);
    try testing.expect(rightmostBit(0b1000) == 0);
    try testing.expect(rightmostBit(0b0110) == 2);
    try testing.expect(rightmostBit(0b1100) == 1);
    try testing.expect(rightmostBit(0b0010) == 2);
    try testing.expect(rightmostBit(0b0000) == null);
}

fn choice(rand: std.Random, prev: Tetr) Tetr {
    var c: Tetr = prev;
    while (c == prev) {
        c = rand.enumValue(Tetr);
    }
    return c;
}

fn shapeWidth(shape: u16) u4 {
    var it = ShapeRowIterator{};
    var w: u4 = 0;
    while (it.next(shape)) |row| {
        var shift: u4 = 0;
        while (shift < Tetr.side_length) : (shift += 1) {
            if ((row >> @intCast(shift)) & @as(u10, 0b1) != 0) w = @max(Tetr.side_length - @as(u4, shift), w);
        }
    }
    return w;
}

fn shapeHeight(shape: u16) u4 {
    var height: u4 = 4;
    for (0..@bitSizeOf(u4)) |i| {
        if (shape & @as(u16, 0b1111) << Tetr.side_length * @as(u4, @intCast(i)) != 0) break;
        height -= 1;
    }
    return height;
}

test "width" {
    const o = Current{ .kind = .O };
    const i = Current{ .kind = .I };
    const s = Current{ .kind = .S };
    const z = Current{ .kind = .Z };
    const l = Current{ .kind = .L };
    const j = Current{ .kind = .J };
    const t = Current{ .kind = .T };
    try testing.expect(o.width() == 2);
    try testing.expect(i.width() == 1);
    try testing.expect(s.width() == 3);
    try testing.expect(z.width() == 3);
    try testing.expect(l.width() == 2);
    try testing.expect(t.width() == 3);
    try testing.expect(j.width() == 2);
}

test "height" {
    const o = Current{ .kind = .O };
    const i = Current{ .kind = .I };
    const s = Current{ .kind = .S };
    const z = Current{ .kind = .Z };
    const l = Current{ .kind = .L };
    const j = Current{ .kind = .J };
    const t = Current{ .kind = .T };
    try testing.expect(o.height() == 2);
    try testing.expect(i.height() == 4);
    try testing.expect(s.height() == 2);
    try testing.expect(z.height() == 2);
    try testing.expect(l.height() == 3);
    try testing.expect(t.height() == 2);
    try testing.expect(j.height() == 3);
}
fn tetris() void {
    var i = grid.len - 1;
    var increase: f32 = 0;
    while (i > 0) : (i -= 1) {
        while (~grid[i] == 0) {
            if (increase == 0) increase = 100;
            grid[i] = 0;
            shiftAll(i - 1);
            increase *= compound_factor;
        }
    }
    if (increase == 0) rl.playSound(click) else rl.playSound(beepboop);
    score += @round(increase);
}

test "score" {
    score = 0;
    const cf: f32 = 1.2 * 1.2 * 1.2 * 1.2;
    score += @as(u32, @round(score_increase_base * cf));
    print("score: {}\n", .{score});
}

fn shiftAll(i: usize) void {
    if (grid[i + 1] != 0 or grid[i] == 0) return;
    grid[i + 1] = grid[i];
    grid[i] = 0;
    return shiftAll(i - 1);
}

fn endGame() void {
    rl.playSound(fin);
    screen = .end;
}

fn resetGame() void {
    grid = @splat(0);
    score = 0;
    current = .new(prng, 5, 0, null);
    current.translate();
}

pub fn main(init: std.process.Init) !void {
    rl.initWindow(screen_size, screen_size, "Tetris Clone");
    defer rl.closeWindow();

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    click = try rl.loadSound("resources/click.wav");
    beepboop = try rl.loadSound("resources/beepboop.wav");
    fin = try rl.loadSound("resources/wiggle.wav");

    var rand = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(init.io, .real).toMilliseconds()));
    prng = rand.random();

    current = .new(prng, 5, 0, null);
    current.translate();

    if (builtin.os.tag == .emscripten) {
        emscripten.emscripten_set_main_loop(&doEverything, 15, 1);
    } else {
        rl.setWindowPosition(0, 0);

        rl.setTargetFPS(15);
        while (!rl.windowShouldClose()) {
            doEverything();
        }
    }
}

fn doEverything() callconv(loop_callconv) void {
    switch (screen) {
        .game => {
            const dt = rl.getFrameTime();
            time_since_last_fell += dt;

            if (rl.isKeyDown(.left) and current.x > 0) blk: {
                current.clear();
                if (current.checkLeftCollision()) {
                    current.translate();
                    break :blk;
                }
                current.x -= 1;
                current.translate();
            }
            if (rl.isKeyDown(.right)) blk: {
                if (current.x >= grid_width - current.width()) break :blk;
                current.clear();
                if (current.checkRightCollision()) {
                    current.translate();
                    break :blk;
                }
                current.x += 1;
                current.translate();
            }
            if (rl.isKeyDown(.down)) {
                current.moveDown();
            }
            if (rl.isKeyPressed(.up)) {
                current.clear();
                current.rotate();
                current.translate();
            }

            if (time_since_last_fell >= fall_tick) {
                time_since_last_fell = 0;
                current.moveDown();
            }

            rl.beginDrawing();
            defer rl.endDrawing();

            rl.clearBackground(.black);
            drawText();
            drawGridShape();
            drawGridValues();
        },
        .end => blk: {
            rl.beginDrawing();
            defer rl.endDrawing();

            if (rl.isKeyPressed(.space)) {
                resetGame();
                screen = .game;
                break :blk;
            }
            rl.clearBackground(.black);
            drawEnd();
        },
    }
}

fn drawText() void {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buffer, "Score:\n{}", .{score}, 0) catch "Score: <error>";
    rl.drawText(text, @intCast(screen_grid_x_off - 170), @intCast(screen_grid_y_off + 200), 40, .white);
}

fn drawEnd() void {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buffer, "Score:{}", .{score}, 0) catch "Score: <error>";
    rl.drawText(text, 100, @intCast(screen_size / 2 - 100), 40, .white);
    rl.drawText("Space to play again", 100, @intCast(screen_size / 2), 40, .white);
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
