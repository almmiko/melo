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

    // ---------------------------------------------------
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var maybeJsMainFile: []const u8 = undefined;

    if (args.len < 2) {
        std.debug.print("{s}\n", .{"Extected path to the main file"});
        return;
    }

    maybeJsMainFile = args[1];
    // ---------------------------------------------------

    // ---------------------------------------------------
    const pathToMainJsFile = try std.fs.path.resolve(alloc, &.{maybeJsMainFile});
    defer alloc.free(pathToMainJsFile);

    const mainScriptSrc = try std.fs.cwd().readFileAlloc(alloc, pathToMainJsFile, 1e9);
    defer alloc.free(mainScriptSrc);
    // ---------------------------------------------------

    std.log.info("\nv8 version: {s}\n", .{v8.getVersion()});

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

    //----------------------------------------------------------
    const source = v8.String.initUtf8(isolate, mainScriptSrc);
    var scriptName = v8.String.initUtf8(isolate, maybeJsMainFile);
    var origin = v8.ScriptOrigin.init(isolate, scriptName.toValue(), 0, 0, false, 0, null, false, false, false, null);
    var script = try v8.Script.compile(context, source, origin);

    _ = try script.run(context);

    try loop.run(.default);
}
