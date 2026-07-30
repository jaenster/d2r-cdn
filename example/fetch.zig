//! Minimal library user: resolve the current osi build and pull one install file,
//! verifying md5 == CKey. The CLI does this and more: `d2r-cdn fetch D2R.exe`.
//!   zig build example && ./zig-out/bin/d2r-fetch
const std = @import("std");
const tact = @import("tact");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    const want = "D2R.exe"; // change this to pull a different install file

    const cdn = try tact.Cdn.open(gpa, threaded.io(), .{});
    defer cdn.close();
    std.debug.print("osi build {s} - extracting {s}\n", .{ cdn.version, want });

    const data = try cdn.extractInstall(want);
    defer gpa.free(data);
    var dig: tact.Hash = undefined;
    tact.Md5.hash(data, &dig, .{});
    std.debug.print("{d} bytes, md5={s}, magic={s}\n", .{ data.len, std.fmt.bytesToHex(dig, .lower), data[0..@min(2, data.len)] });
}
