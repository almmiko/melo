const std = @import("std");
const v8 = @import("zig-v8");
const uv = @import("zig-libuv");

var loop: uv.Loop = undefined;
var alloc: std.mem.Allocator = undefined;
var isolate: v8.Isolate = undefined;

const Task = struct { timeout: u32, cb: v8.Function };
var heap: std.PriorityQueue(Task, void, compare) = undefined;

fn compare(_: void, a: Task, b: Task) std.math.Order {
    if (a.timeout < b.timeout) {
        return .lt;
    } else {
        return .gt;
    }
}

const Print = struct {
    pub fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
        const info = v8.FunctionCallbackInfo.initFromV8(raw_info);

        var hscope: v8.HandleScope = undefined;
        hscope.init(info.getIsolate());
        defer hscope.deinit();

        var data = info.getData().castTo(v8.String);

        var s = info.getArg(0).toString(info.getIsolate().getCurrentContext()) catch unreachable;

        const len = data.lenUtf8(info.getIsolate());
        var buf = std.heap.c_allocator.alloc(u8, len) catch unreachable;

        _ = v8.String.writeUtf8(s, info.getIsolate(), buf);

        std.debug.print("{s}\n", .{buf});

        var returnValue = info.getReturnValue();

        returnValue.set(v8.Number.init(info.getIsolate(), 12));
    }
};

const Timer = struct {
    pub fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
        var info = v8.FunctionCallbackInfo.initFromV8(raw_info);

        var cb = info.getArg(0).castTo(v8.Function);
        var func = v8.Persistent(v8.Function).init(info.getIsolate(), cb);
        var delay = info.getArg(1).toU32(info.getIsolate().getCurrentContext()) catch unreachable;

        const handle = alloc.create(uv.c.uv_timer_t) catch unreachable;

        heap.add(.{ .timeout = delay, .cb = func.inner }) catch unreachable;

        _ = uv.c.uv_timer_init(loop.loop, handle);
        _ = uv.c.uv_timer_start(handle, onComplete, delay, 0);
    }

    pub fn onComplete(handle: [*c]uv.c.uv_timer_t) callconv(.C) void {
        _ = handle;
        var data: ?Task = heap.remove();
        _ = data.?.cb.call(isolate.getCurrentContext(), isolate.getCurrentContext().getGlobal(), &.{});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    alloc = gpa.allocator();

    loop = try uv.Loop.init(alloc);
    defer loop.deinit(alloc);

    heap = std.PriorityQueue(Task, void, compare).init(alloc, {});

    const platform = v8.Platform.initDefault(5, true);
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

    isolate = v8.Isolate.init(&params);
    defer isolate.deinit();

    isolate.enter();
    defer isolate.exit();

    // Create a stack-allocated handle scope.
    var hscope: v8.HandleScope = undefined;
    hscope.init(isolate);
    defer hscope.deinit();

    // ------------------

    var global = v8.ObjectTemplate.initDefault(isolate);

    global.set(v8.String.initUtf8(isolate, "print"), v8.FunctionTemplate.initCallbackData(isolate, Print.callback, isolate.initExternal(&.{})), v8.PropertyAttribute.None);
    global.set(v8.String.initUtf8(isolate, "timeout"), v8.FunctionTemplate.initCallbackData(isolate, Timer.callback, isolate.initExternal(&.{})), v8.PropertyAttribute.None);

    var context = v8.Context.init(isolate, global, null);
    context.enter();

    // Create a string containing the JavaScript source code.
    const scriptString =
        \\function test() { 
        \\      let printValue = print('some'); 
        \\      print(printValue); 
        \\      timeout(function() {
        \\          print('from timeout 3000');
        \\          timeout(function() {
        \\              print('from timeout nested 2000');
        \\          }, 2000);
        \\      }, 3000);
        \\      timeout(function() {
        \\          print('from timeout 1000');
        \\      }, 1000);
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
        // \\function resolveAfter() {
        // \\  return new Promise((resolve) => {
        // \\      resolve('resolved');
        // \\  });
        // \\}
        \\async function asyncCall() {
        \\  print('calling async js');
        \\  const result = await resolveAfter();
        \\  print(result);
        \\}
        \\asyncCall();
        \\
    ;
    //----------------------------------------------------------
    const source = v8.String.initUtf8(isolate, scriptString);
    var scriptName = v8.String.initUtf8(isolate, "test_script");
    var origin = v8.ScriptOrigin.init(isolate, scriptName.toValue(), 0, 0, false, 0, null, false, false, false, null);
    var script = try v8.Script.compile(context, source, origin);

    _ = try script.run(context);

    // Convert the result to an UTF8 string and print it.
    //const res = valueToRawUtf8Alloc(std.heap.c_allocator, isolate, context, value);

    // std.debug.print("{s}\n", .{"await loop"});
    // try loop.run(.until_done);
    // std.debug.print("{s}\n", .{"done loop"});

    // try loop.run(.until_done);
    try loop.run(.default);
}

// pub fn valueToRawUtf8Alloc(alloc1: std.mem.Allocator, isolate: v8.Isolate, ctx: v8.Context, val: v8.Value) []const u8 {
//     const str = val.toString(ctx) catch unreachable;
//     const len = str.lenUtf8(isolate);
//     const buf = alloc1.alloc(u8, len) catch unreachable;
//     _ = str.writeUtf8(isolate, buf);
//     return buf;
// }
