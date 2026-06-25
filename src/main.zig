const std = @import("std");
const rl = @import("raylib");
const assert = std.debug.assert;

const screen_size = 720;
const grid_height = 20;
const grid_width = 10;
const cell_size = 34;
const line_thick = 2;

const screen_grid_x_off = (screen_size - (grid_width * cell_size)) / 2;
const screen_grid_y_off = (screen_size - (grid_height * cell_size)) / 2;

const fall_speed = 1; //cells per second
var time_since_last_fell: f32 = 0;
var current: Current = undefined;

//Rows are represented by u16
var grid: [grid_height]u16 = @splat(0);

//each tetromino is 4x4 grid -- represented by a u16
//      1100
//      1100
//      0000
//      0000
const Tetr = enum(u16) {
    const size = 16;
    const n_rows = size / 4;
    O = 0b1100_1100_0000_0000,
    S = 0b0110_1100_0000_0000,
    Z = 0b1100_0110_0000_0000,
    I = 0b1000_1000_1000_1000,

    fn translate(self: Tetr, x: u8, y: u8) void {
        var shift: u8 = 0;
        while (shift < size) : (shift += 1) {
            if ((@intFromEnum(self) << @as(u4, @intCast(shift))) & (0b1 << 15) != 0) {
                const row = shift / n_rows;
                const col = shift % n_rows;
                grid[y + row] |= @as(u16, 1) << @intCast(x + col);
            }
        }
    }

    fn clear(self: Tetr, x: u8, y: u8) void {
        var shift: u8 = 0;
        while (shift < size) : (shift += 1) {
            if ((@intFromEnum(self) << @as(u4, @intCast(shift))) & (0b1 << 15) != 0) {
                const row = shift / n_rows;
                const col = shift % n_rows;
                grid[y + row] ^= @as(u16, 1) << @intCast(x + col);
            }
        }
    }
};

const Current = struct {
    kind: Tetr,
    x_pos: u8,
    y_pos: u8,

    fn fall(self: *Current) void {
        if (time_since_last_fell < 1) return;
        time_since_last_fell = 0;
        self.kind.clear(self.x_pos, self.y_pos);
        self.y_pos += 1;
        self.kind.translate(self.x_pos, self.y_pos);
    }
};

pub fn main(init: std.process.Init) !void {
    _ = init;
    rl.initWindow(screen_size, screen_size, "Tetris Clone");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setWindowPosition(0, 0);

    current = .{
        .kind = .O,
        .x_pos = 0,
        .y_pos = 0,
    };
    current.kind.translate(current.x_pos, current.y_pos);

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        time_since_last_fell += dt;

        current.fall();

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
            if ((row & (@as(u16, 1) << @intCast(col))) != 0) {
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
