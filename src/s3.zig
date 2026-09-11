//! Minimal S3 for a content-addressed mirror: AWS SigV4 request signing over
//! `std.http`, plus the object operations a mirror needs - size, read, ranged read,
//! write, and a streamed write for blobs too big to hold in memory.
//!
//! Path-style addressing (`https://<endpoint>/<bucket>/<key>`), which is what the
//! S3-compatible endpoints we target speak. Pure std: no SDK, no C.
const std = @import("std");
const http = std.http;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const log = std.log.scoped(.s3);

/// sha256 of the empty string - the payload hash of any bodiless request.
pub const empty_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
/// Stands in for the payload hash when the body is streamed and its digest is not
/// known up front. Permitted over TLS, which is the only thing we speak.
pub const unsigned_payload = "UNSIGNED-PAYLOAD";

/// One S3 service and the keys to talk to it. Independent of which bucket is used,
/// so it can be resolved once from the environment and handed around.
pub const Endpoint = struct {
    /// Bare host, e.g. `fsn1.your-objectstorage.com`.
    host: []const u8,
    region: []const u8 = "us-east-1",
    access_key: []const u8,
    secret_key: []const u8,
};

/// A signed conversation with one bucket. Owns its own connection pool: the bucket
/// is a different host from the CDN, so it gets its own client.
pub const Bucket = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: http.Client,
    ep: Endpoint,
    name: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, ep: Endpoint, name: []const u8) Bucket {
        return .{ .gpa = gpa, .io = io, .client = .{ .allocator = gpa, .io = io }, .ep = ep, .name = name };
    }

    pub fn deinit(self: *Bucket) void {
        self.client.deinit();
    }

    // -- signing -----------------------------------------------------------------

    const Stamp = struct {
        day: [8]u8,
        iso: [16]u8,
    };

    fn stamp(self: *Bucket) Stamp {
        const secs: u64 = @intCast(@divFloor(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_s));
        const es = std.time.epoch.EpochSeconds{ .secs = secs };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        var s: Stamp = .{ .day = undefined, .iso = undefined };
        _ = std.fmt.bufPrint(&s.day, "{d:0>4}{d:0>2}{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch unreachable;
        _ = std.fmt.bufPrint(&s.iso, "{s}T{d:0>2}{d:0>2}{d:0>2}Z", .{
            s.day, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        }) catch unreachable;
        return s;
    }

    fn hmac(key: []const u8, msg: []const u8) [32]u8 {
        var out: [32]u8 = undefined;
        HmacSha256.create(&out, msg, key);
        return out;
    }

    fn hexSha256(data: []const u8) [64]u8 {
        var d: [32]u8 = undefined;
        Sha256.hash(data, &d, .{});
        return std.fmt.bytesToHex(d, .lower);
    }

    /// The `Authorization` header value for one request. `path` must already be the
    /// canonical (encoded) `/bucket/key`; only host and the two x-amz headers are
    /// signed, so anything else (range, content-type) may be sent unsigned.
    fn authorization(self: *Bucket, a: std.mem.Allocator, method: []const u8, path: []const u8, payload_hash: []const u8, st: Stamp) ![]u8 {
        const canonical = try std.fmt.allocPrint(a,
            "{s}\n{s}\n\nhost:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n\n" ++
                "host;x-amz-content-sha256;x-amz-date\n{s}",
            .{ method, path, self.ep.host, payload_hash, &st.iso, payload_hash });
        const scope = try std.fmt.allocPrint(a, "{s}/{s}/s3/aws4_request", .{ &st.day, self.ep.region });
        const to_sign = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{
            &st.iso, scope, &hexSha256(canonical),
        });

        const k_secret = try std.fmt.allocPrint(a, "AWS4{s}", .{self.ep.secret_key});
        const k_date = hmac(k_secret, &st.day);
        const k_region = hmac(&k_date, self.ep.region);
        const k_service = hmac(&k_region, "s3");
        const k_signing = hmac(&k_service, "aws4_request");
        const sig = hmac(&k_signing, to_sign);

        return std.fmt.allocPrint(a, "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={s}", .{
            self.ep.access_key, scope, &std.fmt.bytesToHex(sig, .lower),
        });
    }

    /// `/bucket/key` with every path segment percent-encoded, which is what SigV4
    /// signs and what the request line carries.
    fn canonicalPath(self: *Bucket, a: std.mem.Allocator, key: []const u8) ![]u8 {
        var out = std.Io.Writer.Allocating.init(a);
        errdefer out.deinit();
        try out.writer.print("/{s}/", .{self.name});
        for (key) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == '/') {
                try out.writer.writeByte(c);
            } else {
                try out.writer.print("%{X:0>2}", .{c});
            }
        }
        return out.toOwnedSlice();
    }

    /// Everything a signed request needs, valid until `a` is freed.
    const Signed = struct { url: []u8, headers: [3]http.Header };

    fn prepare(self: *Bucket, a: std.mem.Allocator, method: []const u8, key: []const u8, payload_hash: []const u8) !Signed {
        const st = self.stamp();
        const path = try self.canonicalPath(a, key);
        const auth = try self.authorization(a, method, path, payload_hash, st);
        return .{
            .url = try std.fmt.allocPrint(a, "https://{s}{s}", .{ self.ep.host, path }),
            .headers = .{
                .{ .name = "x-amz-content-sha256", .value = payload_hash },
                .{ .name = "x-amz-date", .value = try a.dupe(u8, &st.iso) },
                .{ .name = "authorization", .value = auth },
            },
        };
    }

    // -- objects -----------------------------------------------------------------

    /// Size of `key`, or null when it does not exist.
    pub fn objectSize(self: *Bucket, key: []const u8) !?u64 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const s = try self.prepare(a, "HEAD", key, empty_sha256);

        var req = try self.client.request(.HEAD, try std.Uri.parse(s.url), .{
            .extra_headers = &s.headers,
            .headers = .{ .accept_encoding = .omit },
        });
        defer req.deinit();
        try req.sendBodiless();
        var redirect: [2048]u8 = undefined;
        const res = try req.receiveHead(&redirect);
        if (res.head.status == .not_found) return null;
        if (res.head.status != .ok) return error.S3Status;
        return res.head.content_length orelse 0;
    }

    /// `key`'s bytes, or null when it does not exist. `range` reads a slice.
    pub fn readObject(self: *Bucket, out: std.mem.Allocator, key: []const u8, range: ?struct { off: u64, len: u64 }) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const s = try self.prepare(a, "GET", key, empty_sha256);

        var hdrs = std.array_list.Managed(http.Header).init(a);
        try hdrs.appendSlice(&s.headers);
        if (range) |r| try hdrs.append(.{
            .name = "range",
            .value = try std.fmt.allocPrint(a, "bytes={d}-{d}", .{ r.off, r.off + r.len - 1 }),
        });

        var req = try self.client.request(.GET, try std.Uri.parse(s.url), .{
            .extra_headers = hdrs.items,
            .headers = .{ .accept_encoding = .omit },
        });
        defer req.deinit();
        try req.sendBodiless();
        var redirect: [2048]u8 = undefined;
        var res = try req.receiveHead(&redirect);
        if (res.head.status == .not_found) return null;
        if (res.head.status != .ok and res.head.status != .partial_content) return error.S3Status;

        var xfer: [64 * 1024]u8 = undefined;
        const rdr = res.reader(&xfer);
        return try rdr.allocRemaining(out, .unlimited);
    }

    /// Write `data` to `key`. For state files and manifests; a blob goes through
    /// `beginWrite` instead so it never lands in memory.
    pub fn writeObject(self: *Bucket, key: []const u8, data: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const s = try self.prepare(a, "PUT", key, &hexSha256(data));

        var req = try self.client.request(.PUT, try std.Uri.parse(s.url), .{
            .extra_headers = &s.headers,
            .headers = .{ .accept_encoding = .omit },
        });
        defer req.deinit();
        const body = try a.dupe(u8, data);
        try req.sendBodyComplete(body);
        var redirect: [2048]u8 = undefined;
        const res = try req.receiveHead(&redirect);
        if (res.head.status != .ok and res.head.status != .created) return error.S3Status;
    }

    /// Begin a streamed PUT of exactly `len` bytes. `w` is initialised in place -
    /// it holds the request and its buffer, so it must not be moved afterwards.
    pub fn beginWrite(self: *Bucket, w: *Upload, key: []const u8, len: u64) !void {
        w.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa), .req = undefined, .body = undefined, .buf = undefined };
        errdefer w.arena.deinit();
        const a = w.arena.allocator();
        const s = try self.prepare(a, "PUT", key, unsigned_payload);

        w.req = try self.client.request(.PUT, try std.Uri.parse(s.url), .{
            .extra_headers = try a.dupe(http.Header, &s.headers),
            .headers = .{ .accept_encoding = .omit },
        });
        w.req.transfer_encoding = .{ .content_length = len };
        w.body = try w.req.sendBody(&w.buf);
    }
};

/// An in-flight streamed PUT. Write through `writer()`, then `finish()`.
pub const Upload = struct {
    arena: std.heap.ArenaAllocator,
    req: http.Client.Request,
    body: http.BodyWriter,
    buf: [64 * 1024]u8,

    pub fn writer(self: *Upload) *std.Io.Writer {
        return &self.body.writer;
    }

    /// Close the body and check the reply. A short or over-long body fails here,
    /// because the declared content-length will not have been met.
    ///
    /// `BodyWriter.end` flushes the body writer but not the connection under it, so
    /// the connection is flushed explicitly: without it a body small enough to sit
    /// entirely in the buffer never reaches the socket and the server waits for it
    /// until it gives up with a 408. A big blob hides the bug by overflowing the
    /// buffer, which forces the writes out on its own.
    pub fn finish(self: *Upload) !void {
        defer self.deinit();
        try self.body.end();
        try self.req.connection.?.flush();
        var redirect: [2048]u8 = undefined;
        var res = try self.req.receiveHead(&redirect);
        if (res.head.status != .ok and res.head.status != .created) {
            // S3 explains itself in an XML body; without it the status alone is a
            // guessing game.
            var xfer: [4096]u8 = undefined;
            const rdr = res.reader(&xfer);
            const body = rdr.allocRemaining(self.arena.allocator(), .limited(2048)) catch "";
            log.warn("PUT {d}: {s}", .{ @intFromEnum(res.head.status), body });
            return error.S3Status;
        }
    }

    pub fn abort(self: *Upload) void {
        self.deinit();
    }

    fn deinit(self: *Upload) void {
        self.req.deinit();
        self.arena.deinit();
    }
};
