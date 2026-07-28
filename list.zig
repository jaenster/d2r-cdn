// list.zig - list what a D2R build contains, straight from the manifests.
//
// Parses the INSTALL manifest (named loose files: exe/dll/etc) and the ROOT
// manifest (the full in-archive file catalog) so you can see the file list
// without downloading the ~37GB of data. Pure Zig std.
const std = @import("std");
const http = std.http;
const flate = std.compress.flate;

const PRODUCT = "osi";
const REGION = "us";
var client: http.Client = undefined;

fn httpGet(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    errdefer aw.deinit();
    const res = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &aw.writer });
    if (res.status != .ok and res.status != .partial_content) return error.HttpStatus;
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
        if (l.len == 0 or l[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, l, '!') != null) continue;
        if (std.mem.eql(u8, field(l, 0), region)) return l;
    }
    return "";
}
fn cfgValue(text: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |ln| {
        const l = std.mem.trimEnd(u8, ln, "\r");
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, l[0..eq], " "), key)) return std.mem.trim(u8, l[eq + 1 ..], " ");
    }
    return "";
}
fn cfgToken(text: []const u8, key: []const u8, n: usize) []const u8 {
    var it = std.mem.tokenizeAny(u8, cfgValue(text, key), " ");
    var i: usize = 0;
    while (it.next()) |t| : (i += 1) if (i == n) return t;
    return "";
}

fn blteDecode(gpa: std.mem.Allocator, data: []const u8) anyerror![]u8 {
    if (data.len < 8 or !std.mem.eql(u8, data[0..4], "BLTE")) return error.NotBlte;
    const header_size = std.mem.readInt(u32, data[4..8], .big);
    var out = std.Io.Writer.Allocating.init(gpa);
    errdefer out.deinit();
    if (header_size == 0) {
        try blteChunk(gpa, &out.writer, data[8..]);
        return out.toOwnedSlice();
    }
    const chunk_count = std.mem.readInt(u24, data[9..12], .big);
    var tbl: usize = 12;
    var dat: usize = 12 + @as(usize, chunk_count) * 24;
    var i: usize = 0;
    while (i < chunk_count) : (i += 1) {
        const csize = std.mem.readInt(u32, data[tbl..][0..4], .big);
        tbl += 24;
        try blteChunk(gpa, &out.writer, data[dat..][0..csize]);
        dat += csize;
    }
    return out.toOwnedSlice();
}
fn blteChunk(gpa: std.mem.Allocator, out: *std.Io.Writer, raw: []const u8) anyerror!void {
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
            const sub = try blteDecode(gpa, raw[1..]);
            defer gpa.free(sub);
            try out.writeAll(sub);
        },
        else => return error.BadBlteMode,
    }
}

// cursor reader over a byte buffer
const Cur = struct {
    b: []const u8,
    p: usize = 0,
    fn u8_(c: *Cur) u8 {
        const v = c.b[c.p];
        c.p += 1;
        return v;
    }
    fn u16be(c: *Cur) u16 {
        const v = std.mem.readInt(u16, c.b[c.p..][0..2], .big);
        c.p += 2;
        return v;
    }
    fn u32be(c: *Cur) u32 {
        const v = std.mem.readInt(u32, c.b[c.p..][0..4], .big);
        c.p += 4;
        return v;
    }
    fn str(c: *Cur) []const u8 {
        const start = c.p;
        while (c.p < c.b.len and c.b[c.p] != 0) c.p += 1;
        const s = c.b[start..c.p];
        c.p += 1; // skip NUL
        return s;
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

fn dataUrl(gpa: std.mem.Allocator, base: []const u8, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/data/{s}/{s}/{s}", .{ base, key[0..2], key[2..4], key });
}

// Encoding table: find the EKey for a given CKey. Format per blizzget/wowdev -
// 4096-byte CKey pages of entries { keyCount:u8, fileSize:u40 BE, CKey[16], EKey[16]*keyCount }.
fn encFindEKey(enc: []const u8, target: []const u8) ?[16]u8 {
    var c = Cur{ .b = enc, .p = 2 };
    _ = c.u8_(); // version
    const ck_size = c.u8_();
    const ek_size = c.u8_();
    const ck_page_kb = c.u16be();
    _ = c.u16be(); // ekey page kb
    const ck_pages = c.u32be();
    _ = c.u32be(); // ekey pages
    _ = c.u8_(); // unk
    const espec = c.u32be();
    c.skip(espec);
    c.skip(@as(usize, ck_pages) * (@as(usize, ck_size) + 16)); // CKey page table
    const page = @as(usize, ck_page_kb) * 1024;
    var pg: usize = 0;
    while (pg < ck_pages) : (pg += 1) {
        const page_start = c.p;
        while (c.p + 1 < page_start + page) {
            const kc = c.b[c.p];
            if (kc == 0) break;
            c.p += 1;
            _ = c.u40be();
            const ckey = c.b[c.p..][0..ck_size];
            c.p += ck_size;
            const ek_start = c.p;
            c.p += @as(usize, kc) * ek_size;
            if (std.mem.eql(u8, ckey, target)) {
                var out: [16]u8 = undefined;
                @memcpy(&out, enc[ek_start..][0..16]);
                return out;
            }
        }
        c.p = page_start + page;
    }
    return null;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    client = .{ .allocator = gpa, .io = threaded.io() };
    defer client.deinit();

    const patch = "http://" ++ REGION ++ ".patch.battle.net:1119/" ++ PRODUCT;
    const vrow = regionLine(try httpGet(gpa, patch ++ "/versions"), REGION);
    const crow = regionLine(try httpGet(gpa, patch ++ "/cdns"), REGION);
    const bch = field(vrow, 1);
    var hosts = std.mem.tokenizeScalar(u8, field(crow, 2), ' ');
    const base = try std.fmt.allocPrint(gpa, "http://{s}/{s}", .{ hosts.next().?, field(crow, 1) });
    const build = try httpGet(gpa, try std.fmt.allocPrint(gpa, "{s}/config/{s}/{s}/{s}", .{ base, bch[0..2], bch[2..4], bch }));
    std.debug.print("D2R {s} (build {s})\n\n", .{ field(vrow, 5), field(vrow, 4) });

    // INSTALL manifest: build config `install = <ckey> <ekey>`, fetch by ekey (loose).
    const in_ekey = cfgToken(build, "install", 1);
    const in_url = try std.fmt.allocPrint(gpa, "{s}/data/{s}/{s}/{s}", .{ base, in_ekey[0..2], in_ekey[2..4], in_ekey });
    const in_raw = try httpGet(gpa, in_url);
    const install = try blteDecode(gpa, in_raw);
    if (!std.mem.eql(u8, install[0..2], "IN")) return error.InstallMagic;

    var c = Cur{ .b = install, .p = 2 };
    _ = c.u8_(); // version
    const hash_size = c.u8_();
    const num_tags = c.u16be();
    const num_entries = c.u32be();
    const mask_bytes = (num_entries + 7) / 8;
    var t: usize = 0;
    while (t < num_tags) : (t += 1) {
        _ = c.str(); // tag name
        _ = c.u16be(); // type
        c.skip(mask_bytes);
    }
    std.debug.print("INSTALL manifest: {d} named files (executables, dlls, top-level)\n", .{num_entries});
    var total: u64 = 0;
    var e: usize = 0;
    while (e < num_entries) : (e += 1) {
        const name = c.str();
        c.skip(hash_size); // ckey
        const size = c.u32be();
        total += size;
        if (e < 40) std.debug.print("  {d:>10}  {s}\n", .{ size, name });
    }
    if (num_entries > 40) std.debug.print("  ... and {d} more\n", .{num_entries - 40});
    std.debug.print("install total: {d} bytes ({d:.1} MB) across {d} files\n\n", .{ total, @as(f64, @floatFromInt(total)) / 1e6, num_entries });

    // ROOT catalog: resolve root CKey -> EKey via the encoding table, fetch, decode.
    const enc_ekey = cfgToken(build, "encoding", 1);
    const enc = try blteDecode(gpa, try httpGet(gpa, try dataUrl(gpa, base, enc_ekey)));
    var root_ckey: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&root_ckey, cfgToken(build, "root", 0));
    const root_ekey = encFindEKey(enc, &root_ckey) orelse return error.RootNotInEncoding;
    const root_ekey_hex = std.fmt.bytesToHex(root_ekey, .lower);
    const root = try blteDecode(gpa, try httpGet(gpa, try dataUrl(gpa, base, &root_ekey_hex)));
    // D2R root is text: one "path|CKey|platform|basename" line per CRLF. Emit every
    // path to stdout (summary stays on stderr) so it can be sorted/aggregated.
    var out_buf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(threaded.io(), &out_buf);
    const w = &fw.interface;
    var lines = std.mem.splitScalar(u8, root, '\n');
    var rn: usize = 0;
    while (lines.next()) |ln| {
        const l = std.mem.trimEnd(u8, ln, "\r");
        if (l.len == 0) continue;
        const bar = std.mem.indexOfScalar(u8, l, '|') orelse continue;
        try w.print("{s}\n", .{l[0..bar]});
        rn += 1;
    }
    try fw.flush();
    std.debug.print("ROOT: EKey={s}  {d} catalog lines ({d} bytes)\n", .{ root_ekey_hex, rn, root.len });
}
