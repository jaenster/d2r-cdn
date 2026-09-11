//! tact - a small, dependency-free Zig library for Blizzard's modern CDN
//! (NGDP / TACT / CASC). Resolve a product's current build, decode BLTE, walk the
//! encoding / root / install manifests, pull individual files out of the data
//! archives by content hash, and mirror a build to a content-addressed pool - a
//! directory or an S3 bucket, same code either way.
//! Pure std (`std.http`, `std.compress.flate`, `Md5`).
//!
//! Typical use:
//!   const cdn = try tact.Cdn.open(gpa, io, .{});          // osi/us, current build
//!   defer cdn.close();
//!   const exe = try cdn.extractInstall("D2R.exe");        // decoded bytes
const std = @import("std");
const http = std.http;
const flate = std.compress.flate;
pub const Md5 = std.crypto.hash.Md5;

const log = std.log.scoped(.tact);

pub const s3 = @import("s3.zig");
pub const steam = @import("steam.zig");
pub const store = @import("store.zig");
pub const Store = store.Store;
pub const ObjectWriter = store.ObjectWriter;

pub const Hash = [16]u8;

// ---- text helpers (versions/cdns pipe tables, config files) --------------------

pub fn field(line: []const u8, idx: usize) []const u8 {
    var it = std.mem.splitScalar(u8, line, '|');
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) if (i == idx) return f;
    return "";
}

/// The data row for `region` in a versions/cdns table, skipping the header and the
/// `## seqn` line. With `any` set, falls back to the first data row of any region.
pub fn regionLine(text: []const u8, region: []const u8, any: bool) []const u8 {
    var first: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |ln| {
        const l = std.mem.trimEnd(u8, ln, "\r");
        if (l.len == 0 or l[0] == '#' or std.mem.indexOfScalar(u8, l, '!') != null) continue;
        if (field(l, 1).len == 0) continue;
        if (first.len == 0) first = l;
        if (std.mem.eql(u8, field(l, 0), region)) return l;
    }
    return if (any) first else "";
}

/// The n-th whitespace token of `key = ...` in a config file.
pub fn cfgToken(text: []const u8, key: []const u8, n: usize) []const u8 {
    var it = std.mem.tokenizeAny(u8, cfgValue(text, key), " \r");
    var i: usize = 0;
    while (it.next()) |t| : (i += 1) if (i == n) return t;
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
        if (dat + cs > data.len) return error.BlteTruncated;
        try blteChunk(gpa, &out.writer, data[dat..][0..cs]);
        dat += cs;
    }
    return out.toOwnedSlice();
}

fn blteChunk(gpa: std.mem.Allocator, out: *std.Io.Writer, raw: []const u8) anyerror!void {
    if (raw.len == 0) return error.BlteTruncated;
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

pub fn hexHash(h: Hash) [32]u8 {
    return std.fmt.bytesToHex(h, .lower);
}

/// Where a blob lives inside a pool: `<kind>/ab/cd/<hash><ext>`, the same layout the
/// CDN itself serves, so a mirror is a byte-for-byte stand-in for the origin.
pub fn blobKey(a: std.mem.Allocator, kind: []const u8, hash: []const u8, ext: []const u8) ![]u8 {
    if (hash.len < 4) return error.BadHash;
    return std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}{s}", .{ kind, hash[0..2], hash[2..4], hash, ext });
}

// ---- the client ----------------------------------------------------------------

pub const Loc = struct { arch: u32, off: u64, size: u32 };
pub const Range = struct { off: u64, len: u64 };

pub const InstallEntry = struct { name: []const u8, ckey: Hash, size: u32 };
pub const RootEntry = struct { path: []const u8, ckey: Hash };

/// One content-addressed blob of a build, as it lives on the CDN and in a mirror.
pub const Blob = struct {
    kind: []const u8, // config | data | patch
    hash: []const u8,
    ext: []const u8 = "",
    role: Role,

    pub const Role = enum { build_config, cdn_config, system, archive_index, archive };
};

pub const Fetched = enum { skipped, downloaded, resumed, failed };

pub const Options = struct {
    product: []const u8 = "osi",
    region: []const u8 = "us",
    /// Version service host. `region` only selects which row is used - cn.patch is
    /// unreachable outside China, so the host stays us.patch by default.
    patch_host: []const u8 = "us.patch.battle.net",
    /// Force a CDN host instead of the first one the service advertises.
    cdn_host: ?[]const u8 = null,
    /// Content-addressed mirror consulted before the network: a directory, or
    /// `s3://<bucket>/<prefix>`.
    pool: ?[]const u8 = null,
    /// Service and keys for an `s3://` pool. Unused for a directory.
    s3: ?s3.Endpoint = null,
    /// Write blobs fetched from the network into `pool`.
    cache: bool = false,
    /// Use the first data row when `region` has none (dev channels are often
    /// published for a single region only).
    any_region: bool = true,
};

/// A resolved product build. `open` does the version-service handshake and reads the
/// build + cdn configs; manifests, archive indices and files are pulled on demand and
/// cached for the lifetime of the client.
///
/// Everything the client itself allocates lives in an internal arena freed by
/// `close`. Extracted file bytes are allocated with the caller's `gpa` and are the
/// caller's to free.
pub const Cdn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    client: http.Client,
    opts: Options,
    /// The mirror consulted before the network, once resolved from `opts.pool`.
    pool: ?*Store = null,

    /// Region of the row actually used (may differ from `opts.region`).
    region: []const u8,
    /// http://<host>/<path> - the CDN root for this product.
    base: []const u8,
    /// http://<host>/<config path> - where product configs live.
    config_base: []const u8,
    build_config: []const u8,
    cdn_config: []const u8,
    product_config: []const u8,
    build_id: []const u8,
    version: []const u8,
    build_cfg: []const u8,
    cdn_cfg: []const u8,

    enc_map: ?std.AutoHashMapUnmanaged(Hash, Hash) = null,
    loc_map: ?std.AutoHashMapUnmanaged(Hash, Loc) = null,
    archive_list: ?[]const []const u8 = null,
    install_list: ?[]const InstallEntry = null,
    root_list: ?[]const RootEntry = null,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Cdn {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        const a = arena.allocator();
        const self = try a.create(Cdn);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = arena,
            .client = .{ .allocator = a, .io = io },
            .opts = .{
                .product = try a.dupe(u8, opts.product),
                .region = try a.dupe(u8, opts.region),
                .patch_host = try a.dupe(u8, opts.patch_host),
                .cdn_host = if (opts.cdn_host) |h| try a.dupe(u8, h) else null,
                .pool = if (opts.pool) |p| try a.dupe(u8, p) else null,
                .s3 = opts.s3,
                .cache = opts.cache,
                .any_region = opts.any_region,
            },
            .region = opts.region,
            .base = "",
            .config_base = "",
            .build_config = "",
            .cdn_config = "",
            .product_config = "",
            .build_id = "",
            .version = "",
            .build_cfg = "",
            .cdn_cfg = "",
        };

        if (self.opts.pool) |spec| self.pool = try Store.open(a, io, spec, self.opts.s3);

        const vrow = regionLine(try self.service("versions"), self.opts.region, self.opts.any_region);
        if (vrow.len == 0) return error.NoBuild;
        const crow = regionLine(try self.service("cdns"), self.opts.region, self.opts.any_region);
        if (crow.len == 0) return error.NoCdnRow;

        var hosts = std.mem.tokenizeScalar(u8, field(crow, 2), ' ');
        const host = self.opts.cdn_host orelse hosts.next() orelse return error.NoCdnHost;
        self.base = try std.fmt.allocPrint(a, "http://{s}/{s}", .{ host, field(crow, 1) });
        const cpath = if (field(crow, 4).len != 0) field(crow, 4) else "tpr/configs/data";
        self.config_base = try std.fmt.allocPrint(a, "http://{s}/{s}", .{ host, cpath });

        self.region = field(vrow, 0);
        self.build_config = field(vrow, 1);
        self.cdn_config = field(vrow, 2);
        self.build_id = field(vrow, 4);
        self.version = field(vrow, 5);
        self.product_config = field(vrow, 6);
        // An encrypted channel serves unreadable configs; that is a state to report,
        // not a failure to open.
        self.build_cfg = self.readConfig(self.build_config) catch "";
        self.cdn_cfg = self.readConfig(self.cdn_config) catch "";
        return self;
    }

    pub fn close(self: *Cdn) void {
        const arena = self.arena;
        const gpa = self.gpa;
        if (self.pool) |st| st.close();
        self.client.deinit();
        arena.deinit();
        gpa.destroy(arena);
    }

    /// Scratch allocator: everything here dies with `close`.
    pub fn scratch(self: *Cdn) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// True when this channel's configs are Armadillo-encrypted (or simply not
    /// readable as config text).
    pub fn isEncrypted(self: *Cdn) bool {
        return std.mem.indexOf(u8, self.build_cfg, "build-name") == null and
            cfgValue(self.build_cfg, "root").len == 0;
    }

    /// The Armadillo key an encrypted channel needs, from its product config.
    pub fn keyName(self: *Cdn) !?[]const u8 {
        if (self.product_config.len < 4) return null;
        const h = self.product_config;
        const url = try std.fmt.allocPrint(self.scratch(), "{s}/{s}/{s}/{s}", .{ self.config_base, h[0..2], h[2..4], h });
        const text = self.httpGet(self.scratch(), url, null) catch return null;
        const key = "\"decryption_key_name\":\"";
        const at = std.mem.indexOf(u8, text, key) orelse return null;
        const rest = text[at + key.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        return rest[0..end];
    }

    // -- raw transport -----------------------------------------------------------

    /// A version-service endpoint (`versions`, `cdns`, `bgdl`) as raw text.
    pub fn service(self: *Cdn, endpoint: []const u8) ![]u8 {
        const a = self.scratch();
        const url = try std.fmt.allocPrint(a, "http://{s}:1119/{s}/{s}", .{ self.opts.patch_host, self.opts.product, endpoint });
        return self.httpGet(a, url, null);
    }

    fn httpGet(self: *Cdn, a: std.mem.Allocator, url: []const u8, range: ?Range) ![]u8 {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var aw = std.Io.Writer.Allocating.init(a);
            var keep = false;
            defer if (!keep) aw.deinit();
            var rbuf: [64]u8 = undefined;
            var hdr: [1]http.Header = undefined;
            var extra: []const http.Header = &.{};
            if (range) |r| {
                hdr[0] = .{ .name = "range", .value = try std.fmt.bufPrint(&rbuf, "bytes={d}-{d}", .{ r.off, r.off + r.len - 1 }) };
                extra = hdr[0..1];
            }
            const res = self.client.fetch(.{
                .location = .{ .url = url },
                .response_writer = &aw.writer,
                .extra_headers = extra,
            }) catch |err| {
                // a pooled connection the CDN closed under us: one clean retry
                if (attempt == 0) continue;
                return err;
            };
            if (res.status != .ok and res.status != .partial_content) return error.HttpStatus;
            const body = try aw.toOwnedSlice();
            keep = true;
            return body;
        }
    }

    pub fn blobUrl(self: *Cdn, a: std.mem.Allocator, kind: []const u8, hash: []const u8, ext: []const u8) ![]u8 {
        if (hash.len < 4) return error.BadHash;
        return std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}/{s}{s}", .{ self.base, kind, hash[0..2], hash[2..4], hash, ext });
    }


    /// A content-addressed blob: the pool first, then the CDN. `range` reads a slice
    /// (a positional read from the pool, a byte-range request from the CDN).
    pub fn readBlob(self: *Cdn, a: std.mem.Allocator, kind: []const u8, hash: []const u8, ext: []const u8, range: ?Range) ![]u8 {
        if (self.pool) |st| {
            const key = try blobKey(self.gpa, kind, hash, ext);
            defer self.gpa.free(key);
            // A pool miss - absent, unreadable, or the bucket being unreachable - is
            // not an error: that is what the origin is for.
            const hit = st.readObject(a, key, if (range) |r| .{ .off = r.off, .len = r.len } else null) catch null;
            if (hit) |d| return d;
        }
        const url = try self.blobUrl(self.gpa, kind, hash, ext);
        defer self.gpa.free(url);
        const data = try self.httpGet(a, url, range);
        if (self.opts.cache and range == null) self.storeInPool(kind, hash, ext, data) catch {};
        return data;
    }

    fn storeInPool(self: *Cdn, kind: []const u8, hash: []const u8, ext: []const u8, data: []const u8) !void {
        const st = self.pool orelse return;
        const key = try blobKey(self.gpa, kind, hash, ext);
        defer self.gpa.free(key);
        try st.writeObject(self.gpa, key, data);
    }

    /// A config blob (plain text), by hash.
    pub fn readConfig(self: *Cdn, hash: []const u8) ![]u8 {
        return self.readBlob(self.scratch(), "config", hash, "", null);
    }
    /// A data blob (BLTE-framed), by hash.
    pub fn readData(self: *Cdn, a: std.mem.Allocator, hash: []const u8, range: ?Range) ![]u8 {
        return self.readBlob(a, "data", hash, "", range);
    }
    /// Fetch a data blob by hash and BLTE-decode it.
    pub fn readDataDecoded(self: *Cdn, a: std.mem.Allocator, hash: []const u8) ![]u8 {
        const raw = try self.readData(a, hash, null);
        defer a.free(raw);
        return blteDecode(a, raw);
    }

    // -- manifests ---------------------------------------------------------------

    /// The archive hash list from the cdn config.
    pub fn archives(self: *Cdn) ![]const []const u8 {
        if (self.archive_list) |l| return l;
        var list = std.array_list.Managed([]const u8).init(self.scratch());
        var it = std.mem.tokenizeAny(u8, cfgValue(self.cdn_cfg, "archives"), " \r");
        while (it.next()) |ah| try list.append(ah);
        self.archive_list = try list.toOwnedSlice();
        return self.archive_list.?;
    }

    /// The CKey -> EKey map from the encoding manifest.
    pub fn encoding(self: *Cdn) !*std.AutoHashMapUnmanaged(Hash, Hash) {
        if (self.enc_map == null) {
            const a = self.scratch();
            const ekey = cfgToken(self.build_cfg, "encoding", 1);
            if (ekey.len == 0) return error.NoEncodingManifest;
            const enc = try self.readDataDecoded(a, ekey);
            var m: std.AutoHashMapUnmanaged(Hash, Hash) = .empty;
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
                    try m.put(a, ck, ek);
                }
                c.p = ps + page;
            }
            self.enc_map = m;
        }
        return &self.enc_map.?;
    }

    /// EKey -> (archive index, offset, size), from every archive `.index`.
    pub fn locations(self: *Cdn) !*std.AutoHashMapUnmanaged(Hash, Loc) {
        if (self.loc_map == null) {
            const a = self.scratch();
            var m: std.AutoHashMapUnmanaged(Hash, Loc) = .empty;
            for (try self.archives(), 0..) |ah, ai| {
                const idx = self.readBlob(a, "data", ah, ".index", null) catch continue;
                defer a.free(idx);
                try parseIndex(a, idx, @intCast(ai), &m);
            }
            self.loc_map = m;
        }
        return &self.loc_map.?;
    }

    /// The install manifest: the named loose files (executables, dlls, top level).
    pub fn install(self: *Cdn) ![]const InstallEntry {
        if (self.install_list) |l| return l;
        const a = self.scratch();
        const ekey = cfgToken(self.build_cfg, "install", 1);
        if (ekey.len == 0) return error.NoInstallManifest;
        const inst = try self.readDataDecoded(a, ekey);
        if (inst.len < 10 or !std.mem.eql(u8, inst[0..2], "IN")) return error.InstallMagic;
        var c = Cur{ .b = inst, .p = 2 };
        _ = c.u8_(); // version
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
        var list = try std.array_list.Managed(InstallEntry).initCapacity(a, nent);
        var e: usize = 0;
        while (e < nent) : (e += 1) {
            const name = c.str();
            var ck: Hash = undefined;
            @memcpy(&ck, c.b[c.p..][0..16]);
            c.skip(hs);
            list.appendAssumeCapacity(.{ .name = name, .ckey = ck, .size = c.u32be() });
        }
        self.install_list = try list.toOwnedSlice();
        return self.install_list.?;
    }

    /// The root manifest: every game file, by path. D2R's root is a text catalog of
    /// `path|CKey|platform|basename` lines.
    pub fn root(self: *Cdn) ![]const RootEntry {
        if (self.root_list) |l| return l;
        const a = self.scratch();
        const ck_hex = cfgToken(self.build_cfg, "root", 0);
        if (ck_hex.len < 32) return error.NoRootManifest;
        var ck: Hash = undefined;
        _ = try std.fmt.hexToBytes(&ck, ck_hex[0..32]);
        const enc = try self.encoding();
        const ek = enc.get(ck) orelse return error.NoEKey;
        const ekhex = hexHash(ek);
        const blob = try self.readDataDecoded(a, &ekhex);
        if (blob.len > 4 and (std.mem.eql(u8, blob[0..4], "TSFM") or std.mem.eql(u8, blob[0..4], "MNDX"))) return error.UnsupportedRootFormat;

        var list = std.array_list.Managed(RootEntry).init(a);
        var seen = std.StringHashMap(void).init(a);
        var lines = std.mem.splitScalar(u8, blob, '\n');
        while (lines.next()) |ln| {
            const l = std.mem.trimEnd(u8, ln, "\r");
            if (l.len == 0) continue;
            const bar = std.mem.indexOfScalar(u8, l, '|') orelse continue;
            const path = l[0..bar];
            if (seen.contains(path)) continue;
            try seen.put(path, {});
            const rest = l[bar + 1 ..];
            const bar2 = std.mem.indexOfScalar(u8, rest, '|') orelse rest.len;
            var eck: Hash = undefined;
            _ = std.fmt.hexToBytes(&eck, rest[0..@min(32, bar2)]) catch continue;
            try list.append(.{ .path = path, .ckey = eck });
        }
        self.root_list = try list.toOwnedSlice();
        return self.root_list.?;
    }

    // -- extraction --------------------------------------------------------------

    /// Decoded bytes of a file by content key, verified against its CKey. Comes from
    /// a loose data blob when there is one, else out of the archive that holds it.
    /// Caller owns the returned slice (allocated with `gpa`).
    pub fn extract(self: *Cdn, ckey: Hash) ![]u8 {
        const enc = try self.encoding();
        const ek = enc.get(ckey) orelse return error.NoEKey;
        const ekhex = hexHash(ek);

        var data: ?[]u8 = null;
        if (self.loc_map) |*m| {
            if (m.get(ek)) |l| data = try self.extractAt(l);
        }
        if (data == null) {
            if (self.readData(self.gpa, &ekhex, null)) |raw| {
                defer self.gpa.free(raw);
                data = try blteDecode(self.gpa, raw);
            } else |_| {
                const m = try self.locations();
                const l = m.get(ek) orelse return error.NotLocated;
                data = try self.extractAt(l);
            }
        }
        const out = data.?;
        errdefer self.gpa.free(out);
        var dig: Hash = undefined;
        Md5.hash(out, &dig, .{});
        if (!std.mem.eql(u8, &dig, &ckey)) return error.CKeyMismatch;
        return out;
    }

    fn extractAt(self: *Cdn, l: Loc) ![]u8 {
        const archs = try self.archives();
        if (l.arch >= archs.len) return error.NotLocated;
        const raw = try self.readData(self.gpa, archs[l.arch], .{ .off = l.off, .len = l.size });
        defer self.gpa.free(raw);
        return blteDecode(self.gpa, raw);
    }

    /// Resolve an install-manifest file (exe/dll) by name and return decoded bytes.
    pub fn extractInstall(self: *Cdn, name: []const u8) ![]u8 {
        for (try self.install()) |e| {
            if (std.mem.eql(u8, e.name, name)) return self.extract(e.ckey);
        }
        return error.NotInInstall;
    }

    /// Resolve a root-manifest file by path and return decoded bytes.
    pub fn extractPath(self: *Cdn, path: []const u8) ![]u8 {
        for (try self.root()) |e| {
            if (std.mem.eql(u8, e.path, path)) return self.extract(e.ckey);
        }
        return error.NotInRoot;
    }

    // -- mirroring ---------------------------------------------------------------

    pub const BlobSet = struct {
        /// Archive indices only: the ~30MB fingerprint of a build, without the
        /// 256MB archives themselves.
        indices_only: bool = false,
        /// Stop after this many archives (0 = all of them).
        max_archives: usize = 0,
    };

    /// Every blob that makes up this build: the two configs, the system manifests,
    /// and each data archive with its index.
    pub fn blobs(self: *Cdn, a: std.mem.Allocator, set: BlobSet) ![]const Blob {
        var list = std.array_list.Managed(Blob).init(a);
        try list.append(.{ .kind = "config", .hash = self.build_config, .role = .build_config });
        try list.append(.{ .kind = "config", .hash = self.cdn_config, .role = .cdn_config });
        for ([_][]const u8{ "encoding", "root", "install", "download", "size", "patch" }) |k| {
            const ek = cfgToken(self.build_cfg, k, 1);
            if (ek.len >= 32) try list.append(.{ .kind = "data", .hash = ek, .role = .system });
        }
        for (try self.archives(), 0..) |ah, i| {
            if (set.max_archives != 0 and i >= set.max_archives) break;
            try list.append(.{ .kind = "data", .hash = ah, .ext = ".index", .role = .archive_index });
            if (!set.indices_only) try list.append(.{ .kind = "data", .hash = ah, .role = .archive });
        }
        return list.toOwnedSlice();
    }

    /// The size the CDN reports for a blob, or null if it will not say.
    pub fn remoteSize(self: *Cdn, url: []const u8) !?u64 {
        var redirect_buf: [8 * 1024]u8 = undefined;
        var req = try self.client.request(.HEAD, try std.Uri.parse(url), .{});
        defer req.deinit();
        try req.sendBodiless();
        const res = try req.receiveHead(&redirect_buf);
        if (res.head.status != .ok) return null;
        return res.head.content_length;
    }

    /// Capture one blob into a pool: a complete one is skipped, and a directory
    /// resumes a partial file. Streams straight through, so a 256MB archive never
    /// lands in memory.
    ///
    /// Blizzard's edge answers a range starting at EOF with the whole blob instead of
    /// 416, so a resumed directory write is checked against the advertised length and
    /// refetched from zero when it does not line up. A bucket never resumes - an
    /// object is all-or-nothing - so it cannot hit that.
    pub fn download(self: *Cdn, dest: *Store, b: Blob) !Fetched {
        const a = self.gpa; // per-blob scratch: freed here, not held for the session
        if (b.hash.len < 4) return error.BadHash;

        const key = try blobKey(a, b.kind, b.hash, b.ext);
        defer a.free(key);
        const url = try self.blobUrl(a, b.kind, b.hash, b.ext);
        defer a.free(url);

        const have: u64 = (dest.objectSize(a, key) catch null) orelse 0;
        const remote = self.remoteSize(url) catch null;
        if (remote) |r| if (have == r and have != 0) return .skipped;

        const r = remote orelse {
            // With no advertised length a bucket cannot be written at all: a PUT has
            // to declare its size. A directory can still take the bytes.
            if (dest.isBucket()) {
                log.warn("{s}: no content-length from the CDN, cannot PUT", .{key});
                return .failed;
            }
            _ = self.stream(dest, key, url, 0, 0) catch |err| {
                log.warn("{s}: {s}", .{ key, @errorName(err) });
                return .failed;
            };
            return .downloaded;
        };

        const resume_at: u64 = if (!dest.isBucket() and have != 0 and have < r) have else 0;
        const written = self.stream(dest, key, url, r, resume_at) catch |err| {
            log.warn("{s}: have={d} remote={d} resume={d}: {s}", .{ key, have, r, resume_at, @errorName(err) });
            return .failed;
        };
        // The PUT declares its length, so a short body has already failed above.
        if (dest.isBucket()) return .downloaded;
        if (written == r) return if (resume_at != 0) .resumed else .downloaded;
        if (resume_at == 0) {
            log.warn("{s}: wrote {d} of {d} bytes", .{ key, written, r });
            return .failed;
        }
        return if ((self.stream(dest, key, url, r, 0) catch return .failed) == r) .downloaded else .failed;
    }

    /// GET `url` into the store at `key`, starting at `resume_at`, returning how many
    /// bytes the stored object now holds (0 for a bucket, which verifies by length).
    fn stream(self: *Cdn, dest: *Store, key: []const u8, url: []const u8, total: u64, resume_at: u64) !u64 {
        var ow: ObjectWriter = undefined;
        try dest.beginWrite(&ow, self.gpa, key, total - resume_at, resume_at);
        var ok = false;
        defer if (!ok) ow.abort();

        var rbuf: [64]u8 = undefined;
        var hdr: [1]http.Header = undefined;
        var extra: []const http.Header = &.{};
        if (resume_at != 0) {
            hdr[0] = .{ .name = "range", .value = try std.fmt.bufPrint(&rbuf, "bytes={d}-", .{resume_at}) };
            extra = hdr[0..1];
        }
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = ow.writer(),
            .extra_headers = extra,
        });
        if (res.status != .ok and res.status != .partial_content) return error.HttpStatus;
        ok = true;
        return try ow.finish();
    }
};

/// Parse an archive `.index` and add EKey -> (arch, off, size) entries to `m`.
pub fn parseIndex(a: std.mem.Allocator, idx: []const u8, arch: u32, m: *std.AutoHashMapUnmanaged(Hash, Loc)) !void {
    if (idx.len < 28) return;
    const foot = idx[idx.len - 28 ..];
    const blk = @as(usize, foot[11]) * 1024;
    const ob = foot[12];
    const sb = foot[13];
    const kb = foot[14];
    const ne = std.mem.readInt(u32, foot[16..20], .little);
    const ent = @as(usize, kb) + sb + ob;
    if (ent == 0 or blk == 0 or kb < 16) return;
    const per = blk / ent;
    var cnt: usize = 0;
    var pg: usize = 0;
    outer: while (cnt < ne) : (pg += 1) {
        var e: usize = 0;
        while (e < per) : (e += 1) {
            const pos = pg * blk + e * ent;
            if (pos + ent > idx.len) break :outer;
            const key = idx[pos..][0..kb];
            if (std.mem.eql(u8, key[0..16], "\x00" ** 16)) continue;
            cnt += 1;
            var ek: Hash = undefined;
            @memcpy(&ek, key[0..16]);
            try m.put(a, ek, .{ .arch = arch, .size = @intCast(readBE(idx[pos + kb ..][0..sb])), .off = readBE(idx[pos + kb + sb ..][0..ob]) });
            if (cnt >= ne) break :outer;
        }
    }
}

/// Shell-style match with `*` and `?`, case-insensitive (CDN paths are lowercase).
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or std.ascii.toLower(pattern[p]) == std.ascii.toLower(name[n]))) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            mark = n;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            n = mark;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

test "blte round-trip of a raw single chunk" {
    // "BLTE" + headerSize=0 + 'N' + payload
    const enc = "BLTE\x00\x00\x00\x00Nhello";
    const out = try blteDecode(std.testing.allocator, enc);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "versions table row selection" {
    const table =
        "Region!STRING:0|BuildConfig!HEX:16\n" ++
        "## seqn = 1\n" ++
        "us|aaaa\n" ++
        "eu|bbbb\n";
    try std.testing.expectEqualStrings("bbbb", field(regionLine(table, "eu", false), 1));
    try std.testing.expectEqualStrings("", regionLine(table, "kr", false));
    try std.testing.expectEqualStrings("us|aaaa", regionLine(table, "kr", true));
}

test "config parsing" {
    const cfg = "root = deadbeef\nencoding = aaaa bbbb\narchives = 11 22 33\n";
    try std.testing.expectEqualStrings("bbbb", cfgToken(cfg, "encoding", 1));
    try std.testing.expectEqualStrings("11 22 33", cfgValue(cfg, "archives"));
    try std.testing.expectEqualStrings("", cfgToken(cfg, "install", 1));
}

test "glob" {
    try std.testing.expect(globMatch("*.dll", "D2R_loader.dll"));
    try std.testing.expect(globMatch("data:*/global/excel/*.txt", "data:data/global/excel/misc.txt"));
    try std.testing.expect(!globMatch("*.dll", "D2R.exe"));
    try std.testing.expect(globMatch("*", "anything"));
}
