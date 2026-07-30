//! tact - a small, dependency-free Zig library for Blizzard's modern CDN
//! (NGDP / TACT / CASC). Resolve a product's current build, decode BLTE, walk the
//! encoding / root / install manifests, and pull individual files out of the data
//! archives by content hash. Pure std (`std.http`, `std.compress.flate`, `Md5`).
//!
//! Typical use:
//!   var cdn = try tact.Cdn.open(gpa, io, "osi", "us");
//!   defer cdn.close();
//!   const exe = try cdn.extractInstall("D2R.exe");   // decoded bytes
const std = @import("std");
const http = std.http;
const flate = std.compress.flate;
pub const Md5 = std.crypto.hash.Md5;

pub const Hash = [16]u8;

// ---- text helpers (versions/cdns pipe tables, config files) --------------------

pub fn field(line: []const u8, idx: usize) []const u8 {
    var it = std.mem.splitScalar(u8, line, '|');
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) if (i == idx) return f;
    return "";
}

pub fn regionLine(text: []const u8, region: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |ln| {
        const l = std.mem.trimEnd(u8, ln, "\r");
        if (l.len == 0 or l[0] == '#' or std.mem.indexOfScalar(u8, l, '!') != null) continue;
        if (std.mem.eql(u8, field(l, 0), region)) return l;
    }
    return "";
}

/// The n-th whitespace token of `key = ...` in a config file.
pub fn cfgToken(text: []const u8, key: []const u8, n: usize) []const u8 {
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

/// The whole value after `key = ` (e.g. the space-separated archive list).
pub fn cfgValue(text: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |ln| {
        const l = std.mem.trimEnd(u8, ln, "\r");
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, l[0..eq], " "), key)) return std.mem.trim(u8, l[eq + 1 ..], " ");
    }
    return "";
}

// ---- BLTE (Blizzard's block container: N=raw, Z=zlib, F=frame, E=encrypted) -----

pub fn blteDecode(gpa: std.mem.Allocator, data: []const u8) anyerror![]u8 {
    if (data.len < 8 or !std.mem.eql(u8, data[0..4], "BLTE")) return error.NotBlte;
    const header_size = std.mem.readInt(u32, data[4..8], .big);
    var out = std.Io.Writer.Allocating.init(gpa);
    errdefer out.deinit();
    if (header_size == 0) {
        try blteChunk(gpa, &out.writer, data[8..]);
        return out.toOwnedSlice();
    }
    const n = std.mem.readInt(u24, data[9..12], .big);
    var tbl: usize = 12;
    var dat: usize = 12 + @as(usize, n) * 24;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cs = std.mem.readInt(u32, data[tbl..][0..4], .big);
        tbl += 24;
        try blteChunk(gpa, &out.writer, data[dat..][0..cs]);
        dat += cs;
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
        'E' => return error.EncryptedChunk,
        else => return error.BadBlteMode,
    }
}

// ---- little byte cursor for the binary manifests -------------------------------

pub const Cur = struct {
    b: []const u8,
    p: usize = 0,
    pub fn u8_(c: *Cur) u8 {
        defer c.p += 1;
        return c.b[c.p];
    }
    pub fn u16be(c: *Cur) u16 {
        defer c.p += 2;
        return std.mem.readInt(u16, c.b[c.p..][0..2], .big);
    }
    pub fn u32be(c: *Cur) u32 {
        defer c.p += 4;
        return std.mem.readInt(u32, c.b[c.p..][0..4], .big);
    }
    pub fn u40be(c: *Cur) u64 {
        var v: u64 = 0;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            v = (v << 8) | c.b[c.p];
            c.p += 1;
        }
        return v;
    }
    pub fn str(c: *Cur) []const u8 {
        const s = c.p;
        while (c.p < c.b.len and c.b[c.p] != 0) c.p += 1;
        defer c.p += 1;
        return c.b[s..c.p];
    }
    pub fn skip(c: *Cur, n: usize) void {
        c.p += n;
    }
};

fn readBE(b: []const u8) u64 {
    var v: u64 = 0;
    for (b) |x| v = (v << 8) | x;
    return v;
}

// ---- the client ----------------------------------------------------------------

pub const Loc = struct { arch: u32, off: u64, size: u32 };

/// A resolved product build on the CDN. `open` does the version-service handshake
/// and reads the build + cdn configs; everything else is lazy.
pub const Cdn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: http.Client,
    base: []const u8, // http://<host>/tpr/<product>
    build_cfg: []const u8,
    cdn_cfg: []const u8,
    version: []const u8,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, product: []const u8, region: []const u8) !Cdn {
        var self: Cdn = .{ .gpa = gpa, .io = io, .client = .{ .allocator = gpa, .io = io }, .base = "", .build_cfg = "", .cdn_cfg = "", .version = "" };
        const patch = try std.fmt.allocPrint(gpa, "http://{s}.patch.battle.net:1119/{s}", .{ region, product });
        const vrow = regionLine(try self.httpGet(try std.fmt.allocPrint(gpa, "{s}/versions", .{patch}), null), region);
        const crow = regionLine(try self.httpGet(try std.fmt.allocPrint(gpa, "{s}/cdns", .{patch}), null), region);
        var hosts = std.mem.tokenizeScalar(u8, field(crow, 2), ' ');
        self.base = try std.fmt.allocPrint(gpa, "http://{s}/{s}", .{ hosts.next() orelse return error.NoCdnHost, field(crow, 1) });
        const bch = field(vrow, 1);
        self.build_cfg = try self.readConfig(bch);
        self.cdn_cfg = try self.readConfig(field(vrow, 2));
        self.version = try gpa.dupe(u8, field(vrow, 5));
        return self;
    }
    pub fn close(self: *Cdn) void {
        self.client.deinit();
    }

    fn httpGet(self: *Cdn, href: []const u8, range: ?[]const u8) ![]u8 {
        var aw = std.Io.Writer.Allocating.init(self.gpa);
        errdefer aw.deinit();
        var hdr: [1]http.Header = undefined;
        var extra: []const http.Header = &.{};
        if (range) |r| {
            hdr[0] = .{ .name = "range", .value = r };
            extra = hdr[0..1];
        }
        const res = try self.client.fetch(.{ .location = .{ .url = href }, .response_writer = &aw.writer, .extra_headers = extra, .keep_alive = false });
        if (res.status != .ok and res.status != .partial_content) return error.HttpStatus;
        return aw.toOwnedSlice();
    }

    fn url(self: *Cdn, kind: []const u8, hash: []const u8, ext: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}/{s}/{s}{s}", .{ self.base, kind, hash[0..2], hash[2..4], hash, ext });
    }

    /// A config blob (plain text), by hash.
    pub fn readConfig(self: *Cdn, hash: []const u8) ![]u8 {
        return self.httpGet(try self.url("config", hash, ""), null);
    }
    /// A data blob (BLTE), by hash. Optional byte range for a slice of an archive.
    pub fn readData(self: *Cdn, hash: []const u8, range: ?[]const u8) ![]u8 {
        return self.httpGet(try self.url("data", hash, ""), range);
    }
    /// Fetch a data blob by hash and BLTE-decode it.
    pub fn readDataDecoded(self: *Cdn, hash: []const u8) ![]u8 {
        const raw = try self.readData(hash, null);
        defer self.gpa.free(raw);
        return blteDecode(self.gpa, raw);
    }

    /// Build the CKey -> EKey map from the encoding manifest.
    pub fn encoding(self: *Cdn) !std.AutoHashMap(Hash, Hash) {
        const enc = try self.readDataDecoded(cfgToken(self.build_cfg, "encoding", 1));
        var m = std.AutoHashMap(Hash, Hash).init(self.gpa);
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
                var ck: Hash = undefined;
                @memcpy(&ck, c.b[c.p..][0..16]);
                c.p += cks;
                var ek: Hash = undefined;
                @memcpy(&ek, c.b[c.p..][0..16]);
                c.p += @as(usize, kc) * eks;
                try m.put(ck, ek);
            }
            c.p = ps + page;
        }
        return m;
    }

    /// Build EKey -> (archive index, offset, size) from every archive .index.
    /// `reader` is called with (kind, hash, ext) and must return the blob bytes -
    /// pass a local-pool reader for offline use, or `null` to fetch from the CDN.
    pub fn locate(self: *Cdn, archs: [][]const u8) !std.AutoHashMap(Hash, Loc) {
        var m = std.AutoHashMap(Hash, Loc).init(self.gpa);
        for (archs, 0..) |ah, ai| {
            const idx = self.httpGet(try self.url("data", ah, ".index"), null) catch continue;
            defer self.gpa.free(idx);
            try parseIndex(idx, @intCast(ai), &m);
        }
        return m;
    }

    /// Resolve an install-manifest file (exe/dll) by name and return decoded bytes.
    pub fn extractInstall(self: *Cdn, name: []const u8) ![]u8 {
        const inst = try self.readDataDecoded(cfgToken(self.build_cfg, "install", 1));
        var ck: Hash = undefined;
        if (!installCKey(inst, name, &ck)) return error.NotInInstall;
        var enc = try self.encoding();
        defer enc.deinit();
        const ek = enc.get(ck) orelse return error.NoEKey;
        const ekhex = std.fmt.bytesToHex(ek, .lower);
        // try loose, else archives
        if (self.readData(&ekhex, null)) |raw| {
            defer self.gpa.free(raw);
            return blteDecode(self.gpa, raw);
        } else |_| {}
        const archs = try self.archives();
        defer self.gpa.free(archs);
        var loc = try self.locate(archs);
        defer loc.deinit();
        const l = loc.get(ek) orelse return error.NotLocated;
        const range = try std.fmt.allocPrint(self.gpa, "bytes={d}-{d}", .{ l.off, l.off + l.size - 1 });
        const raw = try self.readData(archs[l.arch], range);
        defer self.gpa.free(raw);
        return blteDecode(self.gpa, raw);
    }

    /// The archive hash list from the cdn config (caller frees the slice).
    pub fn archives(self: *Cdn) ![][]const u8 {
        var list = std.array_list.Managed([]const u8).init(self.gpa);
        var it = std.mem.tokenizeAny(u8, cfgValue(self.cdn_cfg, "archives"), " \r");
        while (it.next()) |a| try list.append(a);
        return list.toOwnedSlice();
    }
};

/// Parse an archive `.index` and add EKey -> (arch, off, size) entries to `m`.
pub fn parseIndex(idx: []const u8, arch: u32, m: *std.AutoHashMap(Hash, Loc)) !void {
    if (idx.len < 28) return;
    const foot = idx[idx.len - 28 ..];
    const blk = @as(usize, foot[11]) * 1024;
    const ob = foot[12];
    const sb = foot[13];
    const kb = foot[14];
    const ne = std.mem.readInt(u32, foot[16..20], .little);
    const ent = @as(usize, kb) + sb + ob;
    if (ent == 0) return;
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
            var ek: Hash = undefined;
            @memcpy(&ek, key[0..16]);
            try m.put(ek, .{ .arch = arch, .size = @intCast(readBE(idx[pos + kb ..][0..sb])), .off = readBE(idx[pos + kb + sb ..][0..ob]) });
            if (cnt >= ne) break :outer;
        }
    }
}

/// Find a file's CKey in the install manifest by name. Returns false if absent.
pub fn installCKey(inst: []const u8, want: []const u8, ck: *Hash) bool {
    var c = Cur{ .b = inst, .p = 2 };
    _ = c.u8_();
    const hs = c.u8_();
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
    while (e < nent) : (e += 1) {
        const name = c.str();
        @memcpy(ck, c.b[c.p..][0..16]);
        c.skip(hs);
        _ = c.u32be();
        if (std.mem.eql(u8, name, want)) return true;
    }
    return false;
}

test "blte round-trip of a raw single chunk" {
    // "BLTE" + headerSize=0 + 'N' + payload
    const enc = "BLTE\x00\x00\x00\x00Nhello";
    const out = try blteDecode(std.testing.allocator, enc);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}
