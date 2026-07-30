//! Example CLI built on the `tact` library: resolve the current osi build and pull
//! one install file (default D2R.exe), verifying md5 == CKey.
//!   zig build && ./zig-out/bin/d2r-fetch            # info for D2R.exe
//!   ./zig-out/bin/d2r-fetch D2R_loader.dll
const std = @import("std");
const tact = @import("tact");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    const want = "D2R.exe"; // change this to pull a different install file

    var cdn = try tact.Cdn.open(gpa, threaded.io(), "osi", "us");
    defer cdn.close();
    std.debug.print("osi build {s} - extracting {s}\n", .{ cdn.version, want });

    const data = try cdn.extractInstall(want);
    var dig: [16]u8 = undefined;
    tact.Md5.hash(data, &dig, .{});
    std.debug.print("{d} bytes, md5={s}, magic={s}\n", .{ data.len, std.fmt.bytesToHex(dig, .lower), data[0..@min(2, data.len)] });
}
