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

pub var env: *janet.Environment = undefined;
var janetWindows: std.ArrayList(JanetValueWindow) = undefined;

/// This example shows how to use dvui for floating windows on top of an existing application
/// - dvui renders only floating windows
/// - framerate is managed by application, not dvui
pub fn main() !void {
    try janet.init();
    const core_env = janet.Environment.coreEnv(null);
    var env_ = janet.Table.initDynamic(0);
    env_.proto = core_env.toTable();
    env = env_.toEnvironment();

    janetWindows = @TypeOf(janetWindows).init(gpa);
    defer {
        for (janetWindows.items) |x| x.deinit();
        janetWindows.deinit();
    }
    const ex = try env.doString("[1 2 3]", "(embed)");
    try janetWindows.append(JanetValueWindow.init(ex));

    // app_init is a stand-in for what your application is already doing to set things up
    try app_init();

    // create SDL backend using existing window and renderer
    var backend = SDLBackend{ .window = window, .renderer = renderer };
    // your app will do the SDL deinit

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), 0, gpa, backend.backend());
    defer win.deinit();

    main_loop: while (true) {
        try win.begin(.{});

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

        try ui_logic();

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

pub const JanetValueWindow = struct {
    value: janet.Janet,
    text_buf: [1024]u8 = .{0} ** 1024,

    pub fn init(value: janet.Janet) @This() {
        janet.gcRoot(value);
        return .{
            .value = value,
        };
    }
    pub fn deinit(this: @This()) void {
        _ = janet.gcUnroot(this.value);
    }

    pub fn draw(this: *@This(), _id: usize) !void {
        var src = @src();
        src.line += @intCast(_id);
        src.line += 10000;
        var float = try dvui.floatingWindow(src, .{}, .{ .min_size_content = .{ .w = 150, .h = 100 }, .expand = .both });
        defer float.deinit();
        env.def("_", this.value, null);
        const result = try env.doString(
            \\(string/format "%q" _)
        , "(embed)");
        const s = try result.bytesView();
        try dvui.windowHeader("_0000v_todo", "", null);

        try dvui.labelNoFmt(@src(), s.slice(), .{ .expand = .both });

        const entry = try dvui.textEntry(@src(), .{ .text = &this.text_buf }, .{ .expand = .horizontal });
        defer entry.deinit();

        const text = this.text_buf[0..entry.len];
        if (text.len > 0 and text[text.len - 1] == '\n') {
            text[text.len - 1] = 0;
            if (env.doString(text, "(embed repl)")) |res| {
                try janetWindows.append(JanetValueWindow.init(res));
                @memset(&this.text_buf, 0);
            } else |err| {
                std.log.err("when running janet code: {}", .{err});
            }
        }
    }
};

var text_buf: [100]u8 = .{0} ** 100;
fn ui_logic() !void {
    const a = dvui.currentWindow().arena;
    _ = a;

    for (janetWindows.items, 0..) |*win, i| {
        try win.draw(i);
    }

    // {
    //     var float = try dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{ .w = 400, .h = 400 } });
    //     defer float.deinit();

    //     try dvui.windowHeader("Floating Window", "", null);

    //     var scroll = try dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_style = .window });
    //     defer scroll.deinit();
    //     {
    //         var tl = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font_style = .title_4 });
    //         defer tl.deinit();
    //         const lorem = "This example shows how to use dvui for floating windows on top of an existing application.";
    //         try tl.addText(lorem, .{});
    //     }
    //     {
    //         var tl2 = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
    //         defer tl2.deinit();
    //         try tl2.addText("The dvui is painting only floating windows and dialogs.", .{});
    //         try tl2.addText("\n\n", .{});
    //         try tl2.addText("Framerate is managed by the application (in this demo capped at vsync).", .{});
    //         try tl2.addText("\n\n", .{});
    //         try tl2.addText("Cursor is only being set by dvui for floating windows.", .{});
    //     }

    //     if (dvui.Examples.show_demo_window) {
    //         if (try dvui.button(@src(), "Hide Demo Window", .{})) {
    //             dvui.Examples.show_demo_window = false;
    //         }
    //     } else {
    //         if (try dvui.button(@src(), "Show Demo Window", .{})) {
    //             dvui.Examples.show_demo_window = true;
    //         }
    //     }
    // }
    // // look at demo() for examples of dvui widgets, shows in a floating window
    // try dvui.Examples.demo();
}

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
