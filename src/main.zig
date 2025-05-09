const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Mode = enum {
    encode,
    decode,

    pub fn parse(string: []const u8) ?Mode {
        const map = std.StaticStringMap(Mode).initComptime(.{
            .{ "e", .encode },
            .{ "-e", .encode },
            .{ "--encode", .encode },
            .{ "d", .decode },
            .{ "-d", .decode },
            .{ "--decode", .decode },
        });

        return map.get(string);
    }
};

const Options = struct {
    mode: Mode,
    input: []const u8,
    output: []const u8,
};

fn parseArgs(args: []const []const u8) !Options {
    assert(args.len != 0);
    if (args.len < 4) failUsage(args[0]);

    const mode = Mode.parse(args[1]) orelse failUsage(args[0]);
    return .{ .mode = mode, .input = args[2], .output = args[3] };
}

// incorrect command-line options
fn failUsage(program: []const u8) noreturn {
    std.io.getStdErr().writer().print(
        \\Usage: {s} [OPTIONS] INPUT OUTPUT
        \\
        \\Options:
        \\  e, -e, --encode    Encode INPUT [Any] to OUTPUT [PPM]
        \\  d, -d, --decode    Decode INPUT [PPM] to OUTPUT [Any]
        \\
    , .{program}) catch {};
    std.process.exit(1);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    const options = try parseArgs(args);

    const in_file = try std.fs.cwd().openFile(options.input, .{});
    defer in_file.close();

    const out_file = try std.fs.cwd().createFile(options.output, .{});
    defer out_file.close();

    switch (options.mode) {
        .encode => try encode(gpa, in_file, out_file),
        .decode => try decode(gpa, in_file, out_file),
    }
}

fn encode(gpa: Allocator, in_file: std.fs.File, out_file: std.fs.File) !void {
    const input_stat = try in_file.stat();
    const input_len: usize = @intCast(input_stat.size);

    var br = std.io.bufferedReader(in_file.reader());
    const reader = br.reader();

    // Compute size of output image, include extra byte for marking the end
    const pixel_count: usize = (input_len / 3) + 1;
    const sqrt_pixels = @sqrt(@as(f64, @floatFromInt(pixel_count)));
    const side_pow: u6 = @intFromFloat(@ceil(@log2(sqrt_pixels)));
    const side = @as(usize, 1) << side_pow;

    // multiply by 3 for RGB
    const grid = try gpa.alloc(u8, 3 * side * side);
    defer gpa.free(grid);
    @memset(grid, 0);

    // Place each value at the correct location in the buffer
    var idx: usize = 0;
    while (idx < input_len) {
        const pixel: usize = idx / 3;
        const mapped_pixel = mapHilbert(side_pow, pixel);

        var channel: usize = 0;
        while (channel < 3 and idx < input_len) {
            const mapped_idx = mapped_pixel * 3 + channel;
            grid[mapped_idx] = try reader.readByte();

            channel += 1;
            idx += 1;
        }
    }

    // Add a trailing 0xFF to mark where the file ends
    const pixel = input_len / 3;
    const channel = input_len % 3;
    const mapped_pixel = mapHilbert(side_pow, pixel);
    const mapped_idx = mapped_pixel * 3 + channel;
    grid[mapped_idx] = 0xFF;

    // Encode as a PPM
    try out_file.writer().print("P6\n{} {}\n255\n", .{ side, side });
    try out_file.writer().writeAll(grid);
}

const PPM = struct {
    width: usize,
    height: usize,
    rgb_data: []const u8,

    pub fn parse(data: []const u8) !PPM {
        // TODO: better parsing, supporting comments

        var toker = std.mem.splitAny(u8, data, &std.ascii.whitespace);

        // Parse the P6 PPM magic bytes
        const pnm_type = toker.next() orelse return error.InvalidPPM;
        if (!std.mem.eql(u8, pnm_type, "P6")) return error.InvalidPPM;

        // Parse the image width
        const width_str = toker.next() orelse return error.InvalidPPM;
        const width_parse = std.fmt.parseInt(usize, width_str, 10);
        const width = width_parse catch return error.InvalidPPM;

        // Parse the image height
        const height_str = toker.next() orelse return error.InvalidPPM;
        const height_parse = std.fmt.parseInt(usize, height_str, 10);
        const height = height_parse catch return error.InvalidPPM;

        // Ensure we are working with max byte values of 255
        const depth_str = toker.next() orelse return error.InvalidPPM;
        if (!std.mem.eql(u8, depth_str, "255")) return error.InvalidPPM;

        // Ensure the data is as long as the header says it is
        const rgb_data = toker.rest();

        return .{ .width = width, .height = height, .rgb_data = rgb_data };
    }
};

fn decodeDataLength(rgb_data: []const u8, side_pow: u6) !usize {
    if (rgb_data.len == 0) return 0;

    var data_end: usize = rgb_data.len - 1;
    while (true) {
        const pixel = data_end / 3;
        const channel = data_end % 3;
        const mapped_pixel = mapHilbert(side_pow, pixel);
        const mapped_idx = mapped_pixel * 3 + channel;
        const byte = rgb_data[mapped_idx];

        if (byte == 0xFF) return data_end;
        if (data_end == 0) return error.InvalidData;
        data_end -= 1;
    }
}

fn decode(gpa: Allocator, in_file: std.fs.File, out_file: std.fs.File) !void {
    const in_data = try in_file.readToEndAlloc(gpa, std.math.maxInt(usize));
    defer gpa.free(in_data);

    const ppm: PPM = try .parse(in_data);
    if (ppm.height != ppm.width) return error.InvalidData;
    if (@popCount(ppm.width) != 1) return error.InvalidData;

    var bw = std.io.bufferedWriter(out_file.writer());
    const writer = bw.writer();

    const side_pow: u6 = @intCast(@bitSizeOf(usize) - 1 - @clz(ppm.width));
    const data_length = try decodeDataLength(ppm.rgb_data, side_pow);

    var idx: usize = 0;
    while (idx < data_length) {
        const pixel: usize = idx / 3;
        const mapped_pixel = mapHilbert(side_pow, pixel);

        var channel: usize = 0;
        while (channel < 3 and idx < data_length) {
            const mapped_idx = mapped_pixel * 3 + channel;
            const byte = ppm.rgb_data[mapped_idx];
            try writer.writeByte(byte);

            channel += 1;
            idx += 1;
        }
    }

    try bw.flush();
}

// side_pow: grid is 2^side_pow by 2^side_pow
fn mapHilbert(side_pow: u6, idx: usize) usize {
    var x: usize = 0;
    var y: usize = 0;
    var t: usize = idx;
    var s: usize = 1;

    for (0..side_pow) |_| {
        const rx = 1 & (t / 2);
        const ry = 1 & (t ^ rx);

        if (ry == 0) {
            if (rx == 1) {
                x = s - 1 - x;
                y = s - 1 - y;
            }

            const temp = x;
            x = y;
            y = temp;
        }

        x += s * rx;
        y += s * ry;
        t = t / 4;
        s *= 2;
    }

    return x + (y << @intCast(side_pow));
}
