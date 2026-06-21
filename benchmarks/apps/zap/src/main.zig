const std = @import("std");
const zap = @import("zap");

const DEFAULT_PORT: u16 = 9292;

fn sendNotFound(r: zap.Request) void {
    r.setStatus(.not_found);
    r.sendBody("Not Found") catch return;
}

fn onRequest(r: zap.Request) !void {
    const path = r.path orelse "/";

    if (std.mem.eql(u8, path, "/plaintext")) {
        try r.setContentType(.TEXT);
        try r.sendBody("Hello, World!");
        return;
    }

    if (std.mem.eql(u8, path, "/json")) {
        try r.setContentType(.JSON);
        try r.sendBody("{\"message\":\"Hello, World!\"}");
        return;
    }

    const prefix = "/users/";
    if (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and std.mem.indexOfScalar(u8, path[prefix.len..], '/') == null) {
        try r.setContentType(.JSON);
        const id = path[prefix.len..];
        var buffer: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buffer, "{{\"id\":\"{s}\"}}", .{id}) catch "{\"id\":\"\"}";
        try r.sendBody(body);
        return;
    }

    sendNotFound(r);
}

fn configuredPort() u16 {
    if (std.c.getenv("PORT")) |value| {
        return std.fmt.parseInt(u16, std.mem.span(value), 10) catch DEFAULT_PORT;
    }

    if (std.c.getenv("RACK_PORT")) |value| {
        return std.fmt.parseInt(u16, std.mem.span(value), 10) catch DEFAULT_PORT;
    }

    return DEFAULT_PORT;
}

pub fn main() !void {
    const port = configuredPort();

    var listener = zap.HttpListener.init(.{
        .port = port,
        .on_request = onRequest,
        .log = false,
        .max_clients = 100000,
    });
    try listener.listen();

    std.debug.print("Zap benchmark listening on 127.0.0.1:{d}\n", .{port});

    zap.start(.{
        .threads = 4,
        .workers = 4,
    });
}
