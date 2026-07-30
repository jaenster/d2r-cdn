// extract.zig - materialize the whole game as real files from a LOCAL pool (no
// re-download). Reads the content-addressed mirror (config/ + data/ by hash),
// parses root (path -> CKey), maps CKey -> EKey (encoding) and EKey -> (archive,
// offset, size) (the .index files), then reads each archive once, BLTE-decodes every
// file it holds, and writes it to its real path under OUT/.
//
// Paths, product, region are consts below. Needs one tiny HTTP call (/versions) to
// learn the current build's config hashes; everything else is read from POOL.
const std = @import("std");
const http = std.http;
const flate = std.compress.flate;

const POOL = "/volume1/Media/d2r-cdn/pool";
const OUT = "/volume1/Media/d2r-cdn/extracted/osi";
const PRODUCT = "osi";
const REGION = "us";

var io_: std.Io = undefined;
var dir: std.Io.Dir = undefined;
var client: http.Client = undefined;
var base: []const u8 = "";

// read a content-addressed blob: local pool first, else fetch from the CDN (for
// blobs the mirror didn't grab - e.g. root, which the build config lists CKey-only).
fn readLocal(gpa: std.mem.Allocator, kind: []const u8, hash: []const u8, ext: []const u8) ![]u8 {
    var pbuf: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/{s}/{s}/{s}/{s}{s}", .{ POOL, kind, hash[0..2], hash[2..4], hash, ext });
    if (dir.readFileAlloc(io_, p, gpa, .unlimited)) |d| return d else |_| {}
    var ubuf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&ubuf, "{s}/{s}/{s}/{s}/{s}{s}", .{ base, kind, hash[0..2], hash[2..4], hash, ext });
    var aw = std.Io.Writer.Allocating.init(gpa);
    const res = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &aw.writer });
    if (res.status != .ok) return error.Http;
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
fn cfgLine(text: []const u8, key: []const u8) []const u8 {
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
    fn skip(c: *Cur, n: usize) void {
        c.p += n;
    }
};

fn readBE(b: []const u8) u64 {
    var v: u64 = 0;
    for (b) |x| v = (v << 8) | x;
    return v;
}

const Loc = struct { arch: u32, off: u64, size: u32 };
const Ent = struct { path: []const u8, ekey: [16]u8, arch: u32 = 0xffffffff, off: u64 = 0, size: u32 = 0 };

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const pa = std.heap.page_allocator; // real free() for big per-archive/per-file temporaries
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    io_ = threaded.io();
    dir = std.Io.Dir.cwd();

    // tiny HTTP: /versions -> config hashes, /cdns -> the CDN base (for fallback fetches)
    client = .{ .allocator = gpa, .io = io_ };
    defer client.deinit();
    var vaw = std.Io.Writer.Allocating.init(gpa);
    _ = try client.fetch(.{ .location = .{ .url = "http://" ++ REGION ++ ".patch.battle.net:1119/" ++ PRODUCT ++ "/versions" }, .response_writer = &vaw.writer });
    const vrow = regionLine(vaw.written(), REGION);
    const bch = field(vrow, 1);
    const cch = field(vrow, 2);
    var caw = std.Io.Writer.Allocating.init(gpa);
    _ = try client.fetch(.{ .location = .{ .url = "http://" ++ REGION ++ ".patch.battle.net:1119/" ++ PRODUCT ++ "/cdns" }, .response_writer = &caw.writer });
    const crow = regionLine(caw.written(), REGION);
    var hosts = std.mem.tokenizeScalar(u8, field(crow, 2), ' ');
    base = try std.fmt.allocPrint(gpa, "http://{s}/{s}", .{ hosts.next().?, field(crow, 1) });
    std.debug.print("[extract] {s} build {s}\n", .{ PRODUCT, field(vrow, 5) });

    const build = try readLocal(gpa, "config", bch, "");
    const enc = try blte(gpa, try readLocal(gpa, "data", cfgTok(build, "encoding", 1), ""));

    // CKey -> EKey map from the encoding table
    var ck2ek = std.AutoHashMap([16]u8, [16]u8).init(gpa);
    {
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
                var ck: [16]u8 = undefined;
                @memcpy(&ck, c.b[c.p..][0..16]);
                c.p += cks;
                var ek: [16]u8 = undefined;
                @memcpy(&ek, c.b[c.p..][0..16]);
                c.p += @as(usize, kc) * eks;
                try ck2ek.put(ck, ek);
            }
            c.p = ps + page;
        }
    }
    std.debug.print("[extract] encoding: {d} CKeys\n", .{ck2ek.count()});

    // root (path -> CKey), text lines
    const root_ck = cfgTok(build, "root", 0);
    var rckb: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&rckb, root_ck);
    const root_ekhex = std.fmt.bytesToHex(ck2ek.get(rckb).?, .lower);
    const root = try blte(gpa, try readLocal(gpa, "data", &root_ekhex, ""));

    // archives + EKey -> (archive index, off, size) from local .index files
    const cdncfg = try readLocal(gpa, "config", cch, "");
    var archs = std.array_list.Managed([]const u8).init(gpa);
    {
        var it = std.mem.tokenizeAny(u8, cfgLine(cdncfg, "archives"), " \r");
        while (it.next()) |a| try archs.append(a);
    }
    var ek2loc = std.AutoHashMap([16]u8, Loc).init(gpa);
    for (archs.items, 0..) |ah, ai| {
        const idx = readLocal(gpa, "data", ah, ".index") catch continue;
        defer gpa.free(idx);
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
                var ek: [16]u8 = undefined;
                @memcpy(&ek, key[0..16]);
                try ek2loc.put(ek, .{ .arch = @intCast(ai), .size = @intCast(readBE(idx[pos + kb ..][0..sb])), .off = readBE(idx[pos + kb + sb ..][0..ob]) });
                if (cnt >= ne) break :outer;
            }
        }
    }
    std.debug.print("[extract] {d} archives, {d} EKeys located\n", .{ archs.items.len, ek2loc.count() });

    // parse root -> entries (dedup by path), resolve arch/off/size
    var ents = std.array_list.Managed(Ent).init(gpa);
    var seen = std.StringHashMap(void).init(gpa);
    var lines = std.mem.splitScalar(u8, root, '\n');
    while (lines.next()) |ln| {
        const l = std.mem.trimEnd(u8, ln, "\r");
        if (l.len == 0) continue;
        const bar = std.mem.indexOfScalar(u8, l, '|') orelse continue;
        const path = l[0..bar];
        if (seen.contains(path)) continue;
        try seen.put(path, {});
        const rest = l[bar + 1 ..];
        const bar2 = std.mem.indexOfScalar(u8, rest, '|') orelse continue;
        var ck: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&ck, rest[0..bar2]) catch continue;
        const ek = ck2ek.get(ck) orelse continue;
        var ent = Ent{ .path = path, .ekey = ek };
        if (ek2loc.get(ek)) |loc| {
            ent.arch = loc.arch;
            ent.off = loc.off;
            ent.size = loc.size;
        }
        try ents.append(ent);
    }
    std.debug.print("[extract] {d} unique files to extract\n", .{ents.items.len});

    // extract per-archive: read each archive once, decode + write its files
    var wrote: usize = 0;
    var miss: usize = 0;
    for (archs.items, 0..) |ah, ai| {
        var any = false;
        for (ents.items) |e| {
            if (e.arch == ai) {
                any = true;
                break;
            }
        }
        if (!any) continue;
        const blob = readLocal(pa, "data", ah, "") catch {
            std.debug.print("  archive {s} missing locally\n", .{ah[0..12]});
            continue;
        };
        defer pa.free(blob);
        for (ents.items) |e| {
            if (e.arch != ai) continue;
            const raw = blob[e.off .. e.off + e.size];
            const file = blte(pa, raw) catch continue;
            defer pa.free(file);
            const rel = if (std.mem.startsWith(u8, e.path, "data:")) e.path[5..] else e.path;
            const outpath = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ OUT, rel });
            if (std.fs.path.dirname(outpath)) |d| dir.createDirPath(io_, d) catch {};
            dir.writeFile(io_, .{ .sub_path = outpath, .data = file }) catch continue;
            wrote += 1;
        }
    }
    std.debug.print("[extract] archived: wrote {d} files\n", .{wrote});

    // loose files (not in any data archive) - fetch each by its EKey (local pool if
    // the mirror grabbed it, else straight from the CDN), decode, write.
    var loose: usize = 0;
    for (ents.items) |e| {
        if (e.arch != 0xffffffff) continue;
        const rel0 = if (std.mem.startsWith(u8, e.path, "data:")) e.path[5..] else e.path;
        const op0 = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ OUT, rel0 });
        if (dir.access(io_, op0, .{})) |_| {
            loose += 1;
            continue;
        } else |_| {}
        const ekhex = std.fmt.bytesToHex(e.ekey, .lower);
        const raw = readLocal(pa, "data", &ekhex, "") catch {
            miss += 1;
            continue;
        };
        defer pa.free(raw);
        const file = blte(pa, raw) catch continue;
        defer pa.free(file);
        const rel = if (std.mem.startsWith(u8, e.path, "data:")) e.path[5..] else e.path;
        const outpath = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ OUT, rel });
        if (std.fs.path.dirname(outpath)) |d| dir.createDirPath(io_, d) catch {};
        dir.writeFile(io_, .{ .sub_path = outpath, .data = file }) catch continue;
        loose += 1;
        wrote += 1;
        if (loose % 5000 == 0) std.debug.print("  loose: {d} fetched...\n", .{loose});
    }
    std.debug.print("[extract] done: {d} files to {s}/  ({d} archived, {d} loose, {d} failed)\n", .{ wrote, OUT, wrote - loose, loose, miss });
}
