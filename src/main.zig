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
    \\  mirror <dest> [--indices]  mirror the build's blobs into a pool, resumable
    \\  watch <dest>               poll every product channel, capture new builds
    \\  steam [<dest>]             poll the Steam branch table (no login needed)
    \\  steam-capture <dest>       download Steam depots (needs an owning account)
    \\
    \\options:
    \\  -p, --product <code>   product code (default osi; osib=beta, osit=test)
    \\  -r, --region <code>    region row (default us; eu, kr, cn)
    \\      --patch-host <h>   version service host (default us.patch.battle.net)
    \\      --cdn-host <h>     force a CDN host (e.g. level3.blizzard.com)
    \\      --pool <dest>      read blobs from this mirror before the network
    \\      --cache            also write fetched blobs into --pool
    \\  -o, --out <path>       output directory (fetch/extract) or file ("-" = stdout)
    \\  -q, --quiet            no progress on stderr
    \\
    \\a <dest> is a directory or s3://<bucket>/<prefix>; a bucket reads S3_ENDPOINT,
    \\S3_REGION, AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from the environment
    \\
    \\command options:
    \\  mirror   --indices     archive indices only, skip the 256MB archives
    \\           --max <n>     stop after n archives
    \\  extract  --flat        write basenames into one directory
    \\           --dry-run     list what would be written, extract nothing
    \\  watch    --interval <s>  loop every s seconds (default: one pass and exit)
    \\           --data          mirror the full build when a new one appears
    \\  steam    --app <spec,..> Steam apps, each <appid>[@<seconds>][:<branch>]: poll no
    \\                           more often than that, capture only that branch
    \\                           (default 2536520, D2R Infernal Edition)
    \\           --branch <name> which branch's manifest ids to report (default public)
    \\           --interval <s>  loop every s seconds
    \\           --stagger <n>   one of n replicas: offset the first pass by my slot
    \\  steam-capture            list and download every branch's depots (needs a Steam
    \\                           account); --app, --branch and --interval as for steam
    \\           --files <re,..> big depots: only files matching these regexes,
    \\                           e.g. '.*\.(exe|dll|pdb)$'
    \\           --whole-under <mb> depots smaller than this are taken whole (default 512)
    \\           --scratch <dir> where a depot is staged before upload (default ./steam-scratch)
    \\           --manifest <id> one older build by manifest id (with --depot)
    \\           --depot <id>    just this depot
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
    \\  d2r-cdn steam s3://bucket/d2r --interval 900
    \\  d2r-cdn steam-capture s3://bucket/d2r --interval 20 --files '.*\.(exe|dll|pdb)$'
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
        } else if (std.mem.eql(u8, arg, "--app")) {
            flags.app = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--stagger")) {
            flags.stagger = std.fmt.parseInt(u32, args.value(arg), 10) catch fail("--stagger wants a count", .{});
        } else if (std.mem.eql(u8, arg, "--branch")) {
            flags.branch = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--branchpassword")) {
            flags.branch_password = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--files")) {
            flags.files = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--scratch")) {
            flags.scratch = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--depot")) {
            flags.depot = args.value(arg);
        } else if (std.mem.eql(u8, arg, "--whole-under")) {
            const n = std.fmt.parseInt(u64, args.value(arg), 10) catch fail("--whole-under wants megabytes", .{});
            flags.whole_under = n * 1024 * 1024;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            flags.manifest = args.value(arg);
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
    // A bucket pool needs a service and keys; the command line never carries secrets.
    opts.s3 = .{
        .host = init.environ_map.get("S3_ENDPOINT") orelse init.environ_map.get("AWS_ENDPOINT_URL") orelse "",
        .region = init.environ_map.get("S3_REGION") orelse init.environ_map.get("AWS_REGION") orelse "us-east-1",
        .access_key = init.environ_map.get("AWS_ACCESS_KEY_ID") orelse "",
        .secret_key = init.environ_map.get("AWS_SECRET_ACCESS_KEY") orelse "",
    };

    if (std.mem.eql(u8, cmd, "steam-capture")) {
        const dest = if (rest.items.len > 0) rest.items[0] else fail("steam-capture needs a destination", .{});
        return steamCapture(gpa, arena, opts, dest, flags, init.environ_map);
    }

    if (std.mem.eql(u8, cmd, "steam")) {
        return steamWatch(gpa, arena, opts, if (rest.items.len > 0) rest.items[0] else null, flags);
    }

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
        const spec = if (rest.items.len > 0) rest.items[0] else out_path orelse fail("mirror needs a destination", .{});
        const dest = tact.Store.open(gpa, io_, spec, opts.s3) catch |err| fail("pool {s}: {s}", .{ spec, @errorName(err) });
        defer dest.close();
        _ = try mirror(cdn, dest, flags);
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
    app: []const u8 = tact.steam.d2r_appid,
    stagger: u32 = 0,
    /// Only this branch. The watcher reports manifests for it (default public); a
    /// capture takes every branch unless told otherwise.
    branch: ?[]const u8 = null,
    /// Depots declared smaller than this are captured whole, bigger ones filtered.
    whole_under: u64 = 512 * 1024 * 1024,
    branch_password: []const u8 = "",
    files: ?[]const u8 = null,
    scratch: []const u8 = "./steam-scratch",
    depot: ?[]const u8 = null,
    manifest: ?[]const u8 = null,
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

fn mirror(cdn: *tact.Cdn, dest: *tact.Store, flags: Flags) !u64 {
    const blobs = try cdn.blobs(cdn.gpa, .{ .indices_only = flags.indices, .max_archives = flags.max });
    defer cdn.gpa.free(blobs);
    note("[mirror] {s} build {s} -> {s}  ({d} blobs)\n", .{ cdn.opts.product, cdn.version, dest.spec, blobs.len });

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

fn watch(gpa: std.mem.Allocator, arena: std.mem.Allocator, base_opts: tact.Options, spec: []const u8, flags: Flags) !void {
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

    // The channel history and the blobs live in the same place, one prefix apart -
    // a directory on this machine or a bucket, decided by `spec` alone.
    const root = tact.Store.open(gpa, io_, spec, base_opts.s3) catch |err| fail("{s}: {s}", .{ spec, @errorName(err) });
    defer root.close();
    const pool_spec = try std.fmt.allocPrint(arena, "{s}/pool", .{std.mem.trimEnd(u8, spec, "/")});
    const pool = tact.Store.open(gpa, io_, pool_spec, base_opts.s3) catch |err| fail("{s}: {s}", .{ pool_spec, @errorName(err) });
    defer pool.close();

    note("[watch] {d} product channels -> {s}\n", .{ products.items.len, root.spec });
    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    while (true) {
        for (products.items) |p| {
            scanProduct(gpa, pass_arena.allocator(), base_opts, p, root, pool, flags) catch |err| switch (err) {
                error.NoBuild, error.HttpStatus, error.NoCdnRow => {},
                else => note("[watch] {s}: {s}\n", .{ p, @errorName(err) }),
            };
        }
        if (flags.interval == 0) return;
        _ = pass_arena.reset(.retain_capacity); // a pass leaves nothing behind but state
        try io_.sleep(.fromMilliseconds(@as(i64, flags.interval) * 1000), .awake);
    }
}

fn scanProduct(gpa: std.mem.Allocator, a: std.mem.Allocator, base_opts: tact.Options, product: []const u8, root: *tact.Store, pool: *tact.Store, flags: Flags) !void {
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
    const enc_state = try readState(a, root, product, ".enc");
    if (std.mem.eql(u8, enc_state, "1") and !enc)
        try alert(a, flags.webhook, try std.fmt.allocPrint(a, "@@@ {s} WENT PLAINTEXT (was encrypted) - {s} - POSSIBLE INTERNAL LEAK @@@", .{ product, cdn.version }));
    try writeState(a, root, product, ".enc", if (enc) "1" else "0");

    const last = try readState(a, root, product, "");
    if (!std.mem.eql(u8, last, cdn.build_config)) {
        const msg = if (last.len == 0)
            try std.fmt.allocPrint(a, "NEW PRODUCT {s}: {s} [{s}]{s}{s} ({s})", .{ product, cdn.version, tag, if (key.len != 0) " needs-key=" else "", key, cdn.region })
        else
            try std.fmt.allocPrint(a, "{s} NEW BUILD: {s} [{s}]{s}{s} ({s})", .{ product, cdn.version, tag, if (key.len != 0) " needs-key=" else "", key, cdn.region });
        try alert(a, flags.webhook, msg);

        const json = try std.fmt.allocPrint(a,
            \\{{"product":"{s}","version":"{s}","region":"{s}","build_config":"{s}","cdn_config":"{s}","encrypted":{s},"key_name":"{s}","ts":"{s}"}}
            \\
        , .{ product, cdn.version, cdn.region, cdn.build_config, cdn.cdn_config, if (enc) "true" else "false", key, try isoNow(a) });
        const label = if (cdn.version.len != 0) cdn.version else cdn.build_config;
        const jkey = try std.fmt.allocPrint(a, "builds/{s}/{s}.json", .{ product, label });
        try root.writeObject(a, jkey, json);

        // The versions/cdns rows are what make a build reconstructible later: the CDN
        // stops serving them once the build rotates out, and without them the blobs
        // are an unindexed heap.
        for ([_][]const u8{ "versions", "cdns" }) |endpoint| {
            const table = cdn.service(endpoint) catch continue;
            const tkey = try std.fmt.allocPrint(a, "builds/{s}/{s}.{s}", .{ product, label, endpoint });
            root.writeObject(a, tkey, table) catch {};
        }
        try writeState(a, root, product, "", cdn.build_config);
    }

    // Capture the build itself. Encrypted channels have no readable archive list, so
    // only the configs are worth keeping there.
    if (flags.data and !enc) {
        const done = try readState(a, root, product, ".data");
        if (!std.mem.eql(u8, done, cdn.build_config)) {
            try alert(a, flags.webhook, try std.fmt.allocPrint(a, "{s} DOWNLOADING {s} ...", .{ product, cdn.version }));
            const n = mirror(cdn, pool, flags) catch {
                try alert(a, flags.webhook, try std.fmt.allocPrint(a, "{s} download FAILED {s} (will retry)", .{ product, cdn.version }));
                return;
            };
            try writeState(a, root, product, ".data", cdn.build_config);
            try alert(a, flags.webhook, try std.fmt.allocPrint(a, "{s} DONE {s} ({d} new blobs)", .{ product, cdn.version, n }));
            // The blobs are content-addressed and say nothing about what they are.
            // Keeping the build's own executables decoded means a build can be
            // identified - and diffed against the next one - without rebuilding the
            // whole CASC view first.
            captureBinaries(a, cdn, root, product) catch |err|
                note("[watch] {s}: binaries: {s}\n", .{ product, @errorName(err) });
        }
    }
}

/// Decode this build's install files (the exes and dlls) into
/// `binaries/<product>-<build>/`. Cheap next to the archives - about 88MB for osi -
/// and it is the only part of the mirror a human can identify on sight.
fn captureBinaries(a: std.mem.Allocator, cdn: *tact.Cdn, root: *tact.Store, product: []const u8) !void {
    const entries = try cdn.install();
    const label = if (cdn.build_id.len != 0) cdn.build_id else cdn.build_config;
    var wrote: usize = 0;
    for (entries) |e| {
        const key = try std.fmt.allocPrint(a, "binaries/{s}-{s}/{s}", .{ product, label, std.fs.path.basename(e.name) });
        if ((root.objectSize(a, key) catch null) != null) continue;
        const data = cdn.extractInstall(e.name) catch continue;
        defer cdn.gpa.free(data);
        try root.writeObject(a, key, data);
        wrote += 1;
    }
    if (wrote != 0) note("[watch] {s}: {d} binaries -> binaries/{s}-{s}/\n", .{ product, wrote, product, label });
}

// ---- steam ---------------------------------------------------------------------

fn nowMs() i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io_, .real).nanoseconds, std.time.ns_per_ms));
}

fn nowSecs() i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io_, .real).nanoseconds, std.time.ns_per_s));
}

fn appSpecs(a: std.mem.Allocator, list_: []const u8) ![]tact.steam.AppSpec {
    var specs = std.array_list.Managed(tact.steam.AppSpec).init(a);
    var it = std.mem.tokenizeAny(u8, list_, " ,");
    while (it.next()) |s| try specs.append(tact.steam.AppSpec.parse(s) catch
        fail("--app: '{s}' is not <appid>[@<seconds>][:<branch>]", .{s}));
    return specs.toOwnedSlice();
}

/// Whether an app with a slower cadence is due. Half an interval of slack, so an app
/// asking for 300s on a 60s loop is polled every fifth pass rather than every sixth.
fn due(spec: tact.steam.AppSpec, last: i64, now: i64, interval: u32) bool {
    if (spec.every == 0 or last == 0) return true;
    return now - last + @divTrunc(@as(i64, interval), 2) >= spec.every;
}

/// Longest a poller backs off to while the PICS mirror answers 429.
const max_backoff: u32 = 900;

fn steamWatch(gpa: std.mem.Allocator, arena: std.mem.Allocator, base_opts: tact.Options, spec: ?[]const u8, flags: Flags) !void {
    // No destination: just report what Steam is serving right now.
    const root: ?*tact.Store = if (spec) |sp|
        tact.Store.open(gpa, io_, sp, base_opts.s3) catch |err| fail("{s}: {s}", .{ sp, @errorName(err) })
    else
        null;
    defer if (root) |r| r.close();

    const apps = try appSpecs(arena, flags.app);
    const last = try arena.alloc(i64, apps.len);
    @memset(last, 0);

    // Several replicas watching the same thing should spread themselves across the
    // interval rather than all polling at once: the point of running them on separate
    // hosts is separate egress, which is wasted if they fire together. The slot comes
    // from the pod's own ordinal, so nothing has to be configured per replica, and is
    // held to the wall clock so the replicas stay evenly apart.
    const slot: u32 = if (flags.stagger > 1) ordinal() % flags.stagger else 0;
    const slots: u32 = @max(flags.stagger, 1);
    if (flags.stagger > 1 and flags.interval != 0) {
        const wait = tact.steam.untilSlot(nowMs(), flags.interval, slot, slots);
        note("[steam] replica {d}/{d}: first pass in {d}s\n", .{ slot, slots, @divTrunc(wait, 1000) });
        try io_.sleep(.fromMilliseconds(wait), .awake);
    }

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    var delay = flags.interval;
    while (true) {
        var limited = false;
        for (apps, 0..) |app, i| {
            const now = nowSecs();
            if (!due(app, last[i], now, flags.interval)) continue;
            last[i] = now;
            steamPass(pass_arena.allocator(), root, flags, app.id) catch |err| {
                if (err == error.SteamRateLimited) limited = true;
                note("[steam] {s}: {s}\n", .{ app.id, @errorName(err) });
            };
        }
        if (flags.interval == 0) return;
        _ = pass_arena.reset(.{ .retain_with_limit = 4 << 20 });
        if (limited) {
            delay = @min(@max(delay, flags.interval) * 2, max_backoff);
            note("[steam] rate limited by the PICS mirror, next pass in {d}s\n", .{delay});
            try io_.sleep(.fromMilliseconds(@as(i64, delay) * 1000), .awake);
        } else {
            delay = flags.interval;
        }
        try io_.sleep(.fromMilliseconds(tact.steam.untilSlot(nowMs(), flags.interval, slot, slots)), .awake);
    }
}

/// This replica's number, from the trailing digits of the hostname - which for a
/// StatefulSet pod is `<name>-<ordinal>`. Anything else is replica 0.
fn ordinal() u32 {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = std.posix.gethostname(&buf) catch return 0;
    const dash = std.mem.lastIndexOfScalar(u8, host, '-') orelse return 0;
    return std.fmt.parseInt(u32, host[dash + 1 ..], 10) catch 0;
}

fn steamPass(a: std.mem.Allocator, root: ?*tact.Store, flags: Flags, appid: []const u8) !void {
    const branch_name = flags.branch orelse "public";
    const app = try tact.steam.fetchApp(a, io_, appid, branch_name);
    const digest = try tact.steam.branchDigest(a, app);

    const store = root orelse {
        note("[steam] {s} ({s}) - {d} branches, {d} depots, {d:.1} GB on {s}{s}\n", .{
            app.name,               app.appid, app.branches.len, app.depots.len,
            gb(app.totalSize()), branch_name, if (app.private_branches) ", has private branches" else "",
        });
        for (app.branches) |b| note("  {s:<16} build {s:<10}{s}{s} {s}\n", .{
            b.name,                                 b.build_id,
            if (b.password_required) " [pwd]" else "", if (b.lcs_required) " [lcs]" else "",
            b.description,
        });
        return;
    };
    // One line a pass: a loop that polls every minute should not print a table.
    note("[steam] {s} {s}{s}\n", .{ app.appid, digest, if (app.private_branches) " privatebranches" else "" });

    const key_prefix = try std.fmt.allocPrint(a, "steam/{s}", .{app.appid});

    // A branch appearing, vanishing, losing its password or moving to a new build
    // all show up as a different digest.
    const last = try store.readText(a, try std.fmt.allocPrint(a, "{s}/state/branches", .{key_prefix}));
    if (!std.mem.eql(u8, last, digest)) {
        if (last.len == 0) {
            try alert(a, flags.webhook, try std.fmt.allocPrint(a, "STEAM {s} first seen: {s}", .{ app.appid, digest }));
        } else {
            try alert(a, flags.webhook, try std.fmt.allocPrint(a, "STEAM {s} BRANCHES CHANGED\nwas: {s}\nnow: {s}", .{ app.appid, last, digest }));
            // A branch nobody had seen before is the one worth shouting about.
            for (app.branches) |b| {
                const needle = try std.fmt.allocPrint(a, "{s}=", .{b.name});
                if (std.mem.indexOf(u8, last, needle) == null)
                    try alert(a, flags.webhook, try std.fmt.allocPrint(a, "@@@ STEAM {s} NEW BRANCH '{s}' build {s}{s} @@@", .{
                        app.appid, b.name,             b.build_id,
                        if (b.password_required) " (password protected)" else if (b.lcs_required) " (local content server)" else " - OPEN",
                    }));
            }
        }

        // The record as served is the archive: manifest ids stay fetchable from Steam
        // long after the branch has moved on, so keeping them keeps the build.
        for (app.branches) |b| {
            const jkey = try std.fmt.allocPrint(a, "{s}/builds/{s}-{s}.json", .{ key_prefix, b.name, b.build_id });
            if ((store.objectSize(a, jkey) catch null) != null) continue;
            try store.writeObject(a, jkey, app.raw);
        }
        try store.writeObject(a, try std.fmt.allocPrint(a, "{s}/state/branches", .{key_prefix}), digest);
    }

    const pb_key = try std.fmt.allocPrint(a, "{s}/state/privatebranches", .{key_prefix});
    const pb_now = if (app.private_branches) "1" else "0";
    const pb_last = try store.readText(a, pb_key);
    if (pb_last.len != 0 and !std.mem.eql(u8, pb_last, pb_now))
        try alert(a, flags.webhook, try std.fmt.allocPrint(a, "STEAM {s} private-branches flag {s} -> {s}", .{ app.appid, pb_last, pb_now }));
    if (!std.mem.eql(u8, pb_last, pb_now)) try store.writeObject(a, pb_key, pb_now);
}

/// Capture Steam builds: every depot of every branch, downloaded one at a time and
/// uploaded as it completes, so the scratch disk only ever holds one depot.
///
/// Depot bytes need an account that owns the app - Steam issues depot keys only after
/// an ownership check - so unlike the rest of this tool, this half cannot run
/// anonymously. The login token lives in DepotDownloader's isolated storage under
/// $HOME, so an unattended run needs a persistent HOME and one interactive login
/// first to satisfy Steam Guard.
///
/// With --interval it loops, and is built to: a depot it has seen through costs no
/// request at all on later passes, a manifest Steam refuses is asked for again only
/// every quarter hour, and nothing reaches Discord unless something changed.
fn steamCapture(gpa: std.mem.Allocator, arena: std.mem.Allocator, base_opts: tact.Options, dest: []const u8, flags: Flags, env: *const std.process.Environ.Map) !void {
    const store = tact.Store.open(gpa, io_, dest, base_opts.s3) catch |err| fail("{s}: {s}", .{ dest, @errorName(err) });
    defer store.close();

    const login: tact.steam.Login = .{
        .exe = env.get("DEPOTDOWNLOADER") orelse "DepotDownloader",
        .username = env.get("STEAM_USERNAME") orelse "",
        .password = env.get("STEAM_PASSWORD") orelse "",
        .branch_password = flags.branch_password,
    };

    if (flags.manifest) |gid| return captureManifest(arena, store, login, flags, gid);

    const apps = try appSpecs(arena, flags.app);
    var cap: Capture = .{
        .gpa = gpa,
        .store = store,
        .login = login,
        .flags = flags,
        .login_hint = env.get("STEAM_LOGIN_HINT") orelse
            "log in once, interactively, with the same HOME: DepotDownloader -app <appid> -manifest-only -username <name> -remember-password",
    };
    defer cap.deinit();
    const last = try arena.alloc(i64, apps.len);
    @memset(last, 0);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    var delay = flags.interval;
    while (true) {
        const a = pass_arena.allocator();
        var limited = false;
        cap.failures = 0;
        for (apps, 0..) |spec, i| {
            const now = nowSecs();
            if (!due(spec, last[i], now, flags.interval)) continue;
            last[i] = now;
            // The first app listed is the one that matters: it gets every pass in
            // full. The others get one DepotDownloader run a pass, so a new build of
            // theirs is caught up on over a few passes instead of stalling the first
            // app's cadence while it downloads.
            cap.budget = if (i == 0) null else 1;
            cap.captureApp(a, spec) catch |err| switch (err) {
                // Every later depot would fail the same way; one alert, then wait.
                error.SteamLogin => {
                    cap.loginFailed(a) catch |e| note("[capture] login alert: {s}\n", .{@errorName(e)});
                    cap.failures += 1;
                    break;
                },
                error.SteamRateLimited => {
                    limited = true;
                    note("[capture] {s}: rate limited by the PICS mirror\n", .{spec.id});
                },
                else => {
                    note("[capture] {s}: {s}\n", .{ spec.id, @errorName(err) });
                    cap.failures += 1;
                },
            };
        }
        if (flags.interval == 0) {
            if (cap.failures != 0) return error.CaptureIncomplete;
            return;
        }
        _ = pass_arena.reset(.{ .retain_with_limit = 8 << 20 });
        delay = if (limited) @min(@max(delay, flags.interval) * 2, max_backoff) else flags.interval;
        if (limited) note("[capture] backing off, next pass in {d}s\n", .{delay});
        try io_.sleep(.fromMilliseconds(@as(i64, delay) * 1000), .awake);
    }
}

/// How long a manifest Steam refused waits before it is asked for again, and how long
/// any other failure does. Steam logs in afresh for every attempt, so this is also
/// what keeps a refused branch from turning into a login every few seconds.
const denied_backoff: i64 = 15 * 60;
const failed_backoff: i64 = 5 * 60;

const Capture = struct {
    gpa: std.mem.Allocator,
    store: *tact.Store,
    login: tact.steam.Login,
    flags: Flags,
    login_hint: []const u8,
    /// Depots seen through - listed and captured - keyed by app, branch, depot,
    /// manifest and mode. Once a depot is in here a pass costs it no request at all;
    /// the bucket is only asked the first time.
    done: std.StringHashMapUnmanaged(void) = .empty,
    /// Not before this time, by the same key: a denial or a failure.
    held: std.StringHashMapUnmanaged(Hold) = .empty,
    /// Failures already reported, so a stuck depot says so once.
    reported: std.StringHashMapUnmanaged(void) = .empty,
    /// What the last login failure said, for the alert.
    login_reason: []const u8 = "",
    failures: usize = 0,
    /// DepotDownloader runs left for this app this pass; null is unlimited.
    budget: ?usize = null,

    const Hold = struct { until: i64, denied: bool, reason: []const u8 };

    const Status = union(enum) {
        unchanged,
        /// Work to do, but not this pass: out of budget.
        queued,
        captured: struct {
            bytes: u64,
            /// Refused before, served now: the thing all of this waits for.
            jackpot: bool = false,
        },
        /// Refused for the first time: worth one alert.
        denied_new: []const u8,
        /// Refused again, or not asked because it was refused recently.
        denied,
        failed,
    };

    fn deinit(self: *Capture) void {
        self.gpa.free(self.login_reason);
        freeKeys(self.gpa, &self.done);
        var it = self.held.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.reason);
        }
        self.held.deinit(self.gpa);
        freeKeys(self.gpa, &self.reported);
    }

    fn freeKeys(gpa: std.mem.Allocator, map: *std.StringHashMapUnmanaged(void)) void {
        var it = map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        map.deinit(gpa);
    }

    fn remember(self: *Capture, key: []const u8) !void {
        self.release(key);
        if (self.done.contains(key)) return;
        try self.done.put(self.gpa, try self.gpa.dupe(u8, key), {});
    }

    fn hold(self: *Capture, key: []const u8, until: i64, denied: bool, reason: []const u8) !void {
        const r = try self.gpa.dupe(u8, reason);
        if (self.held.getPtr(key)) |h| {
            self.gpa.free(h.reason);
            h.* = .{ .until = until, .denied = denied, .reason = r };
            return;
        }
        try self.held.put(self.gpa, try self.gpa.dupe(u8, key), .{ .until = until, .denied = denied, .reason = r });
    }

    fn release(self: *Capture, key: []const u8) void {
        if (self.held.fetchRemove(key)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value.reason);
        }
    }

    /// Take `runs` DepotDownloader runs from the budget, or none if it cannot cover
    /// the first. A listing and its capture belong together, so a depot needing both
    /// gets both once it gets anything.
    fn spend(self: *Capture, runs: usize) bool {
        const left = self.budget orelse return true;
        if (left == 0) return false;
        self.budget = left -| runs;
        return true;
    }

    fn captureApp(self: *Capture, a: std.mem.Allocator, spec: tact.steam.AppSpec) !void {
        const app = try tact.steam.fetchApp(a, io_, spec.id, "public");
        const only = spec.branch orelse self.flags.branch;

        // `public` first: a depot another branch shares with it is then already
        // captured under public's name, and the other branch only has to point at it.
        const branches = try a.dupe(tact.steam.Branch, app.branches);
        std.mem.sort(tact.steam.Branch, branches, {}, struct {
            fn lt(_: void, x: tact.steam.Branch, y: tact.steam.Branch) bool {
                const xp = std.mem.eql(u8, x.name, "public");
                const yp = std.mem.eql(u8, y.name, "public");
                if (xp != yp) return xp;
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);

        for (branches) |b| {
            if (only) |o| if (!std.mem.eql(u8, o, b.name)) continue;
            const have_password = self.login.branch_password.len != 0 and
                self.flags.branch != null and std.mem.eql(u8, self.flags.branch.?, b.name);
            if (b.password_required and !have_password) {
                note("[capture] {s} {s:<8} build {s}: password protected, skipped\n", .{ app.appid, b.name, b.build_id });
                continue;
            }
            try self.captureBranch(a, app, b);
        }
    }

    fn captureBranch(self: *Capture, a: std.mem.Allocator, app: tact.steam.App, br: tact.steam.Branch) !void {
        var captured: usize = 0;
        var bytes: u64 = 0;
        var denied = std.array_list.Managed([]const u8).init(a);
        var jackpots = std.array_list.Managed([]const u8).init(a);
        var reason: []const u8 = "";
        // One refused retry per branch per pass stands for the rest: Steam refuses a
        // branch, not a depot, and each attempt is a full login.
        var branch_refused = false;

        for (app.depots) |d| {
            const m = d.on(br.name) orelse continue;
            if (self.flags.depot) |only| if (!std.mem.eql(u8, only, d.id)) continue;
            const public_gid = if (d.on("public")) |p| p.gid else "";
            const st = try self.captureDepot(a, app.appid, br, d.id, m, public_gid, &branch_refused);
            switch (st) {
                .captured => |c| {
                    captured += 1;
                    bytes += c.bytes;
                    if (c.jackpot) try jackpots.append(d.id);
                },
                .denied_new => |why| {
                    try denied.append(d.id);
                    reason = why;
                },
                .failed => self.failures += 1,
                .unchanged, .denied, .queued => {},
            }
        }

        if (jackpots.items.len != 0) try alert(a, self.flags.webhook, try std.fmt.allocPrint(a, "@@@ STEAM {s} ({s}) {s} build {s}: {d} depots REFUSED BEFORE, NOW DOWNLOADED: {s} - steam/{s}/{s}/{s}/ @@@", .{
            app.appid,                                  app.name,  br.name, br.build_id, jackpots.items.len,
            try std.mem.join(a, " ", jackpots.items), app.appid, br.name, br.build_id,
        }));
        if (captured != 0) try alert(a, self.flags.webhook, try std.fmt.allocPrint(a, "STEAM {s} ({s}) {s} build {s}: {d} depots captured, {d:.1} MB", .{
            app.appid, app.name, br.name, br.build_id, captured, mb(bytes),
        }));
        if (denied.items.len != 0) try alert(a, self.flags.webhook, try std.fmt.allocPrint(a, "STEAM {s} ({s}) {s} build {s}: {d} depots refused ({s}): {s}. Retried every {d} min; silent unless one gets through.", .{
            app.appid,             app.name, br.name, br.build_id, denied.items.len, reason,
            try std.mem.join(a, " ", denied.items), @divTrunc(denied_backoff, 60),
        }));
    }

    fn line(appid: []const u8, br: tact.steam.Branch, depot: []const u8, gid: []const u8, comptime fmt: []const u8, args: anytype) void {
        note("[capture] {s} {s:<8} {s:<8} {s:<20} " ++ fmt ++ "\n", .{ appid, br.name, depot, gid } ++ args);
    }

    /// One depot at one manifest on one branch: its listing, then its capture, each
    /// done once. Logs exactly one line.
    fn captureDepot(
        self: *Capture,
        a: std.mem.Allocator,
        appid: []const u8,
        br: tact.steam.Branch,
        depot: []const u8,
        m: tact.steam.Manifest,
        public_gid: []const u8,
        branch_refused: *bool,
    ) !Status {
        const store = self.store;
        const gid = m.gid;
        const mode = tact.steam.Mode.choose(m.size, self.flags.whole_under, self.flags.files);
        var tag_buf: [16]u8 = undefined;
        const mode_tag = mode.tag(&tag_buf);
        const key = try std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}/{s}", .{ appid, br.name, depot, gid, mode_tag });
        const now = nowSecs();

        if (self.done.contains(key)) {
            line(appid, br, depot, gid, "unchanged", .{});
            return .unchanged;
        }
        if (self.held.get(key)) |h| if (now < h.until) {
            if (h.denied) {
                line(appid, br, depot, gid, "denied ({s}), retry in {d}s", .{ h.reason, h.until - now });
                return .denied;
            }
            line(appid, br, depot, gid, "failed ({s}), retry in {d}s", .{ h.reason, h.until - now });
            return .failed;
        };

        // Out of runs: do not even ask the bucket what is missing.
        if (self.budget) |left| if (left == 0) {
            line(appid, br, depot, gid, "queued (another app has this pass)", .{});
            return .queued;
        };

        const listing_key = try std.fmt.allocPrint(a, "steam/{s}/listings/{s}/{s}.txt", .{ appid, depot, gid });
        var listed = (try store.objectSize(a, listing_key)) != null;
        const marker_key = try std.fmt.allocPrint(a, "steam/{s}/state/captured-{s}-{s}-{s}", .{ appid, br.name, br.build_id, depot });
        const want = try tact.steam.markerValue(a, gid, mode);
        var captured = std.mem.eql(u8, try store.readText(a, marker_key), want);

        // The same manifest on another branch is the same bytes, already stored under
        // that branch's name - point at it instead of downloading it again.
        const shared_key = try std.fmt.allocPrint(a, "steam/{s}/state/manifest-{s}-{s}", .{ appid, depot, gid });
        var same_as: []const u8 = "";
        if (!captured) {
            const where = try store.readText(a, shared_key);
            if (where.len > mode_tag.len and std.mem.startsWith(u8, where, mode_tag) and where[mode_tag.len] == ' ') {
                same_as = where[mode_tag.len + 1 ..];
                try store.writeObject(a, marker_key, want);
                captured = true;
            }
        }
        if (listed and captured) {
            try self.remember(key);
            if (same_as.len != 0)
                line(appid, br, depot, gid, "unchanged (same manifest as {s})", .{same_as})
            else
                line(appid, br, depot, gid, "unchanged", .{});
            return .unchanged;
        }

        const denied_key = try std.fmt.allocPrint(a, "steam/{s}/state/denied-{s}-{s}-{s}", .{ appid, br.name, br.build_id, depot });
        const retry = tact.steam.retryDenied(try store.readText(a, denied_key), gid, now, denied_backoff);
        switch (retry) {
            .wait => |s| {
                try self.hold(key, now + s, true, "refused earlier");
                line(appid, br, depot, gid, "denied (refused earlier), retry in {d}s", .{s});
                return .denied;
            },
            .again => if (branch_refused.*) {
                try store.writeObject(a, denied_key, try std.fmt.allocPrint(a, "{s} {d}", .{ gid, now }));
                try self.hold(key, now + denied_backoff, true, "branch still refused");
                line(appid, br, depot, gid, "denied (branch still refused), retry in {d}s", .{denied_backoff});
                return .denied;
            },
            .fresh, .lifted => {},
        }

        if (!self.spend(if (listed) 1 else 2)) {
            line(appid, br, depot, gid, "queued (another app has this pass)", .{});
            return .queued;
        }

        if (!listed) {
            const run = try self.list(a, appid, br, depot, gid, public_gid);
            switch (run.outcome.kind) {
                .ok => listed = true,
                .denied => return self.refused(a, key, denied_key, appid, br, depot, gid, retry, run.outcome.reason, branch_refused),
                .login => return self.loginRefused(run.outcome.reason),
                .failed => return self.failed(a, key, appid, br, depot, gid, "listing", run),
            }
        }

        var got: u64 = 0;
        if (!captured) {
            const dir = try std.fmt.allocPrint(a, "{s}/{s}-{s}", .{ self.flags.scratch, appid, depot });
            const run = try tact.steam.downloadDepot(a, io_, self.login, appid, .{
                .depot = depot,
                .manifest = gid,
                .branch = br.name,
                .files = switch (mode) {
                    .whole => null,
                    .files => |pat| pat,
                },
            }, dir);
            switch (run.outcome.kind) {
                .ok => {},
                .denied => {
                    std.Io.Dir.cwd().deleteTree(io_, dir) catch {};
                    return self.refused(a, key, denied_key, appid, br, depot, gid, retry, run.outcome.reason, branch_refused);
                },
                .login => return self.loginRefused(run.outcome.reason),
                .failed => return self.failed(a, key, appid, br, depot, gid, "download", run),
            }
            const prefix = try std.fmt.allocPrint(a, "steam/{s}/{s}/{s}/{s}", .{ appid, br.name, br.build_id, depot });
            got = uploadTree(a, store, dir, prefix) catch |err| {
                const why = try std.fmt.allocPrint(a, "upload: {s}", .{@errorName(err)});
                return self.failed(a, key, appid, br, depot, gid, "upload", .{ .outcome = .{ .kind = .failed, .reason = why }, .output = "" });
            };
            // Only once the bytes are safely in the store: the scratch copy is the
            // only other copy until then.
            std.Io.Dir.cwd().deleteTree(io_, dir) catch |err| note("[capture] {s}: scratch not removed: {s}\n", .{ dir, @errorName(err) });
            try store.writeObject(a, marker_key, want);
            try store.writeObject(a, shared_key, try std.fmt.allocPrint(a, "{s} {s}/{s}", .{ mode_tag, br.name, br.build_id }));
        }

        // Refused before and served now; the branch summary says so, loudly.
        const jackpot = retry == .again;
        if (jackpot) try store.writeObject(a, denied_key, try std.fmt.allocPrint(a, "{s} {d} lifted", .{ gid, now }));
        try self.remember(key);
        if (captured)
            line(appid, br, depot, gid, "listed", .{})
        else
            line(appid, br, depot, gid, "captured {s} {d:.1} MB", .{ mode_tag, mb(got) });
        if (captured and !jackpot) return .unchanged;
        return .{ .captured = .{ .bytes = got, .jackpot = jackpot } };
    }

    /// Fetch the manifest's file listing and keep it, then hold it up against the
    /// depot's previous one. Every manifest gets one, including the big data depots
    /// that are only captured filtered: the listing is what shows a file the filter
    /// would never have asked for.
    fn list(self: *Capture, a: std.mem.Allocator, appid: []const u8, br: tact.steam.Branch, depot: []const u8, gid: []const u8, public_gid: []const u8) !tact.steam.Run {
        const dir = try std.fmt.allocPrint(a, "{s}/{s}-{s}-listing", .{ self.flags.scratch, appid, depot });
        defer std.Io.Dir.cwd().deleteTree(io_, dir) catch {};
        var run = try tact.steam.downloadDepot(a, io_, self.login, appid, .{
            .depot = depot,
            .manifest = gid,
            .branch = br.name,
            .manifest_only = true,
        }, dir);
        if (run.outcome.kind != .ok) return run;

        const path = try tact.steam.listingPath(a, dir, depot, gid);
        const text = std.Io.Dir.cwd().readFileAlloc(io_, path, a, .limited(512 << 20)) catch |err| {
            run.outcome = .{ .kind = .failed, .reason = @errorName(err) };
            return run;
        };
        const store = self.store;
        const listing_key = try std.fmt.allocPrint(a, "steam/{s}/listings/{s}/{s}", .{ appid, depot, gid });
        try store.writeObject(a, try std.fmt.allocPrint(a, "{s}.txt", .{listing_key}), text);
        const files = try tact.steam.parseListing(a, text);

        // What to hold it up against: this branch's previous manifest of the depot,
        // and - for any other branch - what public is serving, since a build that is
        // not public yet is interesting precisely for how it differs from retail.
        const Ref = struct { label: []const u8, gid: []const u8, files: []const tact.steam.ListedFile };
        var refs = std.array_list.Managed(Ref).init(a);
        const last_key = try std.fmt.allocPrint(a, "steam/{s}/state/listed-{s}-{s}", .{ appid, br.name, depot });
        const prev_gid = try store.readText(a, last_key);
        const candidates = [_]struct { label: []const u8, gid: []const u8 }{
            .{ .label = br.name, .gid = prev_gid },
            .{ .label = "public", .gid = if (std.mem.eql(u8, br.name, "public")) "" else public_gid },
        };
        for (candidates) |c| {
            if (c.gid.len == 0 or std.mem.eql(u8, c.gid, gid)) continue;
            if (refs.items.len != 0 and std.mem.eql(u8, refs.items[0].gid, c.gid)) continue;
            const pkey = try std.fmt.allocPrint(a, "steam/{s}/listings/{s}/{s}.txt", .{ appid, depot, c.gid });
            const ptext = (try store.readObject(a, pkey, null)) orelse continue;
            try refs.append(.{ .label = c.label, .gid = c.gid, .files = try tact.steam.parseListing(a, ptext) });
        }

        // Loud: what a debug build looks like.
        var loud = std.Io.Writer.Allocating.init(a);
        var n_loud: usize = 0;
        {
            const first = try tact.steam.anomalies(a, if (refs.items.len != 0) refs.items[0].files else null, files);
            for (first) |f| if (f == .pdb) {
                try loud.writer.print("\n  symbols: {s}", .{f.pdb});
                n_loud += 1;
            };
        }
        for (refs.items) |r| {
            for (try tact.steam.anomalies(a, r.files, files)) |f| {
                switch (f) {
                    .pdb => continue,
                    .new_exe => |n| try loud.writer.print("\n  new executable vs {s}: {s}", .{ r.label, n }),
                    .gone_exe => |n| try loud.writer.print("\n  executable gone vs {s}: {s}", .{ r.label, n }),
                    .grew => |g| try loud.writer.print("\n  {s} {d:.1} MB -> {d:.1} MB vs {s}", .{ g.name, mb(g.was), mb(g.now), r.label }),
                }
                n_loud += 1;
            }
        }
        if (n_loud != 0) try alert(a, self.flags.webhook, try std.fmt.allocPrint(a, "@@@ STEAM {s} {s} build {s} depot {s} manifest {s} LOOKS UNUSUAL:{s}\nlisting: {s}.txt @@@", .{
            appid, br.name, br.build_id, depot, gid, loud.written(), listing_key,
        }));

        // Quiet: every size change worth a look, one message per manifest, and the
        // whole diff kept beside the listing.
        if (refs.items.len != 0) {
            var full = std.Io.Writer.Allocating.init(a);
            var hint = std.Io.Writer.Allocating.init(a);
            var n_hint: usize = 0;
            for (refs.items) |r| {
                const changes = try tact.steam.diffListings(a, r.files, files);
                try full.writer.print("# {s} depot {s}: manifest {s} ({s}) against {s} ({s}): {d} changes\n", .{ appid, depot, gid, br.name, r.gid, r.label, changes.len });
                for (changes) |c| {
                    try writeChange(&full.writer, c);
                    try full.writer.writeAll("\n");
                }
                if (changes.len == 0) continue;
                try hint.writer.print("\nvs {s} {s}: {d} changed", .{ r.label, r.gid, changes.len });
                const shown = @min(changes.len, 10);
                for (changes[0..shown]) |c| {
                    try hint.writer.writeAll("\n ");
                    try writeChange(&hint.writer, c);
                }
                if (changes.len > shown) try hint.writer.print("\n  (+{d} more)", .{changes.len - shown});
                n_hint += changes.len;
            }
            try store.writeObject(a, try std.fmt.allocPrint(a, "{s}.diff.txt", .{listing_key}), full.written());
            if (n_hint != 0) try alert(a, self.flags.webhook, try std.fmt.allocPrint(a, "STEAM {s} {s} build {s} depot {s} manifest {s}: files changed{s}\ndiff: {s}.diff.txt", .{
                appid, br.name, br.build_id, depot, gid, hint.written(), listing_key,
            }));
        }
        try store.writeObject(a, last_key, gid);
        return run;
    }

    fn refused(
        self: *Capture,
        a: std.mem.Allocator,
        key: []const u8,
        denied_key: []const u8,
        appid: []const u8,
        br: tact.steam.Branch,
        depot: []const u8,
        gid: []const u8,
        retry: tact.steam.Retry,
        reason: []const u8,
        branch_refused: *bool,
    ) !Status {
        const now = nowSecs();
        try self.store.writeObject(a, denied_key, try std.fmt.allocPrint(a, "{s} {d}", .{ gid, now }));
        try self.hold(key, now + denied_backoff, true, reason);
        if (retry == .again) branch_refused.* = true;
        line(appid, br, depot, gid, "denied ({s}), retry in {d}s", .{ reason, denied_backoff });
        return if (retry == .again) .denied else .{ .denied_new = reason };
    }

    fn failed(
        self: *Capture,
        a: std.mem.Allocator,
        key: []const u8,
        appid: []const u8,
        br: tact.steam.Branch,
        depot: []const u8,
        gid: []const u8,
        what: []const u8,
        run: tact.steam.Run,
    ) !Status {
        const now = nowSecs();
        try self.hold(key, now + failed_backoff, false, run.outcome.reason);
        line(appid, br, depot, gid, "{s} failed ({s}), retry in {d}s", .{ what, run.outcome.reason, failed_backoff });
        if (!self.reported.contains(key)) {
            try self.reported.put(self.gpa, try self.gpa.dupe(u8, key), {});
            // What DepotDownloader said, once, for whoever has to work out why.
            var tail = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, run.output, " \r\n"), '\n');
            var lines: [12][]const u8 = undefined;
            var n: usize = 0;
            while (tail.next()) |l| {
                if (n == lines.len) break;
                lines[n] = l;
                n += 1;
            }
            while (n > 0) : (n -= 1) note("    | {s}\n", .{lines[n - 1]});
            try alert(a, self.flags.webhook, try std.fmt.allocPrint(a, "STEAM {s} {s} build {s} depot {s} manifest {s}: {s} FAILED ({s}), retrying every {d} min", .{
                appid, br.name, br.build_id, depot, gid, what, run.outcome.reason, @divTrunc(failed_backoff, 60),
            }));
        }
        return .failed;
    }

    fn loginRefused(self: *Capture, reason: []const u8) anyerror {
        self.gpa.free(self.login_reason);
        self.login_reason = self.gpa.dupe(u8, reason) catch "";
        return error.SteamLogin;
    }

    /// The stored token was refused. Nothing unattended fixes that, so say how to -
    /// but at most once an hour, and remembered in the store so a restart does not
    /// say it again.
    fn loginFailed(self: *Capture, a: std.mem.Allocator) !void {
        note("[capture] Steam login failed ({s}); needs an interactive login\n", .{self.login_reason});
        const key = "steam/state/login-alert";
        const last = std.fmt.parseInt(i64, try self.store.readText(a, key), 10) catch 0;
        const now = nowSecs();
        if (now - last < 3600) return;
        try alert(a, self.flags.webhook, try std.fmt.allocPrint(a, "@@@ STEAM LOGIN NEEDED - captures are stopped: DepotDownloader said \"{s}\". To fix: {s} @@@", .{ self.login_reason, self.login_hint }));
        try self.store.writeObject(a, key, try std.fmt.allocPrint(a, "{d}", .{now}));
    }
};

/// An explicit manifest is a build PICS no longer lists - the only way to reach one of
/// Steam's older builds, since the record only ever names what is current. It is
/// stored under the manifest id, because that is the only name it has.
fn captureManifest(arena: std.mem.Allocator, store: *tact.Store, login: tact.steam.Login, flags: Flags, gid: []const u8) !void {
    const depot = flags.depot orelse fail("--manifest needs --depot", .{});
    const branch = flags.branch orelse "public";
    var apps = std.mem.tokenizeAny(u8, flags.app, " ,");
    const appid = apps.next() orelse fail("--manifest needs one --app", .{});
    const label = try std.fmt.allocPrint(arena, "manifest-{s}", .{gid});
    const mode: tact.steam.Mode = if (flags.files) |pat| .{ .files = pat } else .whole;

    const marker = try std.fmt.allocPrint(arena, "steam/{s}/state/captured-{s}-{s}-{s}", .{ appid, branch, label, depot });
    const want = try tact.steam.markerValue(arena, gid, mode);
    if (std.mem.eql(u8, try store.readText(arena, marker), want)) {
        note("[capture] depot {s} manifest {s}: already captured\n", .{ depot, gid });
        return;
    }

    const dir = try std.fmt.allocPrint(arena, "{s}/{s}-{s}", .{ flags.scratch, appid, depot });
    note("[capture] depot {s} manifest {s} -> {s}/{s}\n", .{ depot, gid, label, depot });
    const run = try tact.steam.downloadDepot(arena, io_, login, appid, .{
        .depot = depot,
        .manifest = gid,
        .branch = branch,
        .files = flags.files,
    }, dir);
    if (run.outcome.kind != .ok) {
        std.debug.print("{s}", .{run.output});
        note("[capture] depot {s}: {s} ({s})\n", .{ depot, @tagName(run.outcome.kind), run.outcome.reason });
        try alert(arena, flags.webhook, try std.fmt.allocPrint(arena, "STEAM {s} depot {s} ({s}) DOWNLOAD FAILED ({s})", .{ appid, depot, label, run.outcome.reason }));
        return error.DepotDownloadFailed;
    }

    const prefix = try std.fmt.allocPrint(arena, "steam/{s}/{s}/{s}/{s}", .{ appid, branch, label, depot });
    const n = try uploadTree(arena, store, dir, prefix);
    std.Io.Dir.cwd().deleteTree(io_, dir) catch |err| note("[capture] depot {s}: scratch not removed: {s}\n", .{ depot, @errorName(err) });
    try store.writeObject(arena, marker, want);
    note("[capture] depot {s}: {d:.1} MB stored under {s}\n", .{ depot, mb(n), label });
}

/// `  name  12.3 MB -> 14.0 MB`, with "absent" for a side that has no such file.
fn writeChange(w: *std.Io.Writer, c: tact.steam.Change) !void {
    try w.print(" {s}  ", .{c.name});
    if (c.was) |v| try w.print("{d:.2} MB", .{mb(v)}) else try w.writeAll("absent");
    try w.writeAll(" -> ");
    if (c.now) |v| try w.print("{d:.2} MB", .{mb(v)}) else try w.writeAll("absent");
}

/// Copy every file under `dir` into the store beneath `prefix`, keeping the tree.
fn uploadTree(a: std.mem.Allocator, store: *tact.Store, dir: []const u8, prefix: []const u8) !u64 {
    var d = try std.Io.Dir.cwd().openDir(io_, dir, .{ .iterate = true });
    defer d.close(io_);
    var it = try d.walk(a);
    defer it.deinit();

    var total: u64 = 0;
    var files: usize = 0;
    while (try it.next(io_)) |e| {
        if (e.kind != .file) continue;
        // DepotDownloader's own bookkeeping and our file list, not game content.
        if (std.mem.startsWith(u8, e.path, ".DepotDownloader")) continue;
        if (std.mem.eql(u8, e.path, ".filelist.txt")) continue;

        const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.path });
        defer a.free(key);
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, e.path });
        defer a.free(path);
        total += try store.putFile(a, key, path);
        files += 1;
        if (files % 200 == 0) note("  {d} files, {d:.1} GB\n", .{ files, gb(total) });
    }
    return total;
}

/// An absent state object is "never seen"; an unreadable one is an error, because
/// treating a failed read as "never seen" would alert about a build that is already
/// recorded - and keep doing it every pass.
fn readState(a: std.mem.Allocator, root: *tact.Store, product: []const u8, suffix: []const u8) ![]const u8 {
    const key = try std.fmt.allocPrint(a, "state/{s}{s}", .{ product, suffix });
    return root.readText(a, key);
}

fn writeState(a: std.mem.Allocator, root: *tact.Store, product: []const u8, suffix: []const u8, value: []const u8) !void {
    const key = try std.fmt.allocPrint(a, "state/{s}{s}", .{ product, suffix });
    try root.writeObject(a, key, value);
}

fn alert(gpa: std.mem.Allocator, webhook: ?[]const u8, full: []const u8) !void {
    std.debug.print(">> {s}\n", .{full});
    // Discord refuses a message over 2000 characters outright; a cut one still says
    // what happened, and the log above has all of it.
    var cut: usize = @min(full.len, 1900);
    while (cut < full.len and cut > 0 and full[cut] & 0xC0 == 0x80) cut -= 1; // not mid-character
    const msg = if (cut < full.len) try std.fmt.allocPrint(gpa, "{s}\n(cut; the log has the rest)", .{full[0..cut]}) else full;
    const url = webhook orelse return;
    if (url.len == 0) return;
    var client: std.http.Client = .{ .allocator = gpa, .io = io_ };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    try body.writer.writeAll("{\"content\":\"");
    try std.json.Stringify.encodeJsonStringChars(msg, .{}, &body.writer);
    try body.writer.writeAll("\"}");
    const status = post(&client, url, body.written()) catch |err| {
        std.debug.print("   (webhook failed: {s})\n", .{@errorName(err)});
        return;
    };
    if (@intFromEnum(status) / 100 != 2) std.debug.print("   (webhook answered {d})\n", .{@intFromEnum(status)});
}

/// POST and read only the status. Discord answers a webhook with 204 and no length,
/// and `Client.fetch` then waits for a body until the server gives up on the
/// connection - minutes, with the whole loop stalled behind it.
fn post(client: *std.http.Client, url: []const u8, payload: []const u8) !std.http.Status {
    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .keep_alive = false,
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = payload.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(payload);
    try bw.end();
    try req.connection.?.flush();
    const res = try req.receiveHead(&.{});
    return res.head.status;
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

fn gb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
}

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
