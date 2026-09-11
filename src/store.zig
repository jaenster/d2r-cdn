//! Where a mirror lives: a directory on this machine, or a bucket. Which of the two
//! serves an operation is this file's business - callers only ever ask for an object
//! by key, so the same binary mirrors to a NAS disk or to object storage depending
//! on one flag.
//!
//! Bucket credentials are handed in by the caller (which reads them from the
//! environment, never the command line) - see `s3.Endpoint`.
const std = @import("std");
const s3 = @import("s3.zig");

pub const Range = struct { off: u64, len: u64 };

/// An endpoint pasted as a URL is still an endpoint; SigV4 signs the bare host.
fn stripScheme(v: []const u8) []const u8 {
    var h = v;
    if (std.mem.indexOf(u8, h, "://")) |i| h = h[i + 3 ..];
    return std.mem.trimEnd(u8, h, "/");
}

pub const Store = struct {
    io: std.Io,
    /// What was asked for, kept verbatim for logging.
    spec: []const u8,
    /// Folded into every key when the store is a bucket.
    prefix: []const u8 = "",
    where: union(enum) {
        dir: []const u8,
        bucket: s3.Bucket,
    },

    /// `spec` is either `s3://<bucket>/<prefix>` or a filesystem path. Returned by
    /// pointer: a bucket owns an http client, which must not move afterwards.
    pub fn open(a: std.mem.Allocator, io: std.Io, spec: []const u8, ep: ?s3.Endpoint) !*Store {
        const self = try a.create(Store);
        self.* = .{ .io = io, .spec = try a.dupe(u8, spec), .where = undefined };

        if (!std.mem.startsWith(u8, spec, "s3://")) {
            self.where = .{ .dir = self.spec };
            return self;
        }

        const rest = spec["s3://".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const bucket = if (slash) |i| rest[0..i] else rest;
        const prefix = if (slash) |i| std.mem.trim(u8, rest[i + 1 ..], "/") else "";
        if (bucket.len == 0) return error.BadPoolSpec;

        const e = ep orelse return error.MissingS3Endpoint;
        if (e.host.len == 0) return error.MissingS3Endpoint;
        if (e.access_key.len == 0 or e.secret_key.len == 0) return error.MissingS3Credentials;

        self.where = .{ .bucket = s3.Bucket.init(a, io, .{
            .host = try a.dupe(u8, stripScheme(e.host)),
            .region = try a.dupe(u8, e.region),
            .access_key = try a.dupe(u8, e.access_key),
            .secret_key = try a.dupe(u8, e.secret_key),
        }, try a.dupe(u8, bucket)) };
        // The prefix is part of every key, so fold it in once here.
        self.prefix = try a.dupe(u8, prefix);
        return self;
    }

    pub fn close(self: *Store) void {
        switch (self.where) {
            .dir => {},
            .bucket => |*b| b.deinit(),
        }
    }

    pub fn isBucket(self: *const Store) bool {
        return std.meta.activeTag(self.where) == .bucket;
    }

    /// `prefix/key` for a bucket, `dir/key` for a directory.
    fn resolve(self: *Store, a: std.mem.Allocator, key: []const u8) ![]u8 {
        return switch (self.where) {
            .dir => |d| std.fmt.allocPrint(a, "{s}/{s}", .{ d, key }),
            .bucket => if (self.prefix.len == 0)
                a.dupe(u8, key)
            else
                std.fmt.allocPrint(a, "{s}/{s}", .{ self.prefix, key }),
        };
    }

    /// Size of the stored object, or null when it is not there.
    pub fn objectSize(self: *Store, a: std.mem.Allocator, key: []const u8) !?u64 {
        const at = try self.resolve(a, key);
        defer a.free(at);
        return switch (self.where) {
            .dir => if (std.Io.Dir.cwd().statFile(self.io, at, .{})) |st| st.size else |_| null,
            .bucket => |*b| b.objectSize(at),
        };
    }

    /// The object's bytes (or a slice of them), null when absent.
    pub fn readObject(self: *Store, out: std.mem.Allocator, key: []const u8, range: ?Range) !?[]u8 {
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const at = self.resolve(fba.allocator(), key) catch return null;
        switch (self.where) {
            .dir => {
                if (range) |r| {
                    const file = std.Io.Dir.cwd().openFile(self.io, at, .{}) catch return null;
                    defer file.close(self.io);
                    const dst = try out.alloc(u8, @intCast(r.len));
                    errdefer out.free(dst);
                    const n = file.readPositionalAll(self.io, dst, r.off) catch {
                        out.free(dst);
                        return null;
                    };
                    if (n != dst.len) {
                        out.free(dst);
                        return null;
                    }
                    return dst;
                }
                return std.Io.Dir.cwd().readFileAlloc(self.io, at, out, .unlimited) catch null;
            },
            .bucket => |*b| return b.readObject(out, at, if (range) |r| .{ .off = r.off, .len = r.len } else null),
        }
    }

    /// Store `data` under `key`, creating whatever has to exist first.
    pub fn writeObject(self: *Store, a: std.mem.Allocator, key: []const u8, data: []const u8) !void {
        const at = try self.resolve(a, key);
        defer a.free(at);
        switch (self.where) {
            .dir => {
                if (std.fs.path.dirname(at)) |d| std.Io.Dir.cwd().createDirPath(self.io, d) catch {};
                try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = at, .data = data });
            },
            .bucket => |*b| try b.writeObject(at, data),
        }
    }

    /// Small text object, trimmed; "" when absent. The shape every state file has.
    pub fn readText(self: *Store, a: std.mem.Allocator, key: []const u8) ![]const u8 {
        const data = (try self.readObject(a, key, null)) orelse return "";
        return std.mem.trim(u8, data, " \n\r");
    }

    /// Begin writing exactly `len` bytes to `key`, starting at byte `at` (a directory
    /// can resume a partial file; an object cannot, so a bucket requires `at == 0`).
    /// `w` is initialised in place and must not be moved afterwards.
    pub fn beginWrite(self: *Store, w: *ObjectWriter, a: std.mem.Allocator, key: []const u8, len: u64, at: u64) !void {
        const path = try self.resolve(a, key);
        defer a.free(path);
        switch (self.where) {
            .dir => {
                if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(self.io, d);
                const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false });
                w.* = .{ .inner = .{ .file = .{ .io = self.io, .f = file, .w = undefined, .buf = undefined } } };
                w.inner.file.w = file.writer(self.io, &w.inner.file.buf);
                w.inner.file.w.pos = at;
            },
            .bucket => |*b| {
                std.debug.assert(at == 0);
                w.* = .{ .inner = .{ .upload = undefined } };
                try b.beginWrite(&w.inner.upload, path, len);
            },
        }
    }
};

/// An in-flight write to a store. Write through `writer()`, then `finish()`.
pub const ObjectWriter = struct {
    inner: union(enum) {
        file: struct {
            io: std.Io,
            f: std.Io.File,
            w: std.Io.File.Writer,
            buf: [64 * 1024]u8,
        },
        upload: s3.Upload,
    },

    pub fn writer(self: *ObjectWriter) *std.Io.Writer {
        return switch (self.inner) {
            .file => &self.inner.file.w.interface,
            .upload => self.inner.upload.writer(),
        };
    }

    /// Flush and confirm. For a bucket this is where a short body is caught, since
    /// the declared content-length will not have been met.
    pub fn finish(self: *ObjectWriter) !u64 {
        switch (self.inner) {
            .file => {
                try self.inner.file.w.interface.flush();
                const n = self.inner.file.w.pos;
                self.inner.file.f.close(self.inner.file.io);
                return n;
            },
            .upload => {
                try self.inner.upload.finish();
                return 0;
            },
        }
    }

    pub fn abort(self: *ObjectWriter) void {
        switch (self.inner) {
            .file => self.inner.file.f.close(self.inner.file.io),
            .upload => self.inner.upload.abort(),
        }
    }
};
