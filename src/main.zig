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
    var manager = try ObjectManager.init();

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

    pub fn init() !@This() {
        try janet.init();
        const core_env = janet.Environment.coreEnv(null);
        var env_ = janet.Table.initDynamic(0);
        env_.proto = core_env.toTable();
        const env = env_.toEnvironment();
        return .{
            .env = env,
        };
    }

    pub fn draw(this: *@This()) !void {
        const a = dvui.currentWindow().arena;
        _ = a;

        {
            var float = try dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{} });
            defer float.deinit();
            try dvui.windowHeader("Root Window", "", null);

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
        var float = try dvui.floatingWindow(@src(), .{ .open_flag = &open }, .{ .min_size_content = .{}, .id_extra = @intFromPtr(key.ptr) });
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

    fn widgetDo(this: *@This(), float: *dvui.FloatingWindowWidget, key: []const u8) !void {
        var doit_buffer = dvui.dataGet(null, float.wd.id, key, [1024]u8) orelse .{0} ** 1024;
        defer dvui.dataSet(null, float.wd.id, key, doit_buffer);

        {
            const entry = try dvui.textEntry(@src(), .{ .text = &doit_buffer, .scroll_vertical_bar = .hide, .scroll_horizontal_bar = .hide }, .{ .expand = .horizontal });
            entry.deinit();
            const text = doit_buffer[0..entry.len];
            if (text.len > 0 and text[text.len - 1] == '\n') {
                text[text.len - 1] = 0;
                try this.tryDo(text[0 .. text.len - 1], &doit_buffer, .getit);
            }
            const box = try dvui.box(@src(), .horizontal, .{ .gravity_x = 1 });
            defer box.deinit();
            if (try dvui.button(@src(), "Do It", .{})) {
                try this.tryDo(text, &doit_buffer, .doit);
            }
            if (try dvui.button(@src(), "Get It", .{})) {
                try this.tryDo(text, &doit_buffer, .getit);
            }
        }
    }

    fn tryDo(this: *@This(), text: []const u8, buffer: []u8, action: enum { doit, getit }) !void {
        _ = buffer;
        if (this.env.doString(text, "(embed repl)")) |res| {
            // @breakpoint();
            std.log.info("exec result = {}", .{res});
            if (action == .getit) {
                // janet.gcRoot(res);
                // defer _ = janet.gcUnroot(res);
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
