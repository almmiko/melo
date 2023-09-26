const std = @import("std");
const uv = @import("zig-libuv-bindings");

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    const loop = try uv.Loop.init(alloc);
    defer loop.deinit(alloc);

    const timer = try uv.Timer.init(alloc, loop);
    defer timer.deinit(alloc);

    try timer.start((struct {
        fn cb(t: *uv.Timer) void {
            _ = t;
            std.debug.print("hello from c lib \n", .{});
        }
    }).cb, 200, 1000);

    try loop.run(.default);
}
