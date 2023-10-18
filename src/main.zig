const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const janet = @import("janet");
const SDLBackend = @import("SDLBackend");

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

pub const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

var window: *c.SDL_Window = undefined;
var renderer: *c.SDL_Renderer = undefined;

fn app_init() !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
        std.debug.print("Couldn't initialize SDL: {s}\n", .{c.SDL_GetError()});
        return error.BackendError;
    }

    window = c.SDL_CreateWindow("DVUI Ontop Example", c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED, @as(c_int, @intCast(640)), @as(c_int, @intCast(480)), c.SDL_WINDOW_ALLOW_HIGHDPI | c.SDL_WINDOW_RESIZABLE) orelse {
        std.debug.print("Failed to open window: {s}\n", .{c.SDL_GetError()});
        return error.BackendError;
    };

    _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "linear");

    renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_PRESENTVSYNC) orelse {
        std.debug.print("Failed to create renderer: {s}\n", .{c.SDL_GetError()});
        return error.BackendError;
    };

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
}

/// This example shows how to use dvui for floating windows on top of an existing application
/// - dvui renders only floating windows
/// - framerate is managed by application, not dvui
pub fn main() !void {
    // defer _ = gpa_instance.deinit();
    if (std.os.argv.len <= 1) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: {s} IMAGE_FILE\n", .{std.os.argv[0]});
        try stderr.print("IMAGE_FILE does not need to exist at first\n", .{});
        std.os.exit(1);
    }

    var manager = try ObjectManager.init(gpa, std.mem.span(std.os.argv[1]));
    defer manager.deinit();

    // app_init is a stand-in for what your application is already doing to set things up
    try app_init();

    // create SDL backend using existing window and renderer
    var backend = SDLBackend{ .window = window, .renderer = renderer };
    // your app will do the SDL deinit

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), 0, gpa, backend.backend());
    defer win.deinit();

    main_loop: while (true) {
        try win.begin(std.time.nanoTimestamp());

        // send events to dvui if they belong to floating windows
        var event: SDLBackend.c.SDL_Event = undefined;
        while (SDLBackend.c.SDL_PollEvent(&event) != 0) {
            // some global quitting shortcuts
            switch (event.type) {
                // c.SDL_KEYDOWN => {
                //     if (((event.key.keysym.mod & c.KMOD_CTRL) > 0) and event.key.keysym.sym == c.SDLK_q) {
                //         break :main_loop;
                //     }
                // },
                c.SDL_QUIT => {
                    break :main_loop;
                },
                else => {},
            }

            if (try backend.addEvent(&win, event)) {
                // dvui handles this event as it's for a floating window
            } else {
                // dvui doesn't handle this event, send it to the underlying application
            }
        }

        // this is where the application would do it's normal rendering with
        // dvui calls interleaved
        backend.clear();

        try manager.draw();

        // marks end of dvui frame, don't call dvui functions after this
        // - sends all dvui stuff to backend for rendering, must be called before renderPresent()
        _ = try win.end(.{});

        // cursor management
        if (win.cursorRequestedFloating()) |cursor| {
            // cursor is over floating window, dvui sets it
            backend.setCursor(cursor);
        } else {
            // cursor should be handled by application
            backend.setCursor(.bad);
        }

        // render frame to OS
        backend.renderPresent();
    }
}

pub const ObjectManager = struct {
    env: *janet.Environment,
    filename: []const u8,

    pub fn init(alloc: std.mem.Allocator, filename: []const u8) !@This() {
        try janet.init();
        if (std.fs.cwd().openFile(filename, .{})) |file| {
            defer file.close();
            const content = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
            defer alloc.free(content);
            const core_env = janet.Environment.coreEnv(null);
            core_env.def("_", janet.string(content), null);
            const env_obj = try core_env.doString("(load-image _)", "(embed)");
            const env = (try env_obj.unwrap(*janet.Table)).toEnvironment();
            return .{
                .env = env,
                .filename = filename,
            };
        } else |err| {
            if (err != error.FileNotFound) {
                return err;
            }
            const core_env = janet.Environment.coreEnv(null);
            var env_ = janet.Table.initDynamic(0);
            env_.proto = core_env.toTable();
            const env = env_.toEnvironment();
            janet.gcRoot(env_.wrap());
            return .{
                .env = env,
                .filename = filename,
            };
        }
    }

    pub fn persist(this: @This()) !void {
        const img_obj = try this.env.doString("(make-image (curenv))", "(main)");
        const img_s = try img_obj.bytesView();
        const file = try std.fs.cwd().createFile(this.filename, .{});
        defer file.close();
        try file.writeAll(img_s.slice());
        try file.sync();
    }

    pub fn deinit(this: @This()) void {
        _ = janet.gcUnroot(this.env.toTable().wrap());
    }

    pub fn draw(this: *@This()) !void {
        const a = dvui.currentWindow().arena;
        _ = a;

        { // root window
            var float = try dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{} });
            defer float.deinit();
            try dvui.windowHeader("Root Window", "", null);

            if (try dvui.button(@src(), "Persist", .{})) {
                try this.persist();
            }
            if (try dvui.button(@src(), "Toggle Demo Window", .{})) {
                dvui.Examples.show_demo_window = !dvui.Examples.show_demo_window;
            }
            try this.widgetDo(float, "");
        }
        try dvui.Examples.demo();

        const kvs = try this.env.toTable().wrap().dictionaryView();
        // const slice = try a.dupe(janet.KV, kvs.slice());
        for (kvs.slice()) |kv| {
            if (kv.key.unwrap(janet.Symbol)) |key_sym| {
                const key = key_sym.slice;
                var value: janet.Janet = undefined;
                _ = @import("cjanet").janet_resolve(this.env.toC(), key_sym.toC(), @ptrCast(&value));
                if (key.len > 1 and key[0] == '_') {
                    // std.log.debug("k = {s} v = {}", .{ key, value });
                    try this.drawValue(key, value);
                }
            } else |_| {}
        }
    }

    pub fn drawValue(this: *@This(), key: []const u8, value: janet.Janet) !void {
        var open = true;
        var float = try dvui.floatingWindow(@src(), .{ .open_flag = &open, .window_avoid = .nudge }, .{ .min_size_content = .{}, .id_extra = @intFromPtr(key.ptr) });
        defer float.deinit();
        this.env.def("_", value, null);
        const result = try this.env.doString(
            \\(string/format "%q" _)
        , "(embed)");
        const s = try result.bytesView();
        try dvui.windowHeader(key, "", &open);
        if (!open) {
            this.env.def("_", janet.symbol(key), null);
            _ = try this.env.doString("(put (curenv) _ nil)", "(embed)");
            return;
        }

        const layout = try dvui.textLayout(@src(), .{}, .{ .expand = .vertical, .background = false, .min_size_content = .{ .w = 150 } });
        try layout.addText(s.slice(), .{});
        try layout.addTextDone(.{});
        layout.deinit();

        try this.widgetDo(float, key);
    }

    /// widget for Do It and Get It
    fn widgetDo(this: *@This(), float: *dvui.FloatingWindowWidget, key: []const u8) !void {
        var code_buffer: []u8 =
            if (dvui.dataGetSlice(null, float.wd.id, key, []u8)) |data|
            data
        else data: {
            dvui.dataSetSlice(null, float.wd.id, key, &([_]u8{0} ** 1024));
            break :data dvui.dataGetSlice(null, float.wd.id, key, []u8).?;
        };

        {
            var te = dvui.TextEntryWidget.init(@src(), .{ .text = code_buffer }, .{ .expand = .horizontal });
            if (dvui.firstFrame(te.data().id)) {
                dvui.focusWidget(te.data().id, null, null);
            }
            try te.install();

            const emo = te.eventMatchOptions();
            for (dvui.events()) |*e| {
                // for global shortcuts, don't call eventMatch and do it early in the frame
                if (!dvui.eventMatch(e, emo))
                    continue;

                if (e.evt == .key and e.evt.key.code == .enter and e.evt.key.action == .down) {
                    e.handled = true; // prevent normal processing

                    const text = code_buffer[0..te.len];
                    try this.tryDo(text, code_buffer, .getit);
                }

                if (!e.handled) {
                    te.processEvent(e, false);
                }
            }

            try te.drawText();
            te.deinit();

            const text = code_buffer[0..te.len];

            const box = try dvui.box(@src(), .horizontal, .{ .gravity_x = 1 });
            defer box.deinit();
            if (try dvui.button(@src(), "Do It", .{})) {
                try this.tryDo(text, code_buffer, .doit);
            }
            if (try dvui.button(@src(), "Get It", .{})) {
                try this.tryDo(text, code_buffer, .getit);
            }
        }
    }

    fn tryDo(this: *@This(), text: []const u8, buffer: []u8, action: enum { doit, getit }) !void {
        _ = buffer;
        if (this.env.doString(text, "(embed repl)")) |res| {
            // @breakpoint();
            std.log.info("exec result = {}", .{res});
            if (action == .getit) {
                const sym = janet.Symbol.gen();
                const slice = try gpa.dupeZ(u8, sym.slice);
                this.env.def(slice, res, null);
                std.log.info("(def {s} {})", .{ slice, res });
            }
            // @memset(buffer, 0);
        } else |err| {
            std.log.err("when running janet code: {}", .{err});
        }
    }
};
