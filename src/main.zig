//! d2r-cdn - command line front end for the `tact` library: inspect, list, fetch,
//! extract, mirror and watch a Blizzard NGDP/TACT product (D2R by default).
const std = @import("std");
const tact = @import("tact");

const usage =
    \\d2r-cdn - Blizzard NGDP/TACT client (Diablo II: Resurrected by default)
    \\
    \\usage: d2r-cdn [options] <command> [args]
    \\
    \\commands:
    \\  info                       build id, version, config hashes, cdn host, size
    \\  versions | cdns | bgdl     raw version-service tables
    \\  config [build|cdn|<hash>]  a config blob as text
    \\  archives                   the data archive hashes of this build
    \\  blob <hash> [--raw]        one data blob, BLTE-decoded unless --raw
    \\  list [pattern] [--root]    install manifest (--root: the whole file catalog)
    \\  fetch <name>...            extract install files (D2R.exe, *.dll) by name
    \\  extract [pattern]...       extract game files by root path (default: all)
    \\  mirror <dir> [--indices]   mirror the build's blobs into a pool dir, resumable
    \\  watch <dir>                poll every product channel, capture new builds
    \\
    \\options:
    \\  -p, --product <code>   product code (default osi; osib=beta, osit=test)
    \\  -r, --region <code>    region row (default us; eu, kr, cn)
    \\      --patch-host <h>   version service host (default us.patch.battle.net)
    \\      --cdn-host <h>     force a CDN host (e.g. level3.blizzard.com)
    \\      --pool <dir>       read blobs from this local mirror before the network
    \\      --cache            also write fetched blobs into --pool
    \\  -o, --out <path>       output directory (fetch/extract) or file ("-" = stdout)
    \\  -q, --quiet            no progress on stderr
    \\
    \\command options:
    \\  mirror   --indices     archive indices only, skip the 256MB archives
    \\           --max <n>     stop after n archives
    \\  extract  --flat        write basenames into one directory
    \\           --dry-run     list what would be written, extract nothing
    \\  watch    --interval <s>  loop every s seconds (default: one pass and exit)
    \\           --data          mirror the full build when a new one appears
    \\           --webhook <url> Discord webhook (or $DISCORD_WEBHOOK)
    \\           --products <l>  space-separated codes (default: known + brute force)
    \\
    \\examples:
    \\  d2r-cdn info
    \\  d2r-cdn fetch D2R.exe -o ./bin
    \\  d2r-cdn extract 'data:data/global/excel/*' -o ./out
    \\  d2r-cdn --pool /data/pool extract -o /data/game
    \\  d2r-cdn mirror /data/pool --indices
    \\  d2r-cdn watch /data --interval 60 --data
    \\
;

var quiet = false;
var io_: std.Io = undefined;
var out_buf: [64 * 1024]u8 = undefined;
var stdout_writer: std.Io.File.Writer = undefined;
var out: *std.Io.Writer = undefined;

fn note(comptime fmt: []const u8, args: anytype) void {
    if (!quiet) std.debug.print(fmt, args);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("d2r-cdn: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Args = struct {
    argv: []const []const u8,
    i: usize = 0,
    fn next(a: *Args) ?[]const u8 {
        if (a.i >= a.argv.len) return null;
        defer a.i += 1;
        return a.argv[a.i];
    }
    fn value(a: *Args, flag: []const u8) []const u8 {
        return a.next() orelse fail("{s} needs a value", .{flag});
    }
};

pub fn main(init: std.process.Init) !void {
    // Arena for the parsed command line and other small, session-long strings; the
    // general purpose allocator for file bytes, which are freed as they are written.
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    io_ = init.io;
    stdout_writer = std.Io.File.stdout().writer(io_, &out_buf);
    out = &stdout_writer.interface;
    defer out.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena);
    var args = Args{ .argv = @ptrCast(argv[1..]) };

    var opts = tact.Options{};
    var cmd: []const u8 = "";
    var rest = std.array_list.Managed([]const u8).init(arena);
    var out_path: ?[]const u8 = null;
    var flags = Flags{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--product")) {
            opts.product = args.value(arg);
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--region")) {
            opts.region = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--patch-host")) {
            opts.patch_host = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--cdn-host")) {
            opts.cdn_host = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--pool")) {
            opts.pool = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--cache")) {
            opts.cache = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            out_path = args.value(arg);
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            flags.raw = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            flags.root = true;
        } else if (std.mem.eql(u8, arg, "--indices")) {
            flags.indices = true;
        } else if (std.mem.eql(u8, arg, "--flat")) {
            flags.flat = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            flags.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--data")) {
            flags.data = true;
        } else if (std.mem.eql(u8, arg, "--max")) {
            flags.max = std.fmt.parseInt(usize, args.value(arg), 10) catch fail("--max wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--interval")) {
            flags.interval = std.fmt.parseInt(u32, args.value(arg), 10) catch fail("--interval wants seconds", .{});
        } else if (std.mem.eql(u8, arg, "--webhook")) {
            flags.webhook = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--products")) {
            flags.products = args.value(arg);
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            fail("unknown option {s} (try --help)", .{arg});
        } else if (cmd.len == 0) {
            cmd = arg;
        } else {
            try rest.append(arg);
        }
    }
    if (cmd.len == 0) {
        try out.writeAll(usage);
        return;
    }
    if (flags.webhook == null) flags.webhook = init.environ_map.get("DISCORD_WEBHOOK");

    // watch drives its own clients, one per product channel
    if (std.mem.eql(u8, cmd, "watch")) {
        const dir = if (rest.items.len > 0) rest.items[0] else fail("watch needs a destination directory", .{});
        return watch(gpa, arena, opts, dir, flags);
    }

    const cdn = tact.Cdn.open(gpa, io_, opts) catch |err| switch (err) {
        error.NoBuild => fail("no build for product '{s}' (region {s})", .{ opts.product, opts.region }),
        else => return err,
    };
    defer cdn.close();

    if (std.mem.eql(u8, cmd, "info")) {
        try info(cdn);
    } else if (std.mem.eql(u8, cmd, "versions") or std.mem.eql(u8, cmd, "cdns") or std.mem.eql(u8, cmd, "bgdl")) {
        try out.writeAll(try cdn.service(cmd));
    } else if (std.mem.eql(u8, cmd, "config")) {
        const which = if (rest.items.len > 0) rest.items[0] else "build";
        const hash = if (std.mem.eql(u8, which, "build"))
            cdn.build_config
        else if (std.mem.eql(u8, which, "cdn"))
            cdn.cdn_config
        else
            which;
        try out.writeAll(try cdn.readConfig(hash));
    } else if (std.mem.eql(u8, cmd, "archives")) {
        for (try cdn.archives()) |a| try out.print("{s}\n", .{a});
    } else if (std.mem.eql(u8, cmd, "blob")) {
        if (rest.items.len == 0) fail("blob needs a hash", .{});
        const raw = try cdn.readData(gpa, rest.items[0], null);
        defer gpa.free(raw);
        const data = if (flags.raw) raw else try tact.blteDecode(gpa, raw);
        defer if (data.ptr != raw.ptr) gpa.free(data);
        try writeOut(out_path, rest.items[0], data);
    } else if (std.mem.eql(u8, cmd, "list")) {
        try list(cdn, rest.items, flags);
    } else if (std.mem.eql(u8, cmd, "fetch")) {
        if (rest.items.len == 0) fail("fetch needs at least one install file name", .{});
        try fetch(cdn, rest.items, out_path);
    } else if (std.mem.eql(u8, cmd, "extract")) {
        try extract(arena, cdn, rest.items, out_path orelse "extracted", flags);
    } else if (std.mem.eql(u8, cmd, "mirror")) {
        const dir = if (rest.items.len > 0) rest.items[0] else out_path orelse fail("mirror needs a destination directory", .{});
        _ = try mirror(cdn, dir, flags);
    } else {
        fail("unknown command '{s}' (try --help)", .{cmd});
    }
    try out.flush();
}

const Flags = struct {
    raw: bool = false,
    root: bool = false,
    indices: bool = false,
    flat: bool = false,
    dry_run: bool = false,
    data: bool = false,
    max: usize = 0,
    interval: u32 = 0,
    webhook: ?[]const u8 = null,
    products: ?[]const u8 = null,
};

// ---- commands ------------------------------------------------------------------

fn info(cdn: *tact.Cdn) !void {
    try out.print("product     : {s}  (region {s})\n", .{ cdn.opts.product, cdn.region });
    try out.print("version     : {s}  (build {s})\n", .{ cdn.version, cdn.build_id });
    try out.print("build config: {s}\n", .{cdn.build_config});
    try out.print("cdn config  : {s}\n", .{cdn.cdn_config});
    try out.print("cdn base    : {s}\n", .{cdn.base});
    if (cdn.isEncrypted()) {
        const key = (try cdn.keyName()) orelse "unknown";
        try out.print("state       : ENCRYPTED  (needs key {s})\n", .{key});
        return;
    }
    try out.print("build name  : {s}\n", .{tact.cfgValue(cdn.build_cfg, "build-name")});
    const archs = try cdn.archives();
    try out.print("archives    : {d}  (~256MB each)\n", .{archs.len});
    const inst = cdn.install() catch &.{};
    var isize_: u64 = 0;
    for (inst) |e| isize_ += e.size;
    try out.print("install     : {d} files, {d:.1} MB\n", .{ inst.len, mb(isize_) });
    const rootn = if (cdn.root()) |r| r.len else |_| 0;
    try out.print("root        : {d} catalog files\n", .{rootn});
}

fn list(cdn: *tact.Cdn, patterns: []const []const u8, flags: Flags) !void {
    if (flags.root) {
        var n: usize = 0;
        for (try cdn.root()) |e| {
            if (!matchAny(patterns, e.path)) continue;
            try out.print("{s}\n", .{e.path});
            n += 1;
        }
        note("[list] {d} root files\n", .{n});
        return;
    }
    var total: u64 = 0;
    var n: usize = 0;
    for (try cdn.install()) |e| {
        if (!matchAny(patterns, e.name)) continue;
        try out.print("{d:>12}  {s}\n", .{ e.size, e.name });
        total += e.size;
        n += 1;
    }
    note("[list] install: {d} files, {d:.1} MB (--root lists the full catalog)\n", .{ n, mb(total) });
}

fn fetch(cdn: *tact.Cdn, names: []const []const u8, out_dir: ?[]const u8) !void {
    for (names) |name| {
        const data = cdn.extractInstall(name) catch |err| {
            std.debug.print("  {s}: {s}\n", .{ name, @errorName(err) });
            continue;
        };
        defer cdn.gpa.free(data);
        var dig: tact.Hash = undefined;
        tact.Md5.hash(data, &dig, .{});
        note("[fetch] {s}  {d} bytes  md5={s}\n", .{ name, data.len, std.fmt.bytesToHex(dig, .lower) });
        if (out_dir != null and std.mem.eql(u8, out_dir.?, "-")) {
            try out.writeAll(data);
            try out.flush();
            continue;
        }
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ out_dir orelse ".", std.fs.path.basename(name) });
        try write(path, data);
    }
}

fn extract(gpa: std.mem.Allocator, cdn: *tact.Cdn, patterns: []const []const u8, dest: []const u8, flags: Flags) !void {
    const entries = try cdn.root();
    // Resolve every wanted file to its archive slot first, so the extraction runs in
    // archive order: one sequential pass over the pool/CDN instead of random seeks.
    const enc = try cdn.encoding();
    const locs = try cdn.locations();

    const Job = struct { path: []const u8, ckey: tact.Hash, arch: u32, off: u64 };
    var jobs = std.array_list.Managed(Job).init(gpa);
    var unknown: usize = 0;
    for (entries) |e| {
        if (!matchAny(patterns, e.path)) continue;
        const ek = enc.get(e.ckey) orelse {
            unknown += 1;
            continue;
        };
        const l = locs.get(ek);
        try jobs.append(.{ .path = e.path, .ckey = e.ckey, .arch = if (l) |x| x.arch else std.math.maxInt(u32), .off = if (l) |x| x.off else 0 });
    }
    std.mem.sort(Job, jobs.items, {}, struct {
        fn less(_: void, a: Job, b: Job) bool {
            return if (a.arch == b.arch) a.off < b.off else a.arch < b.arch;
        }
    }.less);
    note("[extract] {d} files -> {s}/\n", .{ jobs.items.len, dest });
    if (unknown != 0) note("[extract] {d} files have no encoding entry (skipped)\n", .{unknown});

    var wrote: usize = 0;
    var have: usize = 0;
    var failed: usize = 0;
    var bytes: u64 = 0;
    for (jobs.items) |j| {
        const rel = relPath(j.path);
        if (flags.dry_run) {
            try out.print("{s}\n", .{rel});
            continue;
        }
        const name = if (flags.flat) std.fs.path.basename(rel) else rel;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dest, name });
        defer gpa.free(path);
        if (std.Io.Dir.cwd().access(io_, path, .{})) |_| {
            have += 1;
            continue; // already extracted: resumable
        } else |_| {}
        const data = cdn.extract(j.ckey) catch |err| {
            failed += 1;
            if (failed < 20) note("  {s}: {s}\n", .{ rel, @errorName(err) });
            continue;
        };
        defer cdn.gpa.free(data);
        if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io_, d) catch {};
        std.Io.Dir.cwd().writeFile(io_, .{ .sub_path = path, .data = data }) catch {
            failed += 1;
            continue;
        };
        wrote += 1;
        bytes += data.len;
        if (wrote % 2000 == 0) note("  {d}/{d} files, {d:.1} MB\n", .{ wrote + have, jobs.items.len, mb(bytes) });
    }
    if (!flags.dry_run) note("[extract] done: {d} written ({d:.1} MB), {d} already there, {d} failed\n", .{ wrote, mb(bytes), have, failed });
}

fn mirror(cdn: *tact.Cdn, dest: []const u8, flags: Flags) !u64 {
    const blobs = try cdn.blobs(cdn.gpa, .{ .indices_only = flags.indices, .max_archives = flags.max });
    defer cdn.gpa.free(blobs);
    note("[mirror] {s} build {s} -> {s}  ({d} blobs)\n", .{ cdn.opts.product, cdn.version, dest, blobs.len });

    var got: u64 = 0;
    var failed: usize = 0;
    for (blobs) |b| {
        const st = cdn.download(dest, b) catch tact.Fetched.failed;
        switch (st) {
            .skipped => note("s", .{}),
            .downloaded => {
                note(".", .{});
                got += 1;
            },
            .resumed => {
                note("r", .{});
                got += 1;
            },
            .failed => {
                note("X", .{});
                failed += 1;
            },
        }
    }
    note("\n[mirror] {d} blobs fetched, {d} failed\n", .{ got, failed });
    return got;
}

// ---- watch ---------------------------------------------------------------------

const known_products = [_][]const u8{ "osi", "osit", "osic", "osib", "osia", "osidev", "osiv1", "osiv2", "osiv3", "osiv4", "osiv5", "osiv6" };
const extra_products = [_][]const u8{ "osiqa", "osistage", "osiptr", "osiinternal", "osicert", "osivendor", "osidemo", "osilive", "osipatch" };

fn watch(gpa: std.mem.Allocator, arena: std.mem.Allocator, base_opts: tact.Options, dir: []const u8, flags: Flags) !void {
    var products = std.array_list.Managed([]const u8).init(arena);
    if (flags.products) |list_| {
        var it = std.mem.tokenizeAny(u8, list_, " ,");
        while (it.next()) |p| try products.append(p);
    } else {
        for (known_products) |p| try products.append(p);
        for (extra_products) |p| try products.append(p);
        // brute space: osia..osiz, catches a code Blizzard adds without telling anyone
        for ('a'..'z' + 1) |c| try products.append(try std.fmt.allocPrint(arena, "osi{c}", .{@as(u8, @intCast(c))}));
    }
    const state_dir = try std.fmt.allocPrint(arena, "{s}/state", .{dir});
    const pool = try std.fmt.allocPrint(arena, "{s}/pool", .{dir});
    try std.Io.Dir.cwd().createDirPath(io_, state_dir);

    note("[watch] {d} product channels -> {s}\n", .{ products.items.len, dir });
    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    while (true) {
        for (products.items) |p| {
            scanProduct(gpa, pass_arena.allocator(), base_opts, p, dir, state_dir, pool, flags) catch |err| switch (err) {
                error.NoBuild, error.HttpStatus, error.NoCdnRow => {},
                else => note("[watch] {s}: {s}\n", .{ p, @errorName(err) }),
            };
        }
        if (flags.interval == 0) return;
        _ = pass_arena.reset(.retain_capacity); // a pass leaves nothing behind but state files
        try io_.sleep(.fromMilliseconds(@as(i64, flags.interval) * 1000), .awake);
    }
}

fn scanProduct(gpa: std.mem.Allocator, a: std.mem.Allocator, base_opts: tact.Options, product: []const u8, dir: []const u8, state_dir: []const u8, pool: []const u8, flags: Flags) !void {
    var opts = base_opts;
    opts.product = product;
    const cdn = try tact.Cdn.open(gpa, io_, opts);
    defer cdn.close();
    if (cdn.build_config.len == 0) return error.NoBuild;

    const enc = cdn.isEncrypted();
    const key = if (enc) (try cdn.keyName()) orelse "" else "";
    const tag = if (enc) "ENCRYPTED" else "PLAINTEXT";

    // A confirmed encrypted -> plaintext transition is the interesting event: an
    // internal channel that just became readable.
    const enc_state = try readState(a, state_dir, product, ".enc");
    if (std.mem.eql(u8, enc_state, "1") and !enc)
        try alert(a, flags.webhook, try std.fmt.allocPrint(a, "@@@ {s} WENT PLAINTEXT (was encrypted) - {s} - POSSIBLE INTERNAL LEAK @@@", .{ product, cdn.version }));
    try writeState(state_dir, product, ".enc", if (enc) "1" else "0");

    const last = try readState(a, state_dir, product, "");
    if (!std.mem.eql(u8, last, cdn.build_config)) {
        const msg = if (last.len == 0)
            try std.fmt.allocPrint(a, "NEW PRODUCT {s}: {s} [{s}]{s}{s} ({s})", .{ product, cdn.version, tag, if (key.len != 0) " needs-key=" else "", key, cdn.region })
        else
            try std.fmt.allocPrint(a, "{s} NEW BUILD: {s} [{s}]{s}{s} ({s})", .{ product, cdn.version, tag, if (key.len != 0) " needs-key=" else "", key, cdn.region });
        try alert(a, flags.webhook, msg);

        const bdir = try std.fmt.allocPrint(a, "{s}/builds/{s}", .{ dir, product });
        try std.Io.Dir.cwd().createDirPath(io_, bdir);
        const json = try std.fmt.allocPrint(a,
            \\{{"product":"{s}","version":"{s}","region":"{s}","build_config":"{s}","cdn_config":"{s}","encrypted":{s},"key_name":"{s}","ts":"{s}"}}
            \\
        , .{ product, cdn.version, cdn.region, cdn.build_config, cdn.cdn_config, if (enc) "true" else "false", key, try isoNow(a) });
        const jpath = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ bdir, if (cdn.version.len != 0) cdn.version else cdn.build_config });
        try std.Io.Dir.cwd().writeFile(io_, .{ .sub_path = jpath, .data = json });
        try writeState(state_dir, product, "", cdn.build_config);
    }

    // Capture the build itself. Encrypted channels have no readable archive list, so
    // only the configs are worth keeping there.
    if (flags.data and !enc) {
        const done = try readState(a, state_dir, product, ".data");
        if (!std.mem.eql(u8, done, cdn.build_config)) {
            try alert(a, flags.webhook, try std.fmt.allocPrint(a, "{s} DOWNLOADING {s} ...", .{ product, cdn.version }));
            const n = mirror(cdn, pool, flags) catch {
                try alert(a, flags.webhook, try std.fmt.allocPrint(a, "{s} download FAILED {s} (will retry)", .{ product, cdn.version }));
                return;
            };
            try writeState(state_dir, product, ".data", cdn.build_config);
            try alert(a, flags.webhook, try std.fmt.allocPrint(a, "{s} DONE {s} ({d} new blobs)", .{ product, cdn.version, n }));
        }
    }
}

fn readState(gpa: std.mem.Allocator, state_dir: []const u8, product: []const u8, suffix: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ state_dir, product, suffix });
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io_, path, gpa, .limited(256)) catch return "";
    return std.mem.trim(u8, data, " \n\r");
}

fn writeState(state_dir: []const u8, product: []const u8, suffix: []const u8, value: []const u8) !void {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ state_dir, product, suffix });
    try std.Io.Dir.cwd().writeFile(io_, .{ .sub_path = path, .data = value });
}

fn alert(gpa: std.mem.Allocator, webhook: ?[]const u8, msg: []const u8) !void {
    std.debug.print(">> {s}\n", .{msg});
    const url = webhook orelse return;
    if (url.len == 0) return;
    var client: std.http.Client = .{ .allocator = gpa, .io = io_ };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    try body.writer.writeAll("{\"content\":\"");
    try std.json.Stringify.encodeJsonStringChars(msg, .{}, &body.writer);
    try body.writer.writeAll("\"}");
    _ = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body.written(),
        .headers = .{ .content_type = .{ .override = "application/json" } },
    }) catch |err| std.debug.print("   (webhook failed: {s})\n", .{@errorName(err)});
}

fn isoNow(gpa: std.mem.Allocator) ![]const u8 {
    const secs: u64 = @intCast(@divFloor(std.Io.Timestamp.now(io_, .real).nanoseconds, std.time.ns_per_s));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(gpa, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

// ---- helpers -------------------------------------------------------------------

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1e6;
}

fn matchAny(patterns: []const []const u8, name: []const u8) bool {
    if (patterns.len == 0) return true;
    for (patterns) |p| if (tact.globMatch(p, name)) return true;
    return false;
}

/// Root paths are prefixed with the CASC namespace ("data:data/global/...").
fn relPath(path: []const u8) []const u8 {
    var p = path;
    if (std.mem.indexOfScalar(u8, p, ':')) |c| p = p[c + 1 ..];
    while (p.len != 0 and (p[0] == '/' or p[0] == '\\')) p = p[1..];
    return p;
}

/// `-o -` writes to stdout, `-o <path>` writes that file, no `-o` writes ./<basename>.
fn writeOut(out_path: ?[]const u8, name: []const u8, data: []const u8) !void {
    const dest = out_path orelse std.fs.path.basename(name);
    if (std.mem.eql(u8, dest, "-")) {
        try out.writeAll(data);
        try out.flush();
        return;
    }
    const is_dir = if (std.Io.Dir.cwd().statFile(io_, dest, .{})) |st| st.kind == .directory else |_| false;
    var buf: [1024]u8 = undefined;
    try write(if (is_dir) try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dest, std.fs.path.basename(name) }) else dest, data);
}

fn write(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io_, d) catch {};
    try std.Io.Dir.cwd().writeFile(io_, .{ .sub_path = path, .data = data });
    note("[write] {s}  ({d} bytes)\n", .{ path, data.len });
}
