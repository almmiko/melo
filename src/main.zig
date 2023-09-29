const std = @import("std");
const uv = @import("zig-libuv");
const v8 = @import("zig-v8");

var loop: uv.Loop = undefined;
var timer: uv.Timer = undefined;

const CallbackData = struct { context: v8.Context, isolate: v8.Isolate, callback: v8.Function };

var context: v8.Context = undefined;

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    loop = try uv.Loop.init(alloc);
    defer loop.deinit(alloc);
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
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);

            var data = info.getData().castTo(v8.String);

            var s = info.getArg(0).toString(context) catch unreachable;

            const len = data.lenUtf8(info.getIsolate());
            var buf = std.heap.c_allocator.alloc(u8, len) catch unreachable;

            _ = v8.String.writeUtf8(s, info.getIsolate(), buf);

            std.debug.print("{s}\n", .{buf});
        }
    };

    const Timeout = struct {
        pub fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
            //std.debug.print("timeout call\n", .{});

            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);

            var cb = info.getArg(0).castTo(v8.Function);
            var delay = info.getArg(1).toU32(context) catch unreachable;

            timer = uv.Timer.init(alloc, loop) catch unreachable;

            var dptr: CallbackData = .{ .context = context, .isolate = info.getIsolate(), .callback = cb };

            timer.setData(&dptr);

            timer.start((struct {
                fn cbTimer(t: *uv.Timer) void {
                    var data = t.getData(CallbackData).?.*;
                    _ = data.callback.call(data.context, v8.Object.init(data.isolate).toValue(), &.{});
                }
            }).cbTimer, @intCast(delay), 0) catch unreachable;
        }
    };

    const global_constructor = isolate.initFunctionTemplateDefault();

    var ft = v8.FunctionTemplate.initCallbackData(isolate, Wrapper.callback, isolate.initExternal(&.{}));
    var timeoutFunction = v8.FunctionTemplate.initCallbackData(isolate, Timeout.callback, isolate.initExternal(&.{}));

    var global = v8.ObjectTemplate.init(isolate, global_constructor);

    global.set(v8.String.initUtf8(isolate, "print"), ft, v8.PropertyAttribute.ReadOnly);
    global.set(v8.String.initUtf8(isolate, "timeout"), timeoutFunction, v8.PropertyAttribute.ReadOnly);

    // Create a new context.
    context = v8.Context.init(isolate, global, null);
    context.enter();
    defer context.exit();

    // Create a string containing the JavaScript source code.
    const scriptString =
        \\function test() { 
        \\      print('some'); 
        \\      timeout(function() { 
        \\          print('from timeout');
        \\          timeout(function() { 
        \\              print('from timeout 2');
        \\          }, 3000);
        \\      }, 1000);
        \\};
        \\
        \\test();
        \\
    ;
    const source = v8.String.initUtf8(isolate, scriptString);

    // Compile the source code.
    const script = try v8.Script.compile(context, source, null);

    // Run the script to get the result.
    _ = try script.run(context);

    // Convert the result to an UTF8 string and print it.
    //const res = valueToRawUtf8Alloc(std.heap.c_allocator, isolate, context, value);

    //std.debug.print("{s}\n", .{res});

    try loop.run(.default);
}

pub fn valueToRawUtf8Alloc(alloc: std.mem.Allocator, isolate: v8.Isolate, ctx: v8.Context, val: v8.Value) []const u8 {
    const str = val.toString(ctx) catch unreachable;
    const len = str.lenUtf8(isolate);
    const buf = alloc.alloc(u8, len) catch unreachable;
    _ = str.writeUtf8(isolate, buf);
    return buf;
}
