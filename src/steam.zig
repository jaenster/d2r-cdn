//! Steam's side of the same job. D2R ships on Steam as well as Blizzard's own CDN,
//! and Steam answers two questions the TACT path cannot:
//!
//!   * what branches exist, including the moment a non-public one is flipped open -
//!     which is how a debug build reaches the outside world by accident
//!   * every build it ever served, because a manifest stays fetchable by its id
//!     forever, where a delisted TACT config just returns 403
//!
//! The branch table is public: PICS app-info is served over plain HTTP with no
//! account at all. The depot bytes are not - those need a logged-in account that
//! owns the app, so capturing a build is a separate step (see `Capture`).
const std = @import("std");
const http = std.http;

/// A community mirror of Steam's PICS app-info, which is the same data `steamcmd
/// app_info_print` prints - without needing steamcmd, or a login.
pub const info_host = "https://api.steamcmd.net/v1/info/";

/// Diablo II: Resurrected - Infernal Edition.
pub const d2r_appid = "2536520";

pub const Branch = struct {
    name: []const u8,
    build_id: []const u8,
    time_updated: []const u8 = "",
    /// A branch behind a beta password. Its name is visible; its content is not.
    password_required: bool = false,
    /// "Local Content Server" branches, used for internal testing.
    lcs_required: bool = false,
    description: []const u8 = "",
};

pub const Depot = struct {
    id: []const u8,
    /// Manifest id for the branch being looked at, "" when it has none.
    manifest: []const u8 = "",
    /// Bytes installed, as the manifest declares them.
    size: u64 = 0,
    /// The depot's manifest on every branch PICS lists one for. A branch behind a
    /// password lists its manifests encrypted, so it never shows up here.
    manifests: []const Manifest = &.{},

    pub fn on(self: Depot, branch_name: []const u8) ?Manifest {
        for (self.manifests) |m| if (std.mem.eql(u8, m.branch, branch_name)) return m;
        return null;
    }
};

/// One depot's content on one branch.
pub const Manifest = struct {
    branch: []const u8,
    gid: []const u8,
    /// Bytes installed, as declared.
    size: u64 = 0,
};

/// One reading of an app's PICS record.
pub const App = struct {
    appid: []const u8,
    name: []const u8 = "",
    /// The app declares branches that are not in the public table. Their names stay
    /// hidden, but this is the flag that says there is something to miss.
    private_branches: bool = false,
    branches: []const Branch = &.{},
    depots: []const Depot = &.{},
    /// The record exactly as served, which is what gets archived.
    raw: []const u8 = "",

    pub fn branch(self: App, name: []const u8) ?Branch {
        for (self.branches) |b| if (std.mem.eql(u8, b.name, name)) return b;
        return null;
    }

    /// Total install size of the branch's depots.
    pub fn totalSize(self: App) u64 {
        var n: u64 = 0;
        for (self.depots) |d| n += d.size;
        return n;
    }
};

fn str(obj: std.json.Value, key: []const u8) []const u8 {
    const o = switch (obj) {
        .object => |m| m,
        else => return "",
    };
    const v = o.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Read an app's record. `branch_name` selects which branch's manifest ids are
/// reported in `depots`; the branch table itself always covers every branch.
pub fn fetchApp(a: std.mem.Allocator, io: std.Io, appid: []const u8, branch_name: []const u8) !App {
    var client: http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(a, "{s}{s}", .{ info_host, appid });
    var body = std.Io.Writer.Allocating.init(a);
    const res = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
    // Told apart from other failures so a poller can back off instead of retrying.
    if (res.status == .too_many_requests) return error.SteamRateLimited;
    if (res.status != .ok) return error.SteamInfoStatus;
    const raw = try body.toOwnedSlice();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    const root = parsed.value;
    const data = switch (root) {
        .object => |m| m.get("data") orelse return error.SteamInfoShape,
        else => return error.SteamInfoShape,
    };
    const app = switch (data) {
        .object => |m| m.get(appid) orelse return error.SteamAppNotFound,
        else => return error.SteamInfoShape,
    };
    const app_obj = switch (app) {
        .object => |m| m,
        else => return error.SteamInfoShape,
    };

    var out: App = .{ .appid = appid, .raw = raw };
    if (app_obj.get("common")) |c| out.name = str(c, "name");

    const depots_obj = switch (app_obj.get("depots") orelse return error.SteamInfoShape) {
        .object => |m| m,
        else => return error.SteamInfoShape,
    };
    out.private_branches = std.mem.eql(u8, str(.{ .object = depots_obj }, "privatebranches"), "1");

    var branches = std.array_list.Managed(Branch).init(a);
    if (depots_obj.get("branches")) |bv| switch (bv) {
        .object => |bm| {
            var it = bm.iterator();
            while (it.next()) |e| try branches.append(.{
                .name = e.key_ptr.*,
                .build_id = str(e.value_ptr.*, "buildid"),
                .time_updated = str(e.value_ptr.*, "timeupdated"),
                .password_required = std.mem.eql(u8, str(e.value_ptr.*, "pwdrequired"), "1"),
                .lcs_required = std.mem.eql(u8, str(e.value_ptr.*, "lcsrequired"), "1"),
                .description = str(e.value_ptr.*, "description"),
            });
        },
        else => {},
    };
    out.branches = try branches.toOwnedSlice();

    var depots = std.array_list.Managed(Depot).init(a);
    var it = depots_obj.iterator();
    while (it.next()) |e| {
        // Only the numeric keys are depots; the rest is branches/baselanguages/flags.
        const id = e.key_ptr.*;
        if (id.len == 0 or !std.ascii.isDigit(id[0])) continue;
        var d: Depot = .{ .id = id };
        const manifests = switch (e.value_ptr.*) {
            .object => |m| m.get("manifests"),
            else => null,
        };
        var all = std.array_list.Managed(Manifest).init(a);
        if (manifests) |mv| switch (mv) {
            .object => |mm| {
                var mit = mm.iterator();
                while (mit.next()) |me| {
                    // Older records give the gid as a bare string rather than an object.
                    const m: Manifest = switch (me.value_ptr.*) {
                        .string => |g| .{ .branch = me.key_ptr.*, .gid = g },
                        else => .{
                            .branch = me.key_ptr.*,
                            .gid = str(me.value_ptr.*, "gid"),
                            .size = std.fmt.parseInt(u64, str(me.value_ptr.*, "size"), 10) catch 0,
                        },
                    };
                    if (m.gid.len == 0) continue;
                    try all.append(m);
                    if (std.mem.eql(u8, m.branch, branch_name)) {
                        d.manifest = m.gid;
                        d.size = m.size;
                    }
                }
            },
            else => {},
        };
        d.manifests = try all.toOwnedSlice();
        try depots.append(d);
    }
    out.depots = try depots.toOwnedSlice();
    return out;
}

/// A one-line fingerprint of every branch, so a change of any kind shows up as a
/// difference. Deliberately includes the flags: a branch losing its password is as
/// interesting as a new build on it.
pub fn branchDigest(a: std.mem.Allocator, app: App) ![]u8 {
    var out = std.Io.Writer.Allocating.init(a);
    errdefer out.deinit();
    // The mirror serves branches in a stable order, but do not rely on it.
    const list = try a.dupe(Branch, app.branches);
    std.mem.sort(Branch, list, {}, struct {
        fn lt(_: void, x: Branch, y: Branch) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    for (list) |b| try out.writer.print("{s}={s}{s}{s};", .{
        b.name, b.build_id,
        if (b.password_required) "+pwd" else "",
        if (b.lcs_required) "+lcs" else "",
    });
    return out.toOwnedSlice();
}

// ---- which apps, how often -----------------------------------------------------

/// One entry of `--app`: `<appid>[@<seconds>][:<branch>]`.
///
/// Apps do not all deserve the same attention: the one being studied is polled every
/// pass and captured on every branch, while a neighbour can be looked at every few
/// minutes and only on `public`, without a second deployment to express it.
pub const AppSpec = struct {
    id: []const u8,
    /// At least this many seconds between polls; 0 polls on every pass.
    every: u32 = 0,
    /// Only this branch; null takes every branch PICS lists.
    branch: ?[]const u8 = null,

    pub fn parse(text: []const u8) !AppSpec {
        var rest = std.mem.trim(u8, text, " ");
        var spec: AppSpec = .{ .id = "" };
        if (std.mem.indexOfScalar(u8, rest, ':')) |c| {
            spec.branch = rest[c + 1 ..];
            if (spec.branch.?.len == 0) return error.BadAppSpec;
            rest = rest[0..c];
        }
        if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
            spec.every = std.fmt.parseInt(u32, rest[at + 1 ..], 10) catch return error.BadAppSpec;
            rest = rest[0..at];
        }
        if (rest.len == 0) return error.BadAppSpec;
        for (rest) |ch| if (!std.ascii.isDigit(ch)) return error.BadAppSpec;
        spec.id = rest;
        return spec;
    }
};

/// Milliseconds from `now_ms` (wall clock) to this replica's next turn, when `n`
/// replicas share one `interval_s` and each owns an equal slice of it.
///
/// Wall clock rather than "sleep an interval after my last pass": replicas start at
/// different moments and each pass takes a little while, so relative sleeps drift
/// into bunches. Anchored to the clock, three replicas on 60s poll at :00, :20 and
/// :40 however they were started.
pub fn untilSlot(now_ms: i64, interval_s: u32, slot: u32, n: u32) i64 {
    const period: i64 = @as(i64, interval_s) * 1000;
    if (period == 0) return 0;
    const off = @divTrunc(period * @as(i64, slot % @max(n, 1)), @as(i64, @max(n, 1)));
    const next = @divFloor(now_ms - off, period) * period + off + period;
    return next - now_ms;
}

// ---- capturing a build ---------------------------------------------------------

/// How to reach DepotDownloader, and what it needs to log in.
///
/// The login token is not kept here: DepotDownloader stores it in .NET isolated
/// storage under $HOME, so an unattended run needs the same HOME every time, and a
/// first interactive login (Steam Guard) to put it there.
pub const Login = struct {
    /// Resolved on PATH unless it contains a '/'.
    exe: []const u8 = "DepotDownloader",
    /// Empty means anonymous, which only works for apps that allow it - not D2R.
    username: []const u8 = "",
    password: []const u8 = "",
    /// For a branch behind a beta password.
    branch_password: []const u8 = "",
};

/// What a depot is captured as. Small depots are taken whole, so nothing unexpected
/// in them - a .pdb, a renamed executable, a stray text file - can slip past a
/// filter; the big data depots only give up the files the filter names.
pub const Mode = union(enum) {
    whole,
    /// Comma-separated regexes, as DepotDownloader's file list takes them.
    files: []const u8,

    /// Whole below `whole_under` bytes (declared), filtered above it. No filter at all
    /// means whole regardless of size.
    pub fn choose(declared: u64, whole_under: u64, files: ?[]const u8) Mode {
        const pat = files orelse return .whole;
        if (declared < whole_under) return .whole;
        return .{ .files = pat };
    }

    /// A short, stable name for the mode, which goes into every capture marker so
    /// that widening the filter - or switching a depot to whole - captures the build
    /// again instead of finding a marker that says it is done.
    pub fn tag(self: Mode, buf: *[16]u8) []const u8 {
        return switch (self) {
            .whole => "whole",
            .files => |pat| std.fmt.bufPrint(buf, "files={x:0>8}", .{std.hash.Fnv1a_32.hash(pat)}) catch unreachable,
        };
    }
};

/// The value a capture marker holds once a depot is stored: the manifest and the
/// mode it was captured in. A marker from before modes existed holds only the
/// manifest id, and so never matches - which recaptures it once in the new mode.
pub fn markerValue(a: std.mem.Allocator, manifest: []const u8, mode: Mode) ![]u8 {
    var buf: [16]u8 = undefined;
    return std.fmt.allocPrint(a, "{s} {s}", .{ manifest, mode.tag(&buf) });
}

/// One depot of one build, as it is being captured.
pub const DepotJob = struct {
    depot: []const u8,
    manifest: []const u8,
    branch: []const u8,
    /// Comma-separated regexes; only matching files are downloaded. Null takes the
    /// whole depot. This is what makes capturing a 86GB depot for its executables
    /// cost megabytes instead.
    files: ?[]const u8 = null,
    /// Fetch and write out only the manifest's file listing, no content.
    manifest_only: bool = false,
};

/// How a DepotDownloader run ended, read from what it printed - its exit code says
/// only that something failed, and the three kinds of failure want different
/// handling: a denial is an answer to remember, a login failure needs a human, and
/// anything else is worth trying again.
pub const Outcome = struct {
    kind: Kind,
    /// Short and human: "401", "no manifest request code", the last line printed.
    reason: []const u8 = "",

    pub const Kind = enum { ok, denied, login, failed };
};

/// Steam refusing the account, the branch or the manifest. Order matters only in
/// that the first match names the reason.
const denials = [_]struct { needle: []const u8, reason: []const u8 }{
    .{ .needle = "Encountered 401", .reason = "401" },
    .{ .needle = "Encountered 403", .reason = "403" },
    .{ .needle = "No manifest request code was returned", .reason = "no manifest request code" },
    .{ .needle = "No valid depot key", .reason = "no depot key" },
    .{ .needle = "is not available from this account", .reason = "depot not available to this account" },
    .{ .needle = "Insufficient privileges", .reason = "insufficient privileges" },
    .{ .needle = "Password was invalid for branch", .reason = "branch password rejected" },
    .{ .needle = "either it does not exist or it has a password", .reason = "branch needs a password" },
};

/// The stored token is gone or refused, and only an interactive login fixes it.
/// "Unable to login to Steam3" alone is not here: it also covers a busy Steam.
const login_failures = [_][]const u8{
    "Enter account password",
    "Access token was rejected",
    "protected by Steam Guard",
    "2 factor auth code",
    "authentication code sent",
    "Failed to authenticate with Steam",
    "InvalidPassword",
};

pub fn classify(output: []const u8, exited_ok: bool) Outcome {
    for (login_failures) |n| if (std.mem.indexOf(u8, output, n) != null) return .{ .kind = .login, .reason = n };
    for (denials) |d| if (std.mem.indexOf(u8, output, d.needle) != null) return .{ .kind = .denied, .reason = d.reason };
    if (exited_ok) return .{ .kind = .ok };
    return .{ .kind = .failed, .reason = lastLine(output) };
}

fn lastLine(text: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, " \r\n"), '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len != 0) return t;
    }
    return "no output";
}

pub const Run = struct {
    outcome: Outcome,
    /// Everything DepotDownloader printed, for when the outcome alone is not enough.
    output: []const u8,
};

/// Run DepotDownloader for exactly one depot at one manifest, into `dir`.
///
/// Deliberately one depot per call rather than one app per call: the app-level
/// download filters by the host's OS, architecture and language, which would
/// silently skip most of D2R's depots. Enumerating depots from the PICS record and
/// asking for each by id captures all of them, and lets each one be uploaded and
/// deleted before the next starts, so the scratch disk only ever holds one depot.
///
/// Its output is collected rather than passed through: a capture loop logs one line
/// per depot, and the output is what says whether a failure was a denial.
pub fn downloadDepot(
    a: std.mem.Allocator,
    io: std.Io,
    login: Login,
    appid: []const u8,
    job: DepotJob,
    dir: []const u8,
) !Run {
    var argv = std.array_list.Managed([]const u8).init(a);
    try argv.appendSlice(&.{
        login.exe,
        "-app",      appid,
        "-depot",    job.depot,
        "-manifest", job.manifest,
        "-branch",   job.branch,
        "-dir",      dir,
    });
    // Verify what is already on disk instead of trusting a partial run.
    try argv.append(if (job.manifest_only) "-manifest-only" else "-validate");
    if (login.username.len != 0) {
        try argv.appendSlice(&.{ "-username", login.username });
        // With no password on the command line it uses the remembered token, which
        // is what an unattended run wants.
        if (login.password.len != 0) try argv.appendSlice(&.{ "-password", login.password });
        try argv.append("-remember-password");
    }
    if (login.branch_password.len != 0) try argv.appendSlice(&.{ "-branchpassword", login.branch_password });

    try std.Io.Dir.cwd().createDirPath(io, dir);
    // A file list is a file on disk, one pattern per line, `regex:` prefixed to match
    // rather than compare. It has to live somewhere the child can read, so it goes
    // beside the download it belongs to.
    if (job.files) |patterns| if (!job.manifest_only) {
        const list_path = try std.fmt.allocPrint(a, "{s}/.filelist.txt", .{dir});
        var out = std.Io.Writer.Allocating.init(a);
        var it = std.mem.tokenizeScalar(u8, patterns, ',');
        while (it.next()) |pat| try out.writer.print("regex:{s}\n", .{std.mem.trim(u8, pat, " ")});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = list_path, .data = out.written() });
        try argv.appendSlice(&.{ "-filelist", list_path });
    };

    // stdin is /dev/null, so a login that falls back to asking for a password reads
    // nothing and fails instead of waiting forever. The timeout is for silence, not
    // for the whole run: a big depot prints progress all the way through.
    const res = try std.process.run(a, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(600), .clock = .awake } },
    });
    const output = try std.mem.concat(a, u8, &.{ res.stdout, res.stderr });
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .outcome = classify(output, ok), .output = output };
}

/// Where `-manifest-only` writes its listing inside the download directory.
pub fn listingPath(a: std.mem.Allocator, dir: []const u8, depot: []const u8, manifest: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/manifest_{s}_{s}.txt", .{ dir, depot, manifest });
}

// ---- denied manifests ----------------------------------------------------------

/// A manifest Steam refused this account, as its marker records it:
/// `<manifest> <unix seconds of the last attempt>`, with ` lifted` appended once a
/// later attempt got through.
pub const Denied = struct {
    manifest: []const u8,
    at: i64,
    lifted: bool = false,

    pub fn parse(text: []const u8) ?Denied {
        var it = std.mem.tokenizeAny(u8, text, " \n");
        const gid = it.next() orelse return null;
        const at = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
        const lifted = if (it.next()) |w| std.mem.eql(u8, w, "lifted") else false;
        return .{ .manifest = gid, .at = at, .lifted = lifted };
    }
};

/// What to do about a manifest, given its denied marker.
pub const Retry = union(enum) {
    /// Never denied (or denied as a different manifest): try it, and a denial now is
    /// news worth one alert.
    fresh,
    /// Denied before and it is time to ask again. A denial is not news any more; a
    /// success is the thing this whole exercise waits for.
    again,
    /// Denied too recently to ask again; seconds until it may be.
    wait: i64,
    /// Denied once, then got through. Ordinary from here on.
    lifted,
};

pub fn retryDenied(marker: []const u8, manifest: []const u8, now: i64, backoff: i64) Retry {
    const d = Denied.parse(marker) orelse return .fresh;
    if (!std.mem.eql(u8, d.manifest, manifest)) return .fresh;
    if (d.lifted) return .lifted;
    const due = d.at + backoff;
    if (now < due) return .{ .wait = due - now };
    return .again;
}

// ---- file listings -------------------------------------------------------------

pub const ListedFile = struct {
    name: []const u8,
    size: u64,
    flags: u32,

    /// EDepotFileFlag.Directory.
    pub fn isDir(self: ListedFile) bool {
        return self.flags & 0x40 != 0;
    }
};

/// Parse a listing as DepotDownloader's `-manifest-only` writes it: a header, then
/// `size chunks sha1 flags name` per file, the name running to the end of the line
/// because it may contain spaces.
pub fn parseListing(a: std.mem.Allocator, text: []const u8) ![]ListedFile {
    var files = std.array_list.Managed(ListedFile).init(a);
    var in_table = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (!in_table) {
            in_table = std.mem.indexOf(u8, line, "File SHA") != null;
            continue;
        }
        if (line.len == 0) continue;
        var rest = line;
        var cols: [4][]const u8 = undefined;
        var ok = true;
        for (&cols) |*c| {
            const sp = std.mem.indexOfAny(u8, rest, " \t") orelse {
                ok = false;
                break;
            };
            c.* = rest[0..sp];
            rest = std.mem.trimStart(u8, rest[sp..], " \t");
        }
        if (!ok or rest.len == 0) continue;
        const size = std.fmt.parseInt(u64, cols[0], 10) catch continue;
        const flags = std.fmt.parseInt(u32, cols[3], 16) catch continue;
        try files.append(.{ .name = rest, .size = size, .flags = flags });
    }
    return files.toOwnedSlice();
}

/// Something in a new manifest that a retail build would not have.
pub const Anomaly = union(enum) {
    /// A debug symbol file, anywhere.
    pdb: []const u8,
    /// An executable the depot's previous manifest did not have.
    new_exe: []const u8,
    /// An executable the previous manifest had and this one does not.
    gone_exe: []const u8,
    /// An executable more than half again as big as it was. A retail D2R.exe is
    /// ~32MB; the debug builds that have escaped are over 100MB.
    grew: struct { name: []const u8, was: u64, now: u64 },
};

fn hasExt(name: []const u8, ext: []const u8) bool {
    return name.len >= ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext);
}

/// Compare a depot's new listing with the previous one it had. With no previous
/// listing only the .pdb rule can fire - there is nothing to compare names or sizes
/// against.
pub fn anomalies(a: std.mem.Allocator, prev: ?[]const ListedFile, cur: []const ListedFile) ![]Anomaly {
    var out = std.array_list.Managed(Anomaly).init(a);
    for (cur) |f| if (!f.isDir() and hasExt(f.name, ".pdb")) try out.append(.{ .pdb = f.name });

    const old = prev orelse return out.toOwnedSlice();
    for (cur) |f| {
        if (f.isDir() or !hasExt(f.name, ".exe")) continue;
        const before = findFile(old, f.name) orelse {
            try out.append(.{ .new_exe = f.name });
            continue;
        };
        if (before.size != 0 and f.size * 2 > before.size * 3)
            try out.append(.{ .grew = .{ .name = f.name, .was = before.size, .now = f.size } });
    }
    for (old) |f| {
        if (f.isDir() or !hasExt(f.name, ".exe")) continue;
        if (findFile(cur, f.name) == null) try out.append(.{ .gone_exe = f.name });
    }
    return out.toOwnedSlice();
}

/// A file that differs between two listings of a depot; null is absent.
pub const Change = struct {
    name: []const u8,
    was: ?u64,
    now: ?u64,

    pub fn delta(self: Change) u64 {
        const w = self.was orelse 0;
        const n = self.now orelse 0;
        return if (n > w) n - w else w - n;
    }
};

/// A size change worth mentioning: more than a fifth of what it was, or more than
/// 5MB whatever it was. Patches rebuild most files by a few bytes; this is the line
/// between that and a file that is materially something else.
pub fn sizeChanged(was: u64, now: u64) bool {
    const d = if (now > was) now - was else was - now;
    return d * 5 > was or d > 5 * 1024 * 1024;
}

/// Files added, removed, or changed in size by `sizeChanged` between two listings,
/// biggest change first - so the top of the list is what a human should look at.
pub fn diffListings(a: std.mem.Allocator, prev: []const ListedFile, cur: []const ListedFile) ![]Change {
    var out = std.array_list.Managed(Change).init(a);
    for (cur) |f| {
        if (f.isDir()) continue;
        if (findFile(prev, f.name)) |p| {
            if (sizeChanged(p.size, f.size)) try out.append(.{ .name = f.name, .was = p.size, .now = f.size });
        } else try out.append(.{ .name = f.name, .was = null, .now = f.size });
    }
    for (prev) |f| {
        if (f.isDir()) continue;
        if (findFile(cur, f.name) == null) try out.append(.{ .name = f.name, .was = f.size, .now = null });
    }
    std.mem.sort(Change, out.items, {}, struct {
        fn lt(_: void, x: Change, y: Change) bool {
            if (x.delta() != y.delta()) return x.delta() > y.delta();
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    return out.toOwnedSlice();
}

fn findFile(files: []const ListedFile, name: []const u8) ?ListedFile {
    for (files) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f;
    return null;
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

test "app spec" {
    const plain = try AppSpec.parse("2536520");
    try testing.expectEqualStrings("2536520", plain.id);
    try testing.expectEqual(@as(u32, 0), plain.every);
    try testing.expect(plain.branch == null);

    const slow = try AppSpec.parse(" 2344520@300:public ");
    try testing.expectEqualStrings("2344520", slow.id);
    try testing.expectEqual(@as(u32, 300), slow.every);
    try testing.expectEqualStrings("public", slow.branch.?);

    const only = try AppSpec.parse("2344520:local");
    try testing.expectEqual(@as(u32, 0), only.every);
    try testing.expectEqualStrings("local", only.branch.?);

    try testing.expectError(error.BadAppSpec, AppSpec.parse("2344520@x"));
    try testing.expectError(error.BadAppSpec, AppSpec.parse("2344520:"));
    try testing.expectError(error.BadAppSpec, AppSpec.parse("d4"));
}

test "capture mode and marker value" {
    const narrow = ".*\\.(exe|dll)$";
    const wide = ".*\\.(exe|dll|pdb|map|sym)$";

    try testing.expect(Mode.choose(90_000_000, 512 << 20, wide) == .whole);
    try testing.expect(Mode.choose(14_000_000_000, 512 << 20, wide) == .files);
    try testing.expect(Mode.choose(14_000_000_000, 512 << 20, null) == .whole);

    const a = testing.allocator;
    const m_whole = try markerValue(a, "743501523618738051", .whole);
    defer a.free(m_whole);
    const m_narrow = try markerValue(a, "743501523618738051", .{ .files = narrow });
    defer a.free(m_narrow);
    const m_wide = try markerValue(a, "743501523618738051", .{ .files = wide });
    defer a.free(m_wide);
    const m_wide2 = try markerValue(a, "743501523618738051", .{ .files = wide });
    defer a.free(m_wide2);

    try testing.expectEqualStrings("743501523618738051 whole", m_whole);
    try testing.expect(std.mem.startsWith(u8, m_narrow, "743501523618738051 files="));
    try testing.expectEqual(m_narrow.len, m_wide.len);
    // Widening the filter must not look like the same capture.
    try testing.expect(!std.mem.eql(u8, m_narrow, m_wide));
    try testing.expectEqualStrings(m_wide, m_wide2);
    // Nor must a marker written before modes existed.
    try testing.expect(!std.mem.eql(u8, "743501523618738051", m_whole));
}

test "denied backoff" {
    const gid = "3249937127314284110";
    try testing.expect(retryDenied("", gid, 1000, 900) == .fresh);
    try testing.expect(retryDenied("garbage", gid, 1000, 900) == .fresh);
    // Denied as an older manifest: this one has never been asked for.
    try testing.expect(retryDenied("111 500", gid, 1000, 900) == .fresh);

    const marker = "3249937127314284110 1000";
    try testing.expectEqual(Retry{ .wait = 900 }, retryDenied(marker, gid, 1000, 900));
    try testing.expectEqual(Retry{ .wait = 1 }, retryDenied(marker, gid, 1899, 900));
    try testing.expect(retryDenied(marker, gid, 1900, 900) == .again);
    try testing.expect(retryDenied("3249937127314284110 1000 lifted", gid, 1100, 900) == .lifted);
}

test "classify DepotDownloader output" {
    try testing.expectEqual(Outcome.Kind.ok, classify("Depot 2536522 - Downloaded 1 bytes\nDisconnected from Steam\n", true).kind);

    const denied = classify(
        \\Got depot key for 2536522 result: OK
        \\Downloading depot 2536522 manifest
        \\Encountered 401 for depot manifest 2536522 3249937127314284110. Aborting.
        \\
        \\Unable to download manifest 3249937127314284110 for depot 2536522
    , false);
    try testing.expectEqual(Outcome.Kind.denied, denied.kind);
    try testing.expectEqualStrings("401", denied.reason);

    try testing.expectEqual(Outcome.Kind.denied, classify("No manifest request code was returned for depot 1 from app 2, manifest 3\n", false).kind);
    try testing.expectEqual(Outcome.Kind.denied, classify("No valid depot key for 2536522, unable to download.\n", true).kind);

    try testing.expectEqual(Outcome.Kind.login, classify("Enter account password for \"x\": \nError: InitializeSteam failed\n", false).kind);
    try testing.expectEqual(Outcome.Kind.login, classify("Access token was rejected (AccessDenied).\n", false).kind);

    const busy = classify("Unable to login to Steam3: ServiceUnavailable\n\n", false);
    try testing.expectEqual(Outcome.Kind.failed, busy.kind);
    try testing.expectEqualStrings("Unable to login to Steam3: ServiceUnavailable", busy.reason);
}

const retail_listing =
    \\Content Manifest for Depot 2536522 
    \\
    \\Manifest ID / date     : 743501523618738051 / 7/29/2026 4:00:00 PM 
    \\Total number of files  : 4 
    \\Total number of chunks : 40 
    \\Total bytes on disk    : 59456248 
    \\Total bytes compressed : 42982800 
    \\
    \\
    \\          Size Chunks File SHA                                 Flags Name
    \\      33554432     32 0123456789abcdef0123456789abcdef01234567     0 D2R.exe
    \\        524288      1 0123456789abcdef0123456789abcdef01234567     0 BlizzardError.exe
    \\       1048576      2 0123456789abcdef0123456789abcdef01234567     0 D2R_loader.dll
    \\             0      0 0000000000000000000000000000000000000000    40 Support Files
    \\
;

test "parse a listing" {
    const files = try parseListing(testing.allocator, retail_listing);
    defer testing.allocator.free(files);
    try testing.expectEqual(@as(usize, 4), files.len);
    try testing.expectEqualStrings("D2R.exe", files[0].name);
    try testing.expectEqual(@as(u64, 33554432), files[0].size);
    try testing.expectEqualStrings("Support Files", files[3].name);
    try testing.expect(files[3].isDir());
    try testing.expect(!files[0].isDir());
}

test "listing anomalies" {
    const a = testing.allocator;
    const prev = try parseListing(a, retail_listing);
    defer a.free(prev);

    // The same build again: nothing to say.
    const same = try anomalies(a, prev, prev);
    defer a.free(same);
    try testing.expectEqual(@as(usize, 0), same.len);

    // A first listing is only checked for symbols.
    const first = try anomalies(a, null, prev);
    defer a.free(first);
    try testing.expectEqual(@as(usize, 0), first.len);

    const debug = [_]ListedFile{
        .{ .name = "D2R.exe", .size = 104_857_600, .flags = 0 },
        .{ .name = "D2R.PDB", .size = 400_000_000, .flags = 0 },
        .{ .name = "D2R_loader.dll", .size = 1048576, .flags = 0 },
        .{ .name = "D2RTest.exe", .size = 1000, .flags = 0 },
    };
    const found = try anomalies(a, prev, &debug);
    defer a.free(found);
    try testing.expectEqual(@as(usize, 4), found.len);
    try testing.expectEqualStrings("D2R.PDB", found[0].pdb);
    try testing.expectEqual(@as(u64, 33554432), found[1].grew.was);
    try testing.expectEqualStrings("D2RTest.exe", found[2].new_exe);
    try testing.expectEqualStrings("BlizzardError.exe", found[3].gone_exe);

    // Growth under half again is a normal patch.
    const patch = [_]ListedFile{
        .{ .name = "d2r.exe", .size = 33554432 + 16_000_000, .flags = 0 },
        .{ .name = "BlizzardError.exe", .size = 524288, .flags = 0 },
    };
    const quiet = try anomalies(a, prev, &patch);
    defer a.free(quiet);
    try testing.expectEqual(@as(usize, 0), quiet.len);
}

test "listing diff" {
    const a = testing.allocator;
    const prev = [_]ListedFile{
        .{ .name = "D2R.exe", .size = 33_554_432, .flags = 0 },
        .{ .name = "big.casc", .size = 100_000_000, .flags = 0 },
        .{ .name = "mid.casc", .size = 10_000_000, .flags = 0 },
        .{ .name = "tiny.txt", .size = 100, .flags = 0 },
        .{ .name = "old.dll", .size = 4096, .flags = 0 },
        .{ .name = "Data", .size = 0, .flags = 0x40 },
    };

    const same = try diffListings(a, &prev, &prev);
    defer a.free(same);
    try testing.expectEqual(@as(usize, 0), same.len);

    const cur = [_]ListedFile{
        .{ .name = "D2R.exe", .size = 33_600_000, .flags = 0 }, // a normal rebuild
        .{ .name = "big.casc", .size = 110_000_000, .flags = 0 }, // +10%, but +10MB
        .{ .name = "mid.casc", .size = 11_000_000, .flags = 0 }, // +10%, +1MB: not worth it
        .{ .name = "tiny.txt", .size = 130, .flags = 0 }, // +30%
        .{ .name = "new.pdb", .size = 2_000_000, .flags = 0 },
        .{ .name = "Data2", .size = 0, .flags = 0x40 },
    };
    const d = try diffListings(a, &prev, &cur);
    defer a.free(d);
    try testing.expectEqual(@as(usize, 4), d.len);
    try testing.expectEqualStrings("big.casc", d[0].name);
    try testing.expectEqualStrings("new.pdb", d[1].name);
    try testing.expect(d[1].was == null);
    try testing.expectEqualStrings("old.dll", d[2].name);
    try testing.expect(d[2].now == null);
    try testing.expectEqualStrings("tiny.txt", d[3].name);

    try testing.expect(!sizeChanged(1000, 1200));
    try testing.expect(sizeChanged(1000, 1201));
    try testing.expect(sizeChanged(1000, 799));
    try testing.expect(sizeChanged(1 << 30, (1 << 30) + 5 * 1024 * 1024 + 1));
    try testing.expect(!sizeChanged(1 << 30, (1 << 30) + 5 * 1024 * 1024));
}

test "replica slots" {
    // Three replicas on a 60s interval own :00, :20 and :40.
    try testing.expectEqual(@as(i64, 60_000), untilSlot(0, 60, 0, 3));
    try testing.expectEqual(@as(i64, 20_000), untilSlot(0, 60, 1, 3));
    try testing.expectEqual(@as(i64, 40_000), untilSlot(0, 60, 2, 3));
    try testing.expectEqual(@as(i64, 1_000), untilSlot(19_000, 60, 1, 3));
    // Exactly on its slot means the next one, never zero.
    try testing.expectEqual(@as(i64, 60_000), untilSlot(80_000, 60, 1, 3));
    // Wherever it starts, the next turn lands on the slot.
    const now: i64 = 1_790_188_000_123;
    try testing.expectEqual(@as(i64, 40_000), @mod(now + untilSlot(now, 60, 2, 3), 60_000));
    try testing.expectEqual(@as(i64, 0), @mod(now + untilSlot(now, 60, 0, 1), 60_000));
}
