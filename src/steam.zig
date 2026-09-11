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
        if (manifests) |mv| switch (mv) {
            .object => |mm| if (mm.get(branch_name)) |bm| {
                d.manifest = str(bm, "gid");
                d.size = std.fmt.parseInt(u64, str(bm, "size"), 10) catch 0;
            },
            else => {},
        };
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

/// One depot of one build, as it is being captured.
pub const DepotJob = struct {
    depot: []const u8,
    manifest: []const u8,
    branch: []const u8,
};

/// Run DepotDownloader for exactly one depot at one manifest, into `dir`.
///
/// Deliberately one depot per call rather than one app per call: the app-level
/// download filters by the host's OS, architecture and language, which would
/// silently skip most of D2R's depots. Enumerating depots from the PICS record and
/// asking for each by id captures all of them, and lets each one be uploaded and
/// deleted before the next starts, so the scratch disk only ever holds one depot.
pub fn downloadDepot(
    a: std.mem.Allocator,
    io: std.Io,
    login: Login,
    appid: []const u8,
    job: DepotJob,
    dir: []const u8,
) !void {
    var argv = std.array_list.Managed([]const u8).init(a);
    try argv.appendSlice(&.{
        login.exe,
        "-app",      appid,
        "-depot",    job.depot,
        "-manifest", job.manifest,
        "-branch",   job.branch,
        "-dir",      dir,
        // Verify what is already on disk instead of trusting a partial run.
        "-validate",
    });
    if (login.username.len != 0) {
        try argv.appendSlice(&.{ "-username", login.username });
        // With no password on the command line it uses the remembered token, which
        // is what an unattended run wants.
        if (login.password.len != 0) try argv.appendSlice(&.{ "-password", login.password });
        try argv.append("-remember-password");
    }
    if (login.branch_password.len != 0) try argv.appendSlice(&.{ "-branchpassword", login.branch_password });

    var child = try std.process.spawn(io, .{ .argv = argv.items });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.DepotDownloadFailed,
        else => return error.DepotDownloadFailed,
    }
}
