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

//Rows are represented by u16
var grid: [grid_height]u16 = @splat(0);

//each tetromino is 4x4 grid -- represented by a u16
//      0000
//      0110
//      0110
//      0000
const Tetr = enum(u16) {
    o = 0b0000_0110_0110_0000,
};

pub fn main(init: std.process.Init) !void {
    _ = init;
    rl.initWindow(screen_size, screen_size, "Tetris Clone");
    defer rl.closeWindow();

    rl.setWindowPosition(0, 0);

    while (!rl.windowShouldClose()) {
        grid[grid_height / 2] = 0b11 << 4;
        grid[grid_height / 2 + 1] = 0b11 << 4;

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

fn fillCell(x_off: u8, y_off: u8) void {
    assert(0 < x_off and x_off <= grid_width);
    assert(0 < y_off and y_off <= grid_height);
    rl.drawRectangleV(
        .init(screen_grid_x_off + (cell_size * @as(u16, x_off - 1)) + line_thick, screen_grid_y_off + (cell_size * @as(u16, y_off - 1)) + line_thick),
        .init(cell_size - 2 * line_thick, cell_size - 2 * line_thick),
        .white,
    );
}

fn drawGridValues() void {
    for (grid, 0..) |row, n| {
        var shift: u4 = 0;
        while (shift < grid_width) : (shift += 1) {
            if ((row >> shift) & @as(u16, 1) != 0) {
                //fill cell + shift from the right
                fillCell(grid_width - shift, @intCast(n + 1));
            }
        }
    }
}
