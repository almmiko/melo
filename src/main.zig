const std = @import("std");
const uv = @import("zig-libuv");
const v8 = @import("zig-v8");

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    const loop = try uv.Loop.init(alloc);
    defer loop.deinit(alloc);

    const timer = try uv.Timer.init(alloc, loop);
    defer timer.deinit(alloc);

    const platform = v8.Platform.initDefault(0, true);
    defer platform.deinit();

    std.log.info("v8 version: {s}\n", .{v8.getVersion()});

    v8.initV8Platform(platform);
    v8.initV8();
    defer {
        _ = v8.deinitV8();
        v8.deinitV8Platform();
    }

    var params = v8.initCreateParams();
    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    defer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);

    var isolate = v8.Isolate.init(&params);
    defer isolate.deinit();

    isolate.enter();
    defer isolate.exit();

    // Create a stack-allocated handle scope.
    var hscope: v8.HandleScope = undefined;
    hscope.init(isolate);
    defer hscope.deinit();

    const Wrapper = struct {
        pub fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
            _ = raw_info;
            std.debug.print("Hello zig node\n", .{});
        }
    };

    const global_constructor = isolate.initFunctionTemplateDefault();

    var ft = v8.FunctionTemplate.initCallbackData(isolate, Wrapper.callback, isolate.initExternal(&.{}));

    var key = v8.String.initUtf8(isolate, "print");

    var global = v8.ObjectTemplate.init(isolate, global_constructor);
    global.set(key, ft, v8.PropertyAttribute.ReadOnly);

    // Create a new context.
    var context = v8.Context.init(isolate, global, null);
    context.enter();
    defer context.exit();

    // Create a string containing the JavaScript source code.
    const source = v8.String.initUtf8(isolate, "'Hello' + ', World! 🍏🍓' + Math.sin(Math.PI/2) + print()");

    // Compile the source code.
    const script = try v8.Script.compile(context, source, null);

    // Run the script to get the result.
    const value = try script.run(context);

    // Convert the result to an UTF8 string and print it.
    const res = valueToRawUtf8Alloc(std.heap.c_allocator, isolate, context, value);

    std.debug.print("{s}\n", .{res});

    try timer.start((struct {
        fn cb(t: *uv.Timer) void {
            _ = t;
            std.debug.print("hello from c lib \n", .{});
        }
    }).cb, 200, 1000);

    try loop.run(.default);
}

pub fn valueToRawUtf8Alloc(alloc: std.mem.Allocator, isolate: v8.Isolate, ctx: v8.Context, val: v8.Value) []const u8 {
    const str = val.toString(ctx) catch unreachable;
    const len = str.lenUtf8(isolate);
    const buf = alloc.alloc(u8, len) catch unreachable;
    _ = str.writeUtf8(isolate, buf);
    return buf;
}
