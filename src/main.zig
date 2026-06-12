const zig_atleast_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

pub const panic = std.debug.FullPanic(panicHandler);

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [4096]u8 = undefined;
    var fw = logFile().writerStreaming(&buf);
    logWrite(&fw.interface, level, scope, format, args) catch
        std.debug.panic("write to log file failed: {t}", .{fw.err.?});
}

fn logWrite(
    w: *std.Io.Writer,
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) error{WriteFailed}!void {
    const level_txt = comptime level.asText();
    const scope_txt = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    var st: win32.SYSTEMTIME = undefined;
    win32.GetLocalTime(&st);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} " ++ level_txt ++ ": " ++ scope_txt, .{
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
    });
    try w.print(format ++ "\r\n", args);
    try w.flush();
}

fn msgBoxFmt(comptime fmt: []const u8, args: anytype) void {
    // TODO: show an actual msgbox instead
    std.debug.panic(fmt, args);
}

const MsgBoxIcon = enum {
    asterisk,
};
fn msgBox(icon: MsgBoxIcon, title: [*:0]const u16, msg: [*:0]const u16) void {
    _ = win32.MessageBoxW(null, msg, title, switch (icon) {
        .asterisk => .{ .ICONASTERISK = 1 },
    });
}

fn appdataPath(buf: []u16, name: []const u16) [:0]u16 {
    const localappdata = std.process.getenvW(win32.L("LOCALAPPDATA")) orelse
        @panic("environment variable LOCALAPPDATA not found");
    const len = localappdata.len + name.len;
    if (len >= buf.len) @panic("LOCALAPPDATA path too long");
    @memcpy(buf[0..localappdata.len], localappdata);
    @memcpy(buf[localappdata.len..][0..name.len], name);
    buf[len] = 0;
    return buf[0..len :0];
}

fn logFile() std.fs.File {
    if (global.log_file) |file| return file;

    var cur_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    var prev_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;

    const dir = appdataPath(&cur_buf, win32.L("\\AudioSwitch"));
    if (0 == win32.CreateDirectoryW(dir.ptr, null)) {
        const e = win32.GetLastError();
        if (e != win32.ERROR_ALREADY_EXISTS) win32.panicWin32("CreateDirectory(log)", e);
    }

    // Roll: discard the previous log.1.txt, then rename this run's predecessor
    // log.txt -> log.1.txt. Both are best-effort: either may not exist yet.
    const prev = appdataPath(&prev_buf, win32.L("\\AudioSwitch\\log.1.txt"));
    const cur = appdataPath(&cur_buf, win32.L("\\AudioSwitch\\log.txt"));
    _ = win32.DeleteFileW(prev.ptr);
    _ = win32.MoveFileW(cur.ptr, prev.ptr);

    // CREATE_ALWAYS => start this run with a fresh, empty log.txt.
    const handle = win32.CreateFileW(
        cur.ptr,
        win32.FILE_GENERIC_WRITE,
        .{ .READ = 1 },
        null,
        win32.CREATE_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE)
        win32.panicWin32("CreateFile(log)", win32.GetLastError());

    const file: std.fs.File = .{ .handle = handle };
    global.log_file = file;
    return file;
}

threadlocal var thread_is_panicking = false;

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    if (!thread_is_panicking) {
        thread_is_panicking = true;
        crashMessageBox(msg, ret_addr orelse @returnAddress());
    }
    std.debug.defaultPanic(msg, ret_addr);
}

fn crashMessageBox(msg: []const u8, ret_addr: usize) void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // don't free, we're about to crash
    const arena = arena_instance.allocator();
    var allocating: std.Io.Writer.Allocating = .init(arena);
    const write_result = writeCrash(&allocating.writer, msg, ret_addr);
    const final_msg: [*:0]const u8 = blk: {
        write_result catch {
            const marker = "[TRUNCATED]";
            const buf = allocating.writer.buffer;
            if (buf.len <= marker.len) break :blk "failed to allocate memory for error";
            // Prefer to append after the written content; if there isn't room,
            // overwrite the tail of the buffer instead.
            const max_start = buf.len - marker.len - 1;
            const start = @min(allocating.writer.end, max_start);
            @memcpy(buf[start..][0..marker.len], marker);
            buf[start + marker.len] = 0;
        };
        break :blk @ptrCast(allocating.writer.buffer.ptr);
    };
    _ = win32.MessageBoxA(null, final_msg, "Audio Switch Crashed", .{ .ICONHAND = 1 });
}

fn writeCrash(writer: *std.Io.Writer, msg: []const u8, ret_addr: usize) error{WriteFailed}!void {
    try writer.print("{s}\n\n", .{msg});
    if (zig_atleast_16) {
        try std.debug.writeCurrentStackTrace(.{
            .first_address = ret_addr,
            .allow_unsafe_unwind = true, // we're crashing anyway, give it our all!
        }, .{ .writer = writer, .mode = .no_color });
    } else if (std.debug.getSelfDebugInfo()) |debug_info| {
        std.debug.writeCurrentStackTrace(writer, debug_info, .no_color, ret_addr) catch {};
    } else |_| {}
    try writer.writeByte(0);
}

const TIMER_UPDATE_SYSTRAY = 3;
const WM_AUDIO_CHANGE = win32.WM_USER + 4;
const WM_MAIN_SHELL_NOTIFY = win32.WM_USER + 5;

const WM_AUDIO_CHANGE_RESULT = 0x4fbbe6c4;

const Icon = struct {
    form_factor: ?audio.FormFactor,
    tint: render.Tint,
};
const IconKey = struct {
    form_factor: ?audio.FormFactor,
    tint: render.Tint,
    size: u16,
};
const IconMap = std.AutoArrayHashMapUnmanaged(IconKey, win32.HICON);
const MenuIconMap = std.AutoArrayHashMapUnmanaged(IconKey, win32.HBITMAP);
const Config = struct {
    device1: ?[:0]const u16,
    device2: ?[:0]const u16,
};

const global = struct {
    var wm_taskbarcreated: u32 = undefined;
    var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_instance.allocator();
    var config: ?Config = null;
    var retry_timer_set: bool = false;
    var systray_icon_state: ?SystrayIconState = null;
    var last_systray_dpi: ?u32 = null;
    var icons: IconMap = .{};
    var menu_icons: MenuIconMap = .{};
    var log_file: ?std.fs.File = null;
};
const SystrayIconState = struct {
    icon: Icon,
    version_set: bool,
};

pub fn wWinMain(
    hInstance: win32.HINSTANCE,
    hPrevInstance: ?win32.HINSTANCE,
    pCmdLine: [*:0]u16,
    nCmdShow: u16,
) c_int {
    _ = hInstance;
    _ = hPrevInstance;
    _ = pCmdLine;
    _ = nCmdShow;

    win32.SetLastError(.NO_ERROR);
    {
        const maybe_mutex = win32.CreateMutexW(
            null,
            0,
            win32.L("AudioSwitch-" ++ audio_switch_guid_string),
        );
        const err = win32.GetLastError();
        const mutex = maybe_mutex orelse win32.panicWin32("CreateMutex", err);
        _ = mutex;
        switch (err) {
            win32.NO_ERROR => {},
            win32.ERROR_ALREADY_EXISTS => {
                msgBox(.asterisk, win32.L("AudioSwitch"), win32.L("AudioSwitch already running"));
                return 0;
            },
            else => win32.panicWin32("CreateMutex", err),
        }
    }

    global.wm_taskbarcreated = win32.RegisterWindowMessageW(win32.L("TaskbarCreated"));
    if (global.wm_taskbarcreated == 0) {
        win32.panicWin32("RegisterWindowMessage(TaskbarCreated)", win32.GetLastError());
    } else {
        std.log.info("WM_TASKBARCREATED={}", .{global.wm_taskbarcreated});
    }

    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
        if (hr.failed) win32.panicHresult("CoInitializeEx", hr);
    }

    const CLASS_NAME = win32.L("AppSwitchWindow");

    {
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            // .style = .{ .VREDRAW = 1, .HREDRAW = 1 },
            .style = .{},
            .lpfnWndProc = wnd_proc_main,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = win32.GetModuleHandleW(null),
            // .hIcon = global.icons.large,
            .hIcon = null,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            // .hIconSm = global.icons.small,
            .hIconSm = null,
        };
        if (0 == win32.RegisterClassExW(&wc)) win32.panicWin32(
            "RegisterClass",
            win32.GetLastError(),
        );
    }

    const hwnd = win32.CreateWindowExW(
        .{
            .APPWINDOW = 1,
            .NOREDIRECTIONBITMAP = 1,
            //.ACCEPTFILES = 1,
        },
        CLASS_NAME,
        win32.L("Audio Switch"),
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        null, // parent window
        null, // menu
        win32.GetModuleHandleW(null),
        null,
    ) orelse win32.panicWin32("CreateWindow", win32.GetLastError());

    {
        var err: HResultError = undefined;
        audio.init(global.gpa, .{ .hwnd = hwnd, .msg = WM_AUDIO_CHANGE }, &err) catch std.debug.panic("{f}", .{err});
    }

    std.log.info("{} audio devices:", .{audio.devices.items.len});
    for (audio.devices.items) |device| {
        std.log.info("\"{f}\" {f}", .{
            std.unicode.fmtUtf16Le(device.name),
            std.unicode.fmtUtf16Le(device.id),
        });
    }

    loadConfig();

    {
        const result = win32.SendMessageW(
            hwnd,
            WM_AUDIO_CHANGE,
            @intFromEnum(audio.ChangeKind.default_render_console),
            0,
        );
        std.debug.assert(result == WM_AUDIO_CHANGE_RESULT);
    }

    while (true) {
        var msg: win32.MSG = undefined;
        const result = win32.GetMessageW(&msg, null, 0, 0);
        if (result < 0) win32.panicWin32("GetMessage", win32.GetLastError());
        if (result == 0) {
            std.log.info("WM_QUIT", .{});
            if (shellNotifyDelete(hwnd)) |err| {
                std.log.err("shellNotifyDelete failed, error={f}", .{err});
                if (msg.wParam == 0) return 0xff;
            }
            return @intCast(msg.wParam);
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

fn getSystrayMonitor() ?win32.HMONITOR {
    if (win32.FindWindowW(win32.L("Shell_TrayWnd"), null)) |hwnd_systray| {
        if (win32.MonitorFromWindow(hwnd_systray, win32.MONITOR_DEFAULTTONULL)) |m| return m;
        std.log.warn("MonitorFromWindow for systray failed, error={f}", .{win32.GetLastError()});
    } else {
        std.log.warn("unable to find systray window, defaulting to primary monitor", .{});
    }
    // POINT pt = { 0, 0 };
    const monitor = win32.MonitorFromPoint(.{ .x = 0, .y = 0 }, win32.MONITOR_DEFAULTTOPRIMARY) orelse {
        std.log.warn("MonitorFromPoint at 0,0 for primary failed, error={f}", .{win32.GetLastError()});
        return null;
    };
    return monitor;
}

fn getSystrayDpi() ?u32 {
    const systray_monitor = getSystrayMonitor() orelse return null;
    var dpi: XY(u32) = undefined;
    {
        const hr = win32.GetDpiForMonitor(systray_monitor, win32.MDT_EFFECTIVE_DPI, &dpi.x, &dpi.y);
        if (hr.failed) {
            std.log.warn("GetDpiForMonitor for systray failed, error={f}", .{win32.GetLastError()});
            return null;
        }
    }
    if (dpi.x != dpi.y) std.debug.panic("dpix {} != dpiy {}", .{ dpi.x, dpi.y });
    return dpi.x;
}

fn getSystemSmallIconSize() XY(u16) {
    const maybe_dpi = getSystrayDpi();
    if (maybe_dpi != global.last_systray_dpi) {
        std.log.info("systray-dpi: {?}", .{maybe_dpi});
        global.last_systray_dpi = maybe_dpi;
    }
    if (maybe_dpi) |dpi| return .{
        .x = @intCast(win32.GetSystemMetricsForDpi(.CXSMICON, dpi)),
        .y = @intCast(win32.GetSystemMetricsForDpi(.CYSMICON, dpi)),
    };
    return .{
        .x = @intCast(win32.GetSystemMetrics(.CXSMICON)),
        .y = @intCast(win32.GetSystemMetrics(.CYSMICON)),
    };
}

fn getSystrayIcon(icon: Icon) win32.HICON {
    const icon_size_xy = getSystemSmallIconSize();
    const min_size = @min(icon_size_xy.x, icon_size_xy.y);
    const key: IconKey = .{ .form_factor = icon.form_factor, .tint = icon.tint, .size = min_size };

    if (global.icons.get(key)) |hicon| return hicon;

    std.log.info(
        "rendering {?t}/{t} icon at {}x{} ({})",
        .{ icon.form_factor, icon.tint, icon_size_xy.x, icon_size_xy.y, min_size },
    );
    const len: usize = @as(usize, min_size) * min_size * 4;
    const pixels = std.heap.page_allocator.alloc(u8, len) catch |e| oom(e);
    defer std.heap.page_allocator.free(pixels);
    @memset(pixels, 0); // start fully transparent

    render.systrayBitmap(pixels, min_size, icon.form_factor, render.tintColor(icon.tint));

    const hicon = iconFromRgba(pixels, min_size);
    global.icons.put(std.heap.page_allocator, key, hicon) catch |e| oom(e);
    return hicon;
}

// Build an HICON from a tightly-packed `size`x`size` 32bpp straight-alpha BGRA
// buffer with the top row first.
fn iconFromRgba(pixels: []const u8, size: u16) win32.HICON {
    var bi: win32.BITMAPINFO = std.mem.zeroes(win32.BITMAPINFO);
    bi.bmiHeader.biSize = @sizeOf(win32.BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = size;
    bi.bmiHeader.biHeight = -@as(i32, size); // negative height => top-down rows
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = win32.BI_RGB;

    var dib_bits: ?*anyopaque = undefined;
    const color = win32.CreateDIBSection(
        null,
        &bi,
        win32.DIB_RGB_COLORS,
        &dib_bits,
        null,
        0,
    ) orelse win32.panicWin32("CreateDIBSection(systray icon)", win32.GetLastError());
    defer _ = win32.DeleteObject(color);

    const byte_count: usize = @as(usize, size) * size * 4;
    @memcpy(@as([*]u8, @ptrCast(dib_bits.?))[0..byte_count], pixels[0..byte_count]);

    // The 32bpp color bitmap carries its own alpha, so the AND mask just needs to be
    // the right size; an all-zero monochrome mask leaves every pixel visible.
    const mask = win32.CreateBitmap(size, size, 1, 1, null) orelse
        win32.panicWin32("CreateBitmap(systray icon mask)", win32.GetLastError());
    defer _ = win32.DeleteObject(mask);

    var info: win32.ICONINFO = .{
        .fIcon = win32.TRUE,
        .xHotspot = 0,
        .yHotspot = 0,
        .hbmMask = mask,
        .hbmColor = color,
    };
    return win32.CreateIconIndirect(&info) orelse
        win32.panicWin32("CreateIconIndirect(systray icon)", win32.GetLastError());
}

// A 32bpp premultiplied-BGRA bitmap of `icon`, for a menu item's hbmpItem (menus
// alpha-blend it, which requires premultiplied alpha). Cached for the process.
fn getMenuBitmap(form_factor: ?audio.FormFactor) win32.HBITMAP {
    const size: u16 = @intCast(win32.GetSystemMetrics(win32.SM_CXSMICON));
    const key: IconKey = .{ .form_factor = form_factor, .tint = .neutral, .size = size };
    if (global.menu_icons.get(key)) |bmp| return bmp;

    // Match the menu label color (a popup menu is light even in dark mode).
    const c = win32.GetSysColor(win32.COLOR_MENUTEXT);
    const color: render.Rgb = .{ .r = @truncate(c), .g = @truncate(c >> 8), .b = @truncate(c >> 16) };

    var bi: win32.BITMAPINFO = std.mem.zeroes(win32.BITMAPINFO);
    bi.bmiHeader.biSize = @sizeOf(win32.BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = size;
    bi.bmiHeader.biHeight = -@as(i32, size); // negative height => top-down rows
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = win32.BI_RGB;

    var dib_bits: ?*anyopaque = undefined;
    const bmp = win32.CreateDIBSection(null, &bi, win32.DIB_RGB_COLORS, &dib_bits, null, 0) orelse
        win32.panicWin32("CreateDIBSection(menu icon)", win32.GetLastError());

    const buf = @as([*]u8, @ptrCast(dib_bits.?))[0 .. @as(usize, size) * size * 4];
    @memset(buf, 0);
    render.systrayBitmap(buf, size, form_factor, color);
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        const a: u32 = buf[i + 3];
        buf[i + 0] = @intCast(@as(u32, buf[i + 0]) * a / 255);
        buf[i + 1] = @intCast(@as(u32, buf[i + 1]) * a / 255);
        buf[i + 2] = @intCast(@as(u32, buf[i + 2]) * a / 255);
    }

    global.menu_icons.put(std.heap.page_allocator, key, bmp) catch |e| oom(e);
    return bmp;
}

const audio_switch_guid_string = "2d899a62-6ff7-4d8b-81f6-379d1d7b70f5";
const audio_switch_guid: win32.Guid = .initString(audio_switch_guid_string);

fn setShellNotifyIconId(data: *win32.NOTIFYICONDATAW) void {
    // NOTE: It seems that microsoft has some requirement that if you use a GUID
    //       for your notification icon, your exe must always be running from the
    //       same path.  Therefore, we use the current exe path as a hash for the
    //       guid so that if the exe moves, our GUID changes and the OS still allows
    //       us to create the systray icon.
    data.guidItem = audio_switch_guid;
    // data.uFlags |= win32.NIF_GUID;
    data.uFlags.GUID = 1;
}

const NotifyKind = enum { add, modify };
fn shellNotifySet(kind: NotifyKind, hwnd: win32.HWND, hicon: win32.HICON) ?win32.WIN32_ERROR {
    var data = std.mem.zeroes(win32.NOTIFYICONDATAW);
    data.cbSize = @sizeOf(@TypeOf(data));
    data.hWnd = hwnd;
    data.uFlags = .{ .ICON = 1, .MESSAGE = 1 }; // = NIF_ICON | NIF_MESSAGE;
    data.hIcon = hicon;
    data.uCallbackMessage = WM_MAIN_SHELL_NOTIFY;
    setShellNotifyIconId(&data);
    win32.SetLastError(.NO_ERROR);
    if (0 == win32.Shell_NotifyIconW(switch (kind) {
        .add => win32.NIM_ADD,
        .modify => win32.NIM_MODIFY,
    }, &data)) return win32.GetLastError();
    return null;
}

fn shellNotifyDelete(hwnd: win32.HWND) ?win32.WIN32_ERROR {
    var data = std.mem.zeroes(win32.NOTIFYICONDATAW);
    data.cbSize = @sizeOf(@TypeOf(data));
    data.hWnd = hwnd;
    setShellNotifyIconId(&data);
    win32.SetLastError(.NO_ERROR);
    if (0 == win32.Shell_NotifyIconW(win32.NIM_DELETE, &data)) {
        const err = win32.GetLastError();
        std.log.err("systray-icon: DELETE failed, error={f}", .{err});
        return err;
    }
    std.log.info("systray-icon: deleted", .{});
    return null;
}

fn updateSystrayIcon3(hwnd: win32.HWND, icon: Icon) void {
    if (global.systray_icon_state) |*state| {
        if (std.meta.eql(state.icon, icon)) return;
    }

    const hicon = getSystrayIcon(icon);

    if (global.systray_icon_state != null) {
        if (shellNotifySet(.modify, hwnd, hicon)) |err| {
            std.log.err("systray-icon: failed, error={f}", .{err});
        } else {
            std.log.info("systray-icon: modified ({?t}/{t})", .{ icon.form_factor, icon.tint });
            global.systray_icon_state.?.icon = icon;
            return;
        }
    }

    var first_attempt: bool = true;
    while (true) : (first_attempt = false) {
        if (shellNotifySet(.add, hwnd, hicon)) |err| {
            std.log.err("systray-icon: failed, error={f}", .{err});
        } else {
            std.log.info("systray-icon: added ({?t}/{t})", .{ icon.form_factor, icon.tint });
            global.systray_icon_state = .{
                .icon = icon,
                .version_set = false,
            };
            return;
        }
        if (!first_attempt) break;
        if (shellNotifyDelete(hwnd)) |err| {
            _ = err; // error already logged
        } else {
            global.systray_icon_state = null;
        }
    }
}

// This can fail if explorer.exe isn't running (has crashed) or is
// in the process of starting.  We should get WM_TASKBARCREATED when
// it's ready and we'll retry adding the notification icon then.
fn updateSystrayIcon2(hwnd: win32.HWND, icon: Icon) void {
    updateSystrayIcon3(hwnd, icon);
    if (global.systray_icon_state) |*state| {
        if (!state.version_set) {
            var data = std.mem.zeroes(win32.NOTIFYICONDATAW);
            data.cbSize = @sizeOf(@TypeOf(data));
            data.hWnd = hwnd;
            data.Anonymous.uVersion = win32.NOTIFYICON_VERSION_4;
            setShellNotifyIconId(&data);
            if (0 != win32.Shell_NotifyIconW(win32.NIM_SETVERSION, &data)) {
                state.version_set = true;
            } else {
                // This has happened, see:
                //     https://tuple-app.sentry.io/issues/5108783112/?project=4505399118987264
                // On this device this call has worked before, but for some reason this time it
                // didn't. In this case the error happened 4 seconds after Tuple launched,
                // and it was a "--boot-launch". So, looks like this can fail when Windows is
                // still booting?
                std.log.err("Shell_NotifyIconW SetVersion failed, error={f}", .{win32.GetLastError()});
            }
        }
    }
}

fn updateSystrayIcon(hwnd: win32.HWND, icon: Icon) void {
    updateSystrayIcon2(hwnd, icon);

    if ((global.systray_icon_state != null) and
        (std.meta.eql(global.systray_icon_state.?.icon, icon)) and
        (global.systray_icon_state.?.version_set))
    {
        if (global.retry_timer_set) {
            if (0 != win32.KillTimer(hwnd, TIMER_UPDATE_SYSTRAY)) {
                std.log.info("retry stopped", .{});
                global.retry_timer_set = false;
            } else {
                std.log.err("KillTimer for systray failed, error={f}", .{win32.GetLastError()});
                // we'll get it on the next iteration I guess?
            }
        }
    } else {
        if (!global.retry_timer_set) {
            // retry every 4 seconds I guess?
            if (0 != win32.SetTimer(hwnd, TIMER_UPDATE_SYSTRAY, 4000, null)) {
                std.log.info("retry started", .{});
                global.retry_timer_set = true;
            } else {
                const handler = if (builtin.mode == .Debug) std.debug.panic else std.log.err;
                handler("SetTimer for systray failed, error={f}", .{win32.GetLastError()});
            }
        }
    }
}

fn getConfig() *Config {
    return &global.config.?;
}

// Read the two device files from %LOCALAPPDATA%\AudioSwitch. Must run after
// audio.init so the device list (all states) is populated to validate against.
fn loadConfig() void {
    global.config = .{
        .device1 = loadDevice(win32.L("\\AudioSwitch\\device1.txt")),
        .device2 = loadDevice(win32.L("\\AudioSwitch\\device2.txt")),
    };
}

// Returns the configured endpoint id (gpa-owned), or null if the file is absent
// or names a device that is truly gone (absent from the all-states list) — in
// which case the stale file is deleted.
fn loadDevice(name: []const u16) ?[:0]const u16 {
    var path_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    const path = appdataPath(&path_buf, name);

    const handle = win32.CreateFileW(
        path.ptr,
        win32.FILE_GENERIC_READ,
        .{ .READ = 1 },
        null,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE) {
        const e = win32.GetLastError();
        if (e == win32.ERROR_FILE_NOT_FOUND) return null;
        win32.panicWin32("CreateFile(read device)", e);
    }

    var buf: [1024]u8 = undefined;
    const n = blk: {
        // Read then close, so the discard paths below can delete the file (we didn't
        // open with FILE_SHARE_DELETE).
        const file: std.fs.File = .{ .handle = handle };
        defer file.close();
        break :blk file.readAll(&buf) catch |e|
            std.debug.panic("read {f} failed: {t}", .{ std.unicode.fmtUtf16Le(path), e });
    };

    // A valid endpoint id is a short ASCII string; a file that fills the buffer
    // is corrupt — discard it rather than crash.
    if (n == buf.len) {
        std.log.warn("device file {f} too large, discarding", .{std.unicode.fmtUtf16Le(path)});
        discardDeviceFile(path);
        return null;
    }
    const text = std.mem.trim(u8, buf[0..n], " \t\r\n");

    const id = std.unicode.utf8ToUtf16LeAllocZ(global.gpa, text) catch |e| switch (e) {
        error.OutOfMemory => oom(error.OutOfMemory),
        error.InvalidUtf8 => {
            std.log.warn("device file {f} is not valid UTF-8, discarding", .{std.unicode.fmtUtf16Le(path)});
            discardDeviceFile(path);
            return null;
        },
    };

    // The all-states device list is the authority: an id absent from it is truly
    // gone (not merely unplugged), so drop the stale file.
    if (audio.indexOfId(id) == null) {
        std.log.info("configured device is gone, clearing {f}", .{std.unicode.fmtUtf16Le(path)});
        global.gpa.free(id);
        discardDeviceFile(path);
        return null;
    }
    return id;
}

fn discardDeviceFile(path: [:0]const u16) void {
    if (0 == win32.DeleteFileW(path.ptr)) {
        const e = win32.GetLastError();
        if (e != win32.ERROR_FILE_NOT_FOUND) win32.panicWin32("DeleteFile(device)", e);
    }
}

fn wnd_proc_main(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CLOSE => {
            @panic("what to do with WM_CLOSE?");
        },
        win32.WM_DESTROY => {
            @panic("what to do with WM_DESTROY?");
        },
        win32.WM_TIMER => {
            @panic("TODO: WM_TIMER");
        },
        WM_AUDIO_CHANGE => {
            const change_kind: audio.ChangeKind = @enumFromInt(wparam);
            // std.log.info("change kind {t}", .{change_kind});
            switch (change_kind) {
                .devices => {
                    var err: HResultError = undefined;
                    audio.sync(global.gpa, &err) catch std.debug.panic("{f}", .{err});
                },
                .default_render_console => defaultRenderChanged(hwnd),
                .default_render_media,
                .default_render_comms,
                .default_capture_console,
                .default_capture_media,
                .default_capture_comms,
                => |k| {
                    _ = k;
                    // std.log.err("TODO: handle {t} changed", .{k});
                },
            }
            return WM_AUDIO_CHANGE_RESULT;
        },
        WM_MAIN_SHELL_NOTIFY => {
            const maybe_action: ?enum { left, right } = blk: switch (win32.loword(lparam)) {
                win32.WM_CONTEXTMENU => {
                    break :blk .right;
                },
                win32.NIN_SELECT => {
                    break :blk .left;
                },
                else => |lparam_lo| {
                    if (false) std.log.debug(
                        "ignoring shell notify {} (0x{0x}) hiword(lparam)={} (0x{1x}) wparam={} (0x{2x})",
                        .{ lparam_lo, wparam, win32.hiword(lparam) },
                    );
                    break :blk null;
                },
            };
            if (maybe_action) |action| {
                // For NOTIFYICON_VERSION_4 the anchor point is in wparam for both
                // the left (NIN_SELECT) and right (WM_CONTEXTMENU) notifications.
                const x = win32.xFromLparam(@bitCast(wparam));
                const y = win32.yFromLparam(@bitCast(wparam));
                switch (action) {
                    .left => leftClick(hwnd, x, y),
                    .right => rightClick(hwnd, x, y),
                }
            }
            return 0;
        },
        else => if (msg == global.wm_taskbarcreated) {
            std.log.info("WM_TASKBARCREATED", .{});
            global.systray_icon_state = null;
            if (0 == win32.PostMessageW(
                hwnd,
                WM_AUDIO_CHANGE,
                @intFromEnum(audio.ChangeKind.default_render_console),
                0,
            )) win32.panicWin32("PostMessage", win32.GetLastError());
            return 0;
        } else return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn rightClick(hwnd: win32.HWND, x: i32, y: i32) void {
    const menu = win32.CreatePopupMenu() orelse
        win32.panicWin32("CreatePopupMenu", win32.GetLastError());
    defer if (0 == win32.DestroyMenu(menu)) win32.panicWin32("DestroyMenu", win32.GetLastError());

    const MENU_CLEAR_DEVICES = 1;
    const MENU_QUIT = 2;
    if (0 == win32.AppendMenuW(menu, win32.MF_STRING, MENU_CLEAR_DEVICES, win32.L("Clear devices")))
        win32.panicWin32("AppendMenu(clear)", win32.GetLastError());
    if (0 == win32.AppendMenuW(menu, win32.MF_SEPARATOR, 0, null))
        win32.panicWin32("AppendMenu(separator)", win32.GetLastError());
    if (0 == win32.AppendMenuW(menu, win32.MF_STRING, MENU_QUIT, win32.L("Quit")))
        win32.panicWin32("AppendMenu(quit)", win32.GetLastError());

    // Required for a systray menu to dismiss when the user clicks elsewhere. Can
    // legitimately fail under Windows' foreground lock, so warn rather than die.
    if (0 == win32.SetForegroundWindow(hwnd)) std.log.warn(
        "SetForegroundWindow failed, error={f}",
        .{win32.GetLastError()},
    );

    win32.SetLastError(.NO_ERROR);
    const cmd = win32.TrackPopupMenu(
        menu,
        .{ .RETURNCMD = 1, .NONOTIFY = 1, .RIGHTBUTTON = 1 },
        x,
        y,
        0,
        hwnd,
        null,
    );
    const track_error = win32.GetLastError();
    // Second half of the KB135788 workaround: nudge our window so the menu
    // dismisses cleanly on a click-away.
    if (0 == win32.PostMessageW(hwnd, win32.WM_NULL, 0, 0))
        win32.panicWin32("PostMessage(WM_NULL)", win32.GetLastError());

    switch (cmd) {
        0 => {
            if (track_error != .NO_ERROR) std.log.warn(
                "TrackPopupMenu returned 0, either error or dismissed, error={f}",
                .{track_error},
            );
        },
        MENU_CLEAR_DEVICES => clearDevices(hwnd),
        MENU_QUIT => win32.PostQuitMessage(0),
        else => std.debug.panic("unexpected TrackPopupMenu result {}", .{cmd}),
    }
}

fn clearDevices(hwnd: win32.HWND) void {
    var buf: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    for ([_][]const u16{
        win32.L("\\AudioSwitch\\device1.txt"),
        win32.L("\\AudioSwitch\\device2.txt"),
    }) |name| {
        const path = appdataPath(&buf, name);
        if (0 != win32.DeleteFileW(path.ptr)) {
            std.log.info("cleared {f}", .{std.unicode.fmtUtf16Le(path)});
        } else {
            const e = win32.GetLastError();
            if (e != win32.ERROR_FILE_NOT_FOUND) msgBoxFmt(
                "delete {f} failed, error={f}",
                .{ std.unicode.fmtUtf16Le(path), e },
            );
        }
    }

    const config = getConfig();
    if (config.device1) |d| global.gpa.free(d);
    if (config.device2) |d| global.gpa.free(d);
    config.device1 = null;
    config.device2 = null;

    // The default no longer matches any configured device; refresh the icon.
    defaultRenderChanged(hwnd);
}

fn leftClick(hwnd: win32.HWND, x: i32, y: i32) void {
    const config = getConfig();
    // 0 or 1 configured: let the user pick the next device instead of toggling.
    const device1 = config.device1 orelse return selectDevice(hwnd, x, y);
    const device2 = config.device2 orelse return selectDevice(hwnd, x, y);

    var err: HResultError = undefined;
    const target: [:0]const u16 = blk: {
        const index = (audio.defaultRenderIndex(&err) catch std.debug.panic("{f}", .{err})) orelse
            break :blk device1;
        const id = audio.devices.items[index].id;
        // device1 -> device2; device2/other/none -> device1
        break :blk if (std.mem.eql(u16, id, device1)) device2 else device1;
    };
    audio.setDefaultRender(target, &err) catch std.debug.panic("{f}", .{err});
}

// Pop a menu of the active devices so the user can fill the next empty config
// slot (device1 first, then device2), saving the choice to disk.
fn selectDevice(hwnd: win32.HWND, x: i32, y: i32) void {
    const config = getConfig();
    const filling_device1 = config.device1 == null;
    // When choosing the second device, show the first checked+grayed so it can't
    // be picked twice.
    const taken: ?[:0]const u16 = if (filling_device1) null else config.device1;

    const menu = win32.CreatePopupMenu() orelse
        win32.panicWin32("CreatePopupMenu", win32.GetLastError());
    defer if (0 == win32.DestroyMenu(menu)) win32.panicWin32("DestroyMenu", win32.GetLastError());

    var active_count: usize = 0;
    for (audio.devices.items, 0..) |dev, i| {
        if (dev.state != win32.DEVICE_STATE_ACTIVE) continue;
        active_count += 1;
        const is_taken = if (taken) |t| std.mem.eql(u16, t, dev.id) else false;
        const flags: win32.MENU_ITEM_FLAGS = if (is_taken) .{ .CHECKED = 1, .GRAYED = 1 } else win32.MF_STRING;
        // Menu id is the device index + 1 (0 is reserved for "dismissed").
        if (0 == win32.AppendMenuW(menu, flags, i + 1, dev.name.ptr))
            win32.panicWin32("AppendMenu(device)", win32.GetLastError());

        var mii = std.mem.zeroes(win32.MENUITEMINFOW);
        mii.cbSize = @sizeOf(win32.MENUITEMINFOW);
        mii.fMask = win32.MIIM_BITMAP;
        mii.hbmpItem = getMenuBitmap(dev.form_factor);
        if (0 == win32.SetMenuItemInfoW(menu, @intCast(i + 1), win32.FALSE, &mii))
            win32.panicWin32("SetMenuItemInfo(device bitmap)", win32.GetLastError());
    }
    if (active_count == 0) {
        std.log.warn("no active devices to choose from", .{});
        return;
    }

    if (0 == win32.SetForegroundWindow(hwnd)) std.log.warn(
        "SetForegroundWindow failed, error={f}",
        .{win32.GetLastError()},
    );
    win32.SetLastError(.NO_ERROR);
    const cmd = win32.TrackPopupMenu(
        menu,
        .{ .RETURNCMD = 1, .NONOTIFY = 1, .RIGHTBUTTON = 1 },
        x,
        y,
        0,
        hwnd,
        null,
    );
    // Capture the error before PostMessageW clobbers it (KB135788 second half).
    const track_error = win32.GetLastError();
    if (0 == win32.PostMessageW(hwnd, win32.WM_NULL, 0, 0))
        win32.panicWin32("PostMessage(WM_NULL)", win32.GetLastError());

    if (cmd == 0) {
        if (track_error != .NO_ERROR) std.log.warn(
            "TrackPopupMenu returned 0, either error or dismissed, error={f}",
            .{track_error},
        );
        return;
    }

    const dev = audio.devices.items[@as(usize, @intCast(cmd)) - 1];
    const slot: []const u16 = if (filling_device1)
        win32.L("\\AudioSwitch\\device1.txt")
    else
        win32.L("\\AudioSwitch\\device2.txt");
    saveDevice(slot, dev.id);
    const id_copy = global.gpa.dupeZ(u16, dev.id) catch |e| oom(e);
    if (filling_device1) {
        config.device1 = id_copy;
    } else {
        config.device2 = id_copy;
    }
    std.log.info("selected device \"{f}\"", .{std.unicode.fmtUtf16Le(dev.name)});
    defaultRenderChanged(hwnd);
}

fn saveDevice(name: []const u16, id: []const u16) void {
    var path_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    const path = appdataPath(&path_buf, name);

    const handle = win32.CreateFileW(
        path.ptr,
        win32.FILE_GENERIC_WRITE,
        .{},
        null,
        win32.CREATE_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE)
        win32.panicWin32("CreateFile(write device)", win32.GetLastError());
    const file: std.fs.File = .{ .handle = handle };
    defer file.close();

    var buf: [512]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&buf, id) catch |e|
        std.debug.panic("device id is not valid UTF-16: {t}", .{e});
    file.writeAll(buf[0..len]) catch |e|
        std.debug.panic("write {f} failed: {t}", .{ std.unicode.fmtUtf16Le(path), e });
    std.log.info("saved {f}", .{std.unicode.fmtUtf16Le(path)});
}

fn defaultRenderChanged(hwnd: win32.HWND) void {
    const config = getConfig();
    const new_icon: Icon = blk: {
        var device: *win32.IMMDevice = undefined;
        {
            const hr = audio.global.enumerator.GetDefaultAudioEndpoint(win32.eRender, win32.eConsole, @ptrCast(&device));
            if (hr == audio.HRESULT_ERROR_NOT_FOUND) break :blk .{ .form_factor = null, .tint = .neutral };
            if (hr.failed) return win32.panicHresult("GetDefaultAudioEndpoint", hr);
        }
        defer _ = device.IUnknown.Release();

        var id_ptr: [*:0]u16 = undefined;
        {
            const hr = device.GetId(@ptrCast(&id_ptr));
            if (hr.failed) return win32.panicHresult("AudioRenderDevice.GetId", hr);
        }
        defer win32.CoTaskMemFree(id_ptr);
        const id = std.mem.span(id_ptr);

        const form_factor: ?audio.FormFactor = if (audio.indexOfId(id)) |i| audio.devices.items[i].form_factor else null;
        const tint: render.Tint = tblk: {
            if (config.device1) |d1| if (std.mem.eql(u16, id, d1)) break :tblk .slot1;
            if (config.device2) |d2| if (std.mem.eql(u16, id, d2)) break :tblk .slot2;
            break :tblk .neutral;
        };
        break :blk .{ .form_factor = form_factor, .tint = tint };
    };
    updateSystrayIcon(hwnd, new_icon);
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

test {
    std.testing.refAllDecls(@This());
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const cimport = @cImport({
    @cInclude("ResourceNames.h");
});

const audio = @import("audio.zig");
const render = @import("render.zig");

const HResultError = @import("win32/HResultError.zig");
const XY = @import("xy.zig").XY;
