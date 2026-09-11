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
    \\  steam    --app <id,..>   Steam appids (default 2536520, D2R Infernal Edition)
    \\           --branch <name> which branch's manifest ids to report (default public)
    \\           --interval <s>  loop every s seconds
    \\           --stagger <n>   one of n replicas: offset the first pass by my slot
    \\  steam-capture            download a build's depots (needs a Steam account)
    \\           --files <re,..> only files matching these regexes, e.g. '.*\.(exe|dll)$'
    \\           --scratch <dir> where a depot is staged before upload (default ./steam-scratch)
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
    \\  d2r-cdn steam-capture s3://bucket/d2r --files '.*\.(exe|dll)$'
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
        const dest = tact.Store.open(arena, io_, spec, opts.s3) catch |err| fail("pool {s}: {s}", .{ spec, @errorName(err) });
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
    branch: []const u8 = "public",
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
    const root = tact.Store.open(arena, io_, spec, base_opts.s3) catch |err| fail("{s}: {s}", .{ spec, @errorName(err) });
    defer root.close();
    const pool_spec = try std.fmt.allocPrint(arena, "{s}/pool", .{std.mem.trimEnd(u8, spec, "/")});
    const pool = tact.Store.open(arena, io_, pool_spec, base_opts.s3) catch |err| fail("{s}: {s}", .{ pool_spec, @errorName(err) });
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

// ---- steam ---------------------------------------------------------------------

fn steamWatch(gpa: std.mem.Allocator, arena: std.mem.Allocator, base_opts: tact.Options, spec: ?[]const u8, flags: Flags) !void {
    // No destination: just report what Steam is serving right now.
    const root: ?*tact.Store = if (spec) |sp|
        tact.Store.open(arena, io_, sp, base_opts.s3) catch |err| fail("{s}: {s}", .{ sp, @errorName(err) })
    else
        null;
    defer if (root) |r| r.close();

    // Several replicas watching the same thing should spread themselves across the
    // interval rather than all polling at once: the point of running them on separate
    // hosts is separate egress, which is wasted if they fire together. The slot comes
    // from the pod's own ordinal, so nothing has to be configured per replica.
    if (flags.stagger > 1 and flags.interval != 0) {
        const slot = ordinal() % flags.stagger;
        const offset = @as(u64, flags.interval) * slot / flags.stagger;
        if (offset != 0) {
            note("[steam] replica {d}/{d}: first pass in {d}s\n", .{ slot, flags.stagger, offset });
            try io_.sleep(.fromMilliseconds(@as(i64, @intCast(offset)) * 1000), .awake);
        }
    }

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    while (true) {
        var it = std.mem.tokenizeAny(u8, flags.app, " ,");
        while (it.next()) |appid| {
            steamPass(pass_arena.allocator(), root, flags, appid) catch |err|
                note("[steam] {s}: {s}\n", .{ appid, @errorName(err) });
        }
        if (flags.interval == 0) return;
        _ = pass_arena.reset(.retain_capacity);
        try io_.sleep(.fromMilliseconds(@as(i64, flags.interval) * 1000), .awake);
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
    const app = try tact.steam.fetchApp(a, io_, appid, flags.branch);

    note("[steam] {s} ({s}) - {d} branches, {d} depots, {d:.1} GB on {s}{s}\n", .{
        app.name,               app.appid, app.branches.len, app.depots.len,
        gb(app.totalSize()), flags.branch, if (app.private_branches) ", has private branches" else "",
    });
    for (app.branches) |b| note("  {s:<16} build {s:<10}{s}{s} {s}\n", .{
        b.name,                                 b.build_id,
        if (b.password_required) " [pwd]" else "", if (b.lcs_required) " [lcs]" else "",
        b.description,
    });

    const store = root orelse return;
    const digest = try tact.steam.branchDigest(a, app);
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
    try store.writeObject(a, pb_key, pb_now);
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

/// An absent state object is "never seen"; an unreadable one is an error, because
/// treating a failed read as "never seen" would alert about a build that is already
/// recorded - and keep doing it every pass.
/// Capture a Steam build: every depot of a branch, downloaded one at a time and
/// uploaded as it completes, so the scratch disk only ever holds one depot.
///
/// Depot bytes need an account that owns the app - Steam issues depot keys only after
/// an ownership check - so unlike the rest of this tool, this half cannot run
/// anonymously. The login token lives in DepotDownloader's isolated storage under
/// $HOME, so an unattended run needs a persistent HOME and one interactive login
/// first to satisfy Steam Guard.
fn steamCapture(gpa: std.mem.Allocator, arena: std.mem.Allocator, base_opts: tact.Options, dest: []const u8, flags: Flags, env: *const std.process.Environ.Map) !void {
    const store = tact.Store.open(arena, io_, dest, base_opts.s3) catch |err| fail("{s}: {s}", .{ dest, @errorName(err) });
    defer store.close();

    const login: tact.steam.Login = .{
        .exe = env.get("DEPOTDOWNLOADER") orelse "DepotDownloader",
        .username = env.get("STEAM_USERNAME") orelse "",
        .password = env.get("STEAM_PASSWORD") orelse "",
        .branch_password = flags.branch_password,
    };

    var bad: usize = 0;
    var apps = std.mem.tokenizeAny(u8, flags.app, " ,");
    while (apps.next()) |appid| {
        captureApp(gpa, arena, store, login, appid, flags) catch |err| {
            note("[capture] {s}: {s}\n", .{ appid, @errorName(err) });
            bad += 1;
        };
    }
    if (bad != 0) return error.CaptureIncomplete;
}

fn captureApp(gpa: std.mem.Allocator, arena: std.mem.Allocator, store: *tact.Store, login: tact.steam.Login, appid: []const u8, flags: Flags) !void {
    // An explicit manifest is a build PICS no longer lists - the only way to reach
    // one of Steam's older builds, since the record only ever names what is current.
    // It is stored under the manifest id, because that is the only name it has.
    if (flags.manifest) |gid| {
        const depot = flags.depot orelse fail("--manifest needs --depot", .{});
        const label = try std.fmt.allocPrint(arena, "manifest-{s}", .{gid});
        return captureDepot(gpa, arena, store, login, appid, flags, .{
            .depot = depot,
            .manifest = gid,
            .branch = flags.branch,
            .files = flags.files,
        }, label, 0);
    }

    const app = try tact.steam.fetchApp(arena, io_, appid, flags.branch);
    const br = app.branch(flags.branch) orelse return error.NoSuchBranch;
    note("[capture] {s} branch {s} build {s}: {d} depots, {d:.1} GB{s}\n", .{
        app.name, br.name, br.build_id, app.depots.len, gb(app.totalSize()),
        if (flags.files != null) " (filtered)" else "",
    });

    var done: usize = 0;
    var failed: usize = 0;
    for (app.depots) |d| {
        if (d.manifest.len == 0) continue; // no content on this branch
        if (flags.depot) |only| if (!std.mem.eql(u8, only, d.id)) continue;
        captureDepot(gpa, arena, store, login, app.appid, flags, .{
            .depot = d.id,
            .manifest = d.manifest,
            .branch = br.name,
            .files = flags.files,
        }, br.build_id, d.size) catch {
            failed += 1;
            continue;
        };
        done += 1;
    }

    if (done != 0 or failed != 0) {
        try alert(arena, flags.webhook, try std.fmt.allocPrint(arena, "STEAM {s} ({s}) build {s}: {d} depots captured, {d} failed", .{
            app.appid, app.name, br.build_id, done, failed,
        }));
    }
    if (failed != 0) return error.CaptureIncomplete;
}

/// Download one depot at one manifest and put it in the store under
/// `steam/<app>/<branch>/<label>/<depot>/`. `label` is the build id for a current
/// build, or `manifest-<gid>` for an older one PICS no longer names.
///
/// The marker holds the manifest id, so a depot republished under the same label is
/// captured again rather than skipped, and a half-finished run resumes at the depot
/// it stopped on.
fn captureDepot(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    store: *tact.Store,
    login: tact.steam.Login,
    appid: []const u8,
    flags: Flags,
    job: tact.steam.DepotJob,
    label: []const u8,
    declared: u64,
) !void {
    var pass = std.heap.ArenaAllocator.init(gpa);
    defer pass.deinit();
    const a = pass.allocator();
    _ = arena;

    const marker = try std.fmt.allocPrint(a, "steam/{s}/state/captured-{s}-{s}-{s}", .{ appid, job.branch, label, job.depot });
    if (std.mem.eql(u8, try store.readText(a, marker), job.manifest)) return;

    const dir = try std.fmt.allocPrint(a, "{s}/{s}-{s}", .{ flags.scratch, appid, job.depot });
    note("[capture] depot {s} manifest {s}", .{ job.depot, job.manifest });
    if (declared != 0) note(" ({d:.1} GB declared)", .{gb(declared)});
    note(" -> {s}/{s}\n", .{ label, job.depot });

    tact.steam.downloadDepot(a, io_, login, appid, job, dir) catch |err| {
        note("[capture] depot {s}: {s}\n", .{ job.depot, @errorName(err) });
        try alert(a, flags.webhook, try std.fmt.allocPrint(a, "STEAM {s} depot {s} ({s}) DOWNLOAD FAILED ({s})", .{ appid, job.depot, label, @errorName(err) }));
        return err;
    };

    const prefix = try std.fmt.allocPrint(a, "steam/{s}/{s}/{s}/{s}", .{ appid, job.branch, label, job.depot });
    const n = uploadTree(a, store, dir, prefix) catch |err| {
        note("[capture] depot {s}: upload: {s}\n", .{ job.depot, @errorName(err) });
        return err;
    };

    // Only once the bytes are safely in the store: the scratch copy is the only other
    // copy until then.
    std.Io.Dir.cwd().deleteTree(io_, dir) catch |err| note("[capture] depot {s}: scratch not removed: {s}\n", .{ job.depot, @errorName(err) });
    try store.writeObject(a, marker, job.manifest);
    note("[capture] depot {s}: {d:.1} MB stored under {s}\n", .{ job.depot, mb(n), label });
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

fn readState(a: std.mem.Allocator, root: *tact.Store, product: []const u8, suffix: []const u8) ![]const u8 {
    const key = try std.fmt.allocPrint(a, "state/{s}{s}", .{ product, suffix });
    return root.readText(a, key);
}

fn writeState(a: std.mem.Allocator, root: *tact.Store, product: []const u8, suffix: []const u8, value: []const u8) !void {
    const key = try std.fmt.allocPrint(a, "state/{s}{s}", .{ product, suffix });
    try root.writeObject(a, key, value);
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
