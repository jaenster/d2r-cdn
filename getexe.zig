// getexe.zig - extract ALL binaries (D2R.exe, DLLs, ...) from a D2R build as fast as
// possible. Resolves the install manifest -> each file's CKey -> EKey via encoding ->
// scans the archive indices ONCE to locate them -> byte-range-fetches each slice ->
// BLTE-decodes -> writes the named file into ./<out>/. ~86MB instead of the 37GB build.
//
//   zig build-exe getexe.zig && ./getexe            # -> ./binaries/D2R.exe, ...
//   PRODUCT and REGION are consts below; OUT dir defaults to "binaries".
const std = @import("std");
const http = std.http;
const flate = std.compress.flate;
const Md5 = std.crypto.hash.Md5;

const PRODUCT = "osi";
const REGION = "us";
const OUT = "binaries";

var client: http.Client = undefined;
var io_: std.Io = undefined;

fn get(gpa: std.mem.Allocator, url: []const u8, range: ?[]const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    errdefer aw.deinit();
    var hdr: [1]http.Header = undefined;
    var extra: []const http.Header = &.{};
    if (range) |r| {
        hdr[0] = .{ .name = "range", .value = r };
        extra = hdr[0..1];
    }
    const res = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &aw.writer, .extra_headers = extra });
    if (res.status != .ok and res.status != .partial_content) return error.Http;
    return aw.toOwnedSlice();
}

fn field(line: []const u8, idx: usize) []const u8 {
    var it = std.mem.splitScalar(u8, line, '|');
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) if (i == idx) return f;
    return "";
}
fn regionLine(text: []const u8, region: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |ln| {
        const l = std.mem.trimEnd(u8, ln, "\r");
        if (l.len == 0 or l[0] == '#' or std.mem.indexOfScalar(u8, l, '!') != null) continue;
        if (std.mem.eql(u8, field(l, 0), region)) return l;
    }
    return "";
}
fn cfgTok(text: []const u8, key: []const u8, n: usize) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |ln| {
        const l = std.mem.trimEnd(u8, ln, "\r");
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, l[0..eq], " "), key)) continue;
        var it = std.mem.tokenizeAny(u8, l[eq + 1 ..], " \r");
        var i: usize = 0;
        while (it.next()) |t| : (i += 1) if (i == n) return t;
    }
    return "";
}
fn cfgLine(text: []const u8, key: []const u8) []const u8 { // whole value after "key = "
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |ln| {
        const l = std.mem.trimEnd(u8, ln, "\r");
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, l[0..eq], " "), key)) return std.mem.trim(u8, l[eq + 1 ..], " ");
    }
    return "";
}

fn blte(gpa: std.mem.Allocator, data: []const u8) anyerror![]u8 {
    if (data.len < 8 or !std.mem.eql(u8, data[0..4], "BLTE")) return error.NotBlte;
    const hs = std.mem.readInt(u32, data[4..8], .big);
    var out = std.Io.Writer.Allocating.init(gpa);
    errdefer out.deinit();
    if (hs == 0) {
        try chunk(gpa, &out.writer, data[8..]);
        return out.toOwnedSlice();
    }
    const n = std.mem.readInt(u24, data[9..12], .big);
    var tbl: usize = 12;
    var dat: usize = 12 + @as(usize, n) * 24;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cs = std.mem.readInt(u32, data[tbl..][0..4], .big);
        tbl += 24;
        try chunk(gpa, &out.writer, data[dat..][0..cs]);
        dat += cs;
    }
    return out.toOwnedSlice();
}
fn chunk(gpa: std.mem.Allocator, out: *std.Io.Writer, raw: []const u8) anyerror!void {
    switch (raw[0]) {
        'N' => try out.writeAll(raw[1..]),
        'Z' => {
            var in = std.Io.Reader.fixed(raw[1..]);
            var win: [flate.max_window_len]u8 = undefined;
            var dec = flate.Decompress.init(&in, .zlib, &win);
            const d = try dec.reader.allocRemaining(gpa, .unlimited);
            defer gpa.free(d);
            try out.writeAll(d);
        },
        'F' => {
            const s = try blte(gpa, raw[1..]);
            defer gpa.free(s);
            try out.writeAll(s);
        },
        else => return error.Mode,
    }
}

const Cur = struct {
    b: []const u8,
    p: usize = 0,
    fn u8_(c: *Cur) u8 {
        defer c.p += 1;
        return c.b[c.p];
    }
    fn u16be(c: *Cur) u16 {
        defer c.p += 2;
        return std.mem.readInt(u16, c.b[c.p..][0..2], .big);
    }
    fn u32be(c: *Cur) u32 {
        defer c.p += 4;
        return std.mem.readInt(u32, c.b[c.p..][0..4], .big);
    }
    fn u40be(c: *Cur) u64 {
        var v: u64 = 0;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            v = (v << 8) | c.b[c.p];
            c.p += 1;
        }
        return v;
    }
    fn str(c: *Cur) []const u8 {
        const s = c.p;
        while (c.p < c.b.len and c.b[c.p] != 0) c.p += 1;
        defer c.p += 1;
        return c.b[s..c.p];
    }
    fn skip(c: *Cur, n: usize) void {
        c.p += n;
    }
};

const Bin = struct {
    name: []const u8,
    ckey: [16]u8,
    ekey: [16]u8 = undefined,
    arch: []const u8 = "",
    off: u64 = 0,
    size: u64 = 0,
    loose: bool = false,
};

fn encFindEKey(enc: []const u8, target: []const u8) ?[16]u8 {
    var c = Cur{ .b = enc, .p = 2 };
    _ = c.u8_();
    const cks = c.u8_();
    const eks = c.u8_();
    const ckkb = c.u16be();
    _ = c.u16be();
    const ckp = c.u32be();
    _ = c.u32be();
    _ = c.u8_();
    const espec = c.u32be();
    c.skip(espec);
    c.skip(@as(usize, ckp) * (@as(usize, cks) + 16));
    const page = @as(usize, ckkb) * 1024;
    var pg: usize = 0;
    while (pg < ckp) : (pg += 1) {
        const ps = c.p;
        while (c.p + 1 < ps + page) {
            const kc = c.b[c.p];
            if (kc == 0) break;
            c.p += 1;
            _ = c.u40be();
            const ckey = c.b[c.p..][0..cks];
            c.p += cks;
            const eks_at = c.p;
            c.p += @as(usize, kc) * eks;
            if (std.mem.eql(u8, ckey, target)) {
                var o: [16]u8 = undefined;
                @memcpy(&o, enc[eks_at..][0..16]);
                return o;
            }
        }
        c.p = ps + page;
    }
    return null;
}

fn readBE(b: []const u8) u64 {
    var v: u64 = 0;
    for (b) |x| v = (v << 8) | x;
    return v;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    io_ = threaded.io();
    client = .{ .allocator = gpa, .io = io_ };
    defer client.deinit();

    const patch = "http://" ++ REGION ++ ".patch.battle.net:1119/" ++ PRODUCT;
    const vrow = regionLine(try get(gpa, patch ++ "/versions", null), REGION);
    const crow = regionLine(try get(gpa, patch ++ "/cdns", null), REGION);
    const bch = field(vrow, 1);
    var hosts = std.mem.tokenizeScalar(u8, field(crow, 2), ' ');
    const base = try std.fmt.allocPrint(gpa, "http://{s}/{s}", .{ hosts.next().?, field(crow, 1) });
    const du = struct {
        fn f(a: std.mem.Allocator, b: []const u8, k: []const u8) ![]u8 {
            return std.fmt.allocPrint(a, "{s}/data/{s}/{s}/{s}", .{ b, k[0..2], k[2..4], k });
        }
    }.f;
    const build = try get(gpa, try std.fmt.allocPrint(gpa, "{s}/config/{s}/{s}/{s}", .{ base, bch[0..2], bch[2..4], bch }), null);
    std.debug.print("[getexe] {s} build {s}\n", .{ PRODUCT, field(vrow, 5) });

    // 1. install manifest -> ALL (name, CKey)
    const inst = try blte(gpa, try get(gpa, try du(gpa, base, cfgTok(build, "install", 1)), null));
    var bins: [128]Bin = undefined;
    var nb: usize = 0;
    {
        var c = Cur{ .b = inst, .p = 2 };
        _ = c.u8_();
        const hsz = c.u8_();
        const ntags = c.u16be();
        const nent = c.u32be();
        const mask = (nent + 7) / 8;
        var t: usize = 0;
        while (t < ntags) : (t += 1) {
            _ = c.str();
            _ = c.u16be();
            c.skip(mask);
        }
        var e: usize = 0;
        while (e < nent and nb < bins.len) : (e += 1) {
            const name = c.str();
            var ck: [16]u8 = undefined;
            @memcpy(&ck, c.b[c.p..][0..16]);
            c.skip(hsz);
            _ = c.u32be();
            bins[nb] = .{ .name = name, .ckey = ck };
            nb += 1;
        }
    }
    std.debug.print("[getexe] install lists {d} files\n", .{nb});

    // 2. encoding -> EKey for each
    const enc = try blte(gpa, try get(gpa, try du(gpa, base, cfgTok(build, "encoding", 1)), null));
    for (bins[0..nb]) |*b| b.ekey = encFindEKey(enc, &b.ckey) orelse b.ckey;

    // 3. scan archive indices ONCE, locate every EKey
    const cdnh = field(vrow, 2);
    const cdncfg = try get(gpa, try std.fmt.allocPrint(gpa, "{s}/config/{s}/{s}/{s}", .{ base, cdnh[0..2], cdnh[2..4], cdnh }), null);
    var located: usize = 0;
    var ai = std.mem.tokenizeAny(u8, cfgLine(cdncfg, "archives"), " \r");
    while (ai.next()) |ah| {
        if (located == nb) break;
        const idx = get(gpa, try std.fmt.allocPrint(gpa, "{s}/data/{s}/{s}/{s}.index", .{ base, ah[0..2], ah[2..4], ah }), null) catch continue;
        if (idx.len < 28) continue;
        const foot = idx[idx.len - 28 ..];
        const blk = @as(usize, foot[11]) * 1024;
        const ob = foot[12];
        const sb = foot[13];
        const kb = foot[14];
        const ne = std.mem.readInt(u32, foot[16..20], .little);
        const ent = @as(usize, kb) + sb + ob;
        if (ent == 0) continue;
        const per = blk / ent;
        var cnt: usize = 0;
        var pg: usize = 0;
        outer: while (cnt < ne) : (pg += 1) {
            var e: usize = 0;
            while (e < per) : (e += 1) {
                const pos = pg * blk + e * ent;
                if (pos + ent > idx.len) break :outer;
                const key = idx[pos..][0..kb];
                if (std.mem.eql(u8, key, "\x00" ** 16)) continue;
                cnt += 1;
                for (bins[0..nb]) |*b| {
                    if (b.arch.len == 0 and std.mem.eql(u8, key[0..16], &b.ekey)) {
                        b.size = readBE(idx[pos + kb ..][0..sb]);
                        b.off = readBE(idx[pos + kb + sb ..][0..ob]);
                        b.arch = ah;
                        located += 1;
                    }
                }
                if (cnt >= ne) break :outer;
            }
        }
    }

    // 4. fetch + decode + write each into the current directory
    const outdir = std.Io.Dir.cwd();
    var total: u64 = 0;
    var wrote: usize = 0;
    for (bins[0..nb]) |*b| {
        var raw: []u8 = undefined;
        if (b.arch.len != 0) {
            const range = try std.fmt.allocPrint(gpa, "bytes={d}-{d}", .{ b.off, b.off + b.size - 1 });
            raw = get(gpa, try du(gpa, base, b.arch), range) catch {
                std.debug.print("  {s}: FETCH FAILED\n", .{b.name});
                continue;
            };
        } else {
            const ekhex = std.fmt.bytesToHex(b.ekey, .lower);
            raw = get(gpa, try du(gpa, base, &ekhex), null) catch {
                std.debug.print("  {s}: not located (not in archives, not loose)\n", .{b.name});
                continue;
            };
        }
        const fileb = try blte(gpa, raw);
        var dig: [16]u8 = undefined;
        Md5.hash(fileb, &dig, .{});
        const ok = std.mem.eql(u8, &dig, &b.ckey);
        try outdir.writeFile(io_, .{ .sub_path = b.name, .data = fileb });
        total += fileb.len;
        wrote += 1;
        std.debug.print("  {s}  {d} bytes  md5==CKey:{}\n", .{ b.name, fileb.len, ok });
    }
    _ = located;
    std.debug.print("[getexe] wrote {d}/{d} files, {d} bytes total\n", .{ wrote, nb, total });
}
