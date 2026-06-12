const zig_atleast_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

pub const panic = std.debug.FullPanic(panicHandler);

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

const IconMap = std.AutoArrayHashMapUnmanaged(u16, win32.HICON);
const Config = struct {
    device1: [:0]const u16,
    device2: [:0]const u16,
};

const global = struct {
    var wm_taskbarcreated: u32 = undefined;
    var localappdata: ?[:0]const u16 = null;
    var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_instance.allocator();
    var config: ?Config = null;
    var exe_path_guid: ?win32.Guid = null;
    var retry_timer_set: bool = false;
    var systray_icon_state: ?SystrayIconState = null;
    var last_systray_dpi: ?u32 = null;
    var none_icons: IconMap = .{};
    var speaker_icons: IconMap = .{};
    var headset_icons: IconMap = .{};
    var other_icons: IconMap = .{};
};
const SystrayIconState = struct {
    icon_id: render.IconId,
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
                // TODO: messagebox?
                std.log.info("another instance of Audio Switch is already running, exiting", .{});
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
        if (hr < 0) win32.panicHresult("CoInitializeEx", hr);
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
        if (hr < 0) {
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
        .x = @intCast(win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi)),
        .y = @intCast(win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi)),
    };
    return .{
        .x = @intCast(win32.GetSystemMetrics(win32.SM_CXSMICON)),
        .y = @intCast(win32.GetSystemMetrics(win32.SM_CYSMICON)),
    };
}

fn getGlobalIconsRef(icon_id: render.IconId) *IconMap {
    return switch (icon_id) {
        .none => &global.none_icons,
        .speaker => &global.speaker_icons,
        .headset => &global.headset_icons,
        .other => &global.other_icons,
    };
}

fn getSystrayIcon(icon_id: render.IconId) win32.HICON {
    const icon_size_xy = getSystemSmallIconSize();
    const icons = getGlobalIconsRef(icon_id);
    const min_size = @min(icon_size_xy.x, icon_size_xy.y);

    if (icons.get(min_size)) |icon| return icon;

    std.log.info(
        "rendering {t} icon at {}x{} ({})",
        .{ icon_id, icon_size_xy.x, icon_size_xy.y, min_size },
    );
    const len: usize = @as(usize, min_size) * min_size * 4;
    const pixels = std.heap.page_allocator.alloc(u8, len) catch |e| oom(e);
    defer std.heap.page_allocator.free(pixels);
    @memset(pixels, 0); // start fully transparent

    render.systrayBitmap(pixels, min_size, icon_id);

    const icon = iconFromRgba(pixels, min_size);
    icons.put(std.heap.page_allocator, min_size, icon) catch |e| oom(e);
    return icon;
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

fn updateSystrayIcon3(hwnd: win32.HWND, icon_id: render.IconId) void {
    if (global.systray_icon_state) |*state| {
        if (state.icon_id == icon_id) return;
    }

    const hicon = getSystrayIcon(icon_id);

    if (global.systray_icon_state != null) {
        if (shellNotifySet(.modify, hwnd, hicon)) |err| {
            std.log.err("systray-icon: failed, error={f}", .{err});
        } else {
            std.log.info("systray-icon: modified ({t})", .{icon_id});
            global.systray_icon_state.?.icon_id = icon_id;
            return;
        }
    }

    var first_attempt: bool = true;
    while (true) : (first_attempt = false) {
        if (shellNotifySet(.add, hwnd, hicon)) |err| {
            std.log.err("systray-icon: failed, error={f}", .{err});
        } else {
            std.log.info("systray-icon: added ({t})", .{icon_id});
            global.systray_icon_state = .{
                .icon_id = icon_id,
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
fn updateSystrayIcon2(hwnd: win32.HWND, icon_id: render.IconId) void {
    updateSystrayIcon3(hwnd, icon_id);
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

fn updateSystrayIcon(hwnd: win32.HWND, icon_id: render.IconId) void {
    updateSystrayIcon2(hwnd, icon_id);

    if ((global.systray_icon_state != null) and
        (global.systray_icon_state.?.icon_id == icon_id) and
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
    if (global.config == null) {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        if (false) {
            const device1 = openAppDataFile(win32.L("device1"), .{
                .access_mask = std.os.windows.GENERIC_READ,
                .creation = std.os.windows.OPEN_EXISTING,
            }) catch |err| std.debug.panic("OpenFile(appdata/device1) failed with {t}", .{err});
            defer win32.closeHandle(device1);
        }

        // // TODO: read this configuration from disk, hardcoded for now
        global.config = .{
            .device1 = win32.L("{0.0.0.00000000}.{1269d876-e1e5-4457-8797-5907e4f56c68}"),
            .device2 = win32.L("{0.0.0.00000000}.{96c82bfe-9cb4-456f-a1a6-661849f2077a}"),
        };
    }
    return &global.config.?;
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
            if (maybe_action) |action| switch (action) {
                .left => leftClick(),
                .right => {
                    const x = win32.xFromLparam(@bitCast(wparam));
                    const y = win32.yFromLparam(@bitCast(wparam));
                    std.log.err("TODO: show quick menu at {},{}", .{ x, y });
                    win32.PostQuitMessage(0);
                },
            };
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

fn leftClick() void {
    const config = getConfig();
    var err: HResultError = undefined;
    const target: [:0]const u16 = blk: {
        const index = (audio.defaultRenderIndex(&err) catch std.debug.panic("{f}", .{err})) orelse
            break :blk config.device1;
        const id = audio.devices.items[index].id;
        // device1 -> device2; device2/other/none -> device1
        break :blk if (std.mem.eql(u16, id, config.device1)) config.device2 else config.device1;
    };
    audio.setDefaultRender(target, &err) catch std.debug.panic("{f}", .{err});
}

fn defaultRenderChanged(hwnd: win32.HWND) void {
    const config = getConfig();
    const new_icon: render.IconId = blk: {
        var device: *win32.IMMDevice = undefined;
        {
            const hr = audio.global.enumerator.GetDefaultAudioEndpoint(win32.eRender, win32.eConsole, @ptrCast(&device));
            if (hr == win32.E_NOTFOUND) break :blk .none;
            if (hr < 0) return win32.panicHresult("GetDefaultAudioEndpoint", hr);
        }
        defer _ = device.IUnknown.Release();

        var id_ptr: win32.PWSTR = undefined;
        {
            const hr = device.GetId(@ptrCast(&id_ptr));
            if (hr < 0) return win32.panicHresult("AudioRenderDevice.GetId", hr);
        }
        defer win32.CoTaskMemFree(id_ptr);
        const id = std.mem.span(id_ptr);

        if (std.mem.eql(u16, id, config.device1)) break :blk .speaker;
        if (std.mem.eql(u16, id, config.device2)) break :blk .headset;
        break :blk .other;
    };
    updateSystrayIcon(hwnd, new_icon);
}

fn getLocalappdata() [:0]const u16 {
    if (global.localappdata == null) {
        global.localappdata = std.process.getenvW(win32.L("LOCALAPPDATA")) orelse @panic("environment variable LOCALAPPDATA not found");
    }
    return global.localappdata.?;
}

fn openAppDataFile(sub_path: []const u16, opt: std.os.windows.OpenFileOptions) !std.os.windows.HANDLE {
    var path: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const localappdata = getLocalappdata();
    if (localappdata.len + 1 + sub_path.len + 1 > path.len) return error.NameTooLong;
    @memcpy(path[0..localappdata.len], localappdata);
    path[localappdata.len] = '\\';
    @memcpy(path[localappdata.len + 1 ..][0..sub_path.len], sub_path);
    path[localappdata.len + 1 + sub_path.len] = 0;
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    std.log.info("opening '{f}'", .{std.unicode.fmtUtf16Le(path[0 .. localappdata.len + 1 + sub_path.len :0])});
    return std.os.windows.OpenFile(
        path[0 .. localappdata.len + 1 + sub_path.len :0],
        opt,
    );
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
