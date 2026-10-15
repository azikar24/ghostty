//! Details about a terminal shown in the tab sidebar: the git branch of
//! its directory and the TCP ports its processes listen on. Linux only
//! (reads /proc); cheap enough to poll every couple of seconds.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The branch checked out in the repository containing `dir` (or a short
/// commit id when detached), written into `buf`. Null outside a repository.
pub fn gitBranch(buf: []u8, dir: []const u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var current: []const u8 = dir;
    while (true) {
        if (headOf(buf, &path_buf, current)) |branch| return branch;
        current = std.fs.path.dirname(current) orelse return null;
    }
}

/// The branch named by `<dir>/.git`, if `dir` is a repository root. `.git`
/// is a directory, or for worktrees and submodules a file naming it.
fn headOf(buf: []u8, path_buf: []u8, dir: []const u8) ?[]const u8 {
    const git = std.fmt.bufPrint(path_buf, "{s}/.git", .{dir}) catch return null;
    const stat = std.fs.cwd().statFile(git) catch return null;

    var head_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const head_path = switch (stat.kind) {
        .directory => std.fmt.bufPrint(&head_path_buf, "{s}/HEAD", .{git}) catch return null,
        .file => file: {
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const link = std.fs.cwd().readFile(git, &link_buf) catch return null;
            const prefix = "gitdir: ";
            if (!std.mem.startsWith(u8, link, prefix)) return null;
            const target = std.mem.trim(u8, link[prefix.len..], " \r\n");
            break :file if (std.fs.path.isAbsolute(target))
                std.fmt.bufPrint(&head_path_buf, "{s}/HEAD", .{target}) catch return null
            else
                std.fmt.bufPrint(&head_path_buf, "{s}/{s}/HEAD", .{ dir, target }) catch return null;
        },
        else => return null,
    };

    var head_buf: [256]u8 = undefined;
    const head = std.mem.trim(u8, std.fs.cwd().readFile(head_path, &head_buf) catch return null, " \r\n");
    const ref = "ref: refs/heads/";
    const name = if (std.mem.startsWith(u8, head, ref)) head[ref.len..] else head[0..@min(7, head.len)];
    if (name.len == 0 or name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

/// TCP ports in LISTEN state owned by `roots` or any of their descendant
/// processes, sorted and deduplicated, written into `out`. Returns how many.
pub fn listeningPorts(alloc: Allocator, roots: []const std.posix.pid_t, out: []u16) usize {
    if (roots.len == 0) return 0;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const pids = descendants(a, roots) catch return 0;
    var inodes: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (pids) |pid| socketInodes(a, pid, &inodes) catch continue;
    if (inodes.count() == 0) return 0;

    var n: usize = 0;
    for ([_][]const u8{ "/proc/net/tcp", "/proc/net/tcp6" }) |table| {
        n = listenPorts(a, table, &inodes, out, n) catch n;
    }
    std.mem.sort(u16, out[0..n], {}, std.sort.asc(u16));
    var unique: usize = 0;
    for (out[0..n]) |port| {
        if (unique > 0 and out[unique - 1] == port) continue;
        out[unique] = port;
        unique += 1;
    }
    return unique;
}

/// `roots` plus every process descended from them.
fn descendants(a: Allocator, roots: []const std.posix.pid_t) ![]std.posix.pid_t {
    // pid -> parent, for every process.
    var parents: std.ArrayListUnmanaged([2]std.posix.pid_t) = .empty;
    var proc = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer proc.close();
    var it = proc.iterate();
    while (try it.next()) |entry| {
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{d}/stat", .{pid}) catch continue;
        var stat_buf: [512]u8 = undefined;
        const stat = proc.readFile(path, &stat_buf) catch continue;
        // "pid (comm) state ppid ...": comm may contain spaces and ')'.
        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
        _ = fields.next(); // state
        const ppid = std.fmt.parseInt(std.posix.pid_t, fields.next() orelse continue, 10) catch continue;
        try parents.append(a, .{ pid, ppid });
    }

    var result: std.ArrayListUnmanaged(std.posix.pid_t) = .empty;
    try result.appendSlice(a, roots);
    var i: usize = 0;
    while (i < result.items.len) : (i += 1) {
        const parent = result.items[i];
        for (parents.items) |pair| {
            if (pair[1] == parent) try result.append(a, pair[0]);
        }
    }
    return result.items;
}

fn socketInodes(a: Allocator, pid: std.posix.pid_t, inodes: *std.AutoHashMapUnmanaged(u64, void)) !void {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/fd", .{pid});
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        var link_buf: [64]u8 = undefined;
        const link = dir.readLink(entry.name, &link_buf) catch continue;
        const prefix = "socket:[";
        if (!std.mem.startsWith(u8, link, prefix) or link.len < prefix.len + 2) continue;
        const inode = std.fmt.parseInt(u64, link[prefix.len .. link.len - 1], 10) catch continue;
        try inodes.put(a, inode, {});
    }
}

/// Append the ports of LISTEN sockets in a /proc/net/tcp-style table whose
/// inode is in `inodes`. Returns the new count.
fn listenPorts(
    a: Allocator,
    table: []const u8,
    inodes: *const std.AutoHashMapUnmanaged(u64, void),
    out: []u16,
    start: usize,
) !usize {
    const data = try std.fs.cwd().readFileAlloc(a, table, 4 * 1024 * 1024);
    var n = start;
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        // sl local_address rem_address st tx:rx tr:when retrnsmt uid timeout inode
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        const local = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        if (!std.mem.eql(u8, state, "0A")) continue; // TCP_LISTEN
        for (0..5) |_| _ = fields.next();
        const inode = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        if (!inodes.contains(inode)) continue;
        const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
        const port = std.fmt.parseInt(u16, local[colon + 1 ..], 16) catch continue;
        if (n == out.len) return n;
        out[n] = port;
        n += 1;
    }
    return n;
}
