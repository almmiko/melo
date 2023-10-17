const std = @import("std");
const uv = @import("zig-libuv");
const v8 = @import("zig-v8");

var loop: uv.Loop = undefined;

const CallbackData = struct { callback: v8.Function };
var global: v8.ObjectTemplate = undefined;
var context: v8.Persistent(v8.Context) = undefined;
// var cb: v8.Persistent(v8.Function) = undefined;
// var persistentFt: v8.Persistent(v8.FunctionTemplate) = undefined;

const Wrapper = struct {
    pub fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
        const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
        var hscope1: v8.HandleScope = undefined;
        hscope1.init(info.getIsolate());
        defer hscope1.deinit();

        var data = info.getData().castTo(v8.String);

        var s = info.getArg(0).toString(context.inner) catch unreachable;

        const len = data.lenUtf8(info.getIsolate());
        var buf = std.heap.c_allocator.alloc(u8, len) catch unreachable;

        _ = v8.String.writeUtf8(s, info.getIsolate(), buf);

        std.debug.print("{s}\n", .{buf});
    }
};

const Timeout = struct {
    pub fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
        //std.debug.print("timeout call\n", .{});
        const alloc = std.heap.c_allocator;

        const info = v8.FunctionCallbackInfo.initFromV8(raw_info);

        var cb1 = info.getArg(0).castTo(v8.Function);
        var delay = info.getArg(1).toU32(context.inner) catch unreachable;

        var hscope1: v8.HandleScope = undefined;
        hscope1.init(info.getIsolate());
        defer hscope1.deinit();

        var timer = uv.Timer.init(alloc, loop) catch unreachable;

        const cb = v8.Persistent(v8.Function).init(info.getIsolate(), cb1);

        var dptr: CallbackData = .{ .callback = cb.inner };
        timer.setData(&dptr);

        timer.start((struct {
            fn cbTimer(t: *uv.Timer) void {
                var data: CallbackData = t.getData(CallbackData).?.*;
                std.debug.print("before cb call", .{});

                _ = data.callback.call(context.inner, context.inner.getGlobal().toValue(), &.{});
            }
        }).cbTimer, @intCast(delay), 0) catch unreachable;
    }
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    loop = try uv.Loop.init(alloc);
    defer loop.deinit(alloc);

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

    // const global_constructor = isolate.initFunctionTemplateDefault();
    //var persistentFt: v8.Persistent(v8.FunctionTemplate) = v8.Persistent(v8.FunctionTemplate).init(isolate, global_constructor);

    const window_class: v8.Persistent(v8.FunctionTemplate) = v8.Persistent(v8.FunctionTemplate).init(isolate, v8.FunctionTemplate.initDefault(isolate));

    const inst = window_class.inner.getInstanceTemplate();
    inst.setInternalFieldCount(1);

    const proto = window_class.inner.getPrototypeTemplate();

    // proto.set(v8.String.initUtf8(isolate, "print"), ft, v8.PropertyAttribute.ReadOnly);
    // proto.set(v8.String.initUtf8(isolate, "timeout"), timeoutFunction, v8.PropertyAttribute.ReadOnly);

    //var ft = persistentFt.inner.initCallbackData(isolate, Wrapper.callback, isolate.initExternal(&.{}));
    var ft = v8.FunctionTemplate.initCallbackData(isolate, Wrapper.callback, isolate.initExternal(&.{}));
    var ftp = v8.Persistent(v8.FunctionTemplate).init(isolate, ft);

    var timeoutFunction = v8.FunctionTemplate.initCallbackData(isolate, Timeout.callback, isolate.initExternal(&.{}));
    var timeoutFunctionPer = v8.Persistent(v8.FunctionTemplate).init(isolate, timeoutFunction);
    //var timeoutFunction = persistentFt.inner.initCallbackData(isolate, Timeout.callback, isolate.initExternal(&.{}));

    // global = v8.ObjectTemplate.init(isolate, global_constructor);

    // global.set(v8.String.initUtf8(isolate, "print"), ft, v8.PropertyAttribute.ReadOnly);
    // global.set(v8.String.initUtf8(isolate, "timeout"), timeoutFunction, v8.PropertyAttribute.ReadOnly);

    proto.set(v8.String.initUtf8(isolate, "print"), ftp.inner, v8.PropertyAttribute.ReadOnly);
    proto.set(v8.String.initUtf8(isolate, "timeout"), timeoutFunctionPer.inner, v8.PropertyAttribute.ReadOnly);

    // Create a new context.
    var c = isolate.initContext(proto, null);
    context = v8.Persistent(v8.Context).init(isolate, c);
    context.inner.enter();
    defer context.inner.exit();

    // Create a string containing the JavaScript source code.
    const scriptString =
        \\function test() { 
        \\      print('some'); 
        \\      timeout(function() {
        \\          print('from timeout');
        \\          timeout(function() {
        \\              print('from timeout 2');
        \\          }, 3000);
        \\      }, 2000);
        \\};
        \\
        \\test();
        // \\let myPromise = new Promise(function(myResolve, myReject) {
        // \\  let x = 1;
        // \\ if (x == 0) {
        // \\myResolve("OK");
        // \\} else {
        // \\myReject("Error");
        // \\}
        // \\});
        // \\
        // \\myPromise.then(
        // \\  function(value) {print(value);},
        // \\  function(error) {print(error);}
        // \\);
        // \\
        \\function resolveAfter() {
        \\  return new Promise((resolve) => {
        \\      resolve('resolved');
        \\  });
        \\}
        \\async function asyncCall() {
        \\  print('calling');
        \\  const result = await resolveAfter();
        \\  print(result);
        \\}
        \\asyncCall();
        \\
    ;
    const source = v8.String.initUtf8(isolate, scriptString);

    // Compile the source code.
    const script = try v8.Script.compile(context.inner, source, null);

    // Run the script to get the result.
    _ = try script.run(context.inner);

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
