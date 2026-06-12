pub const global = struct {
    var notify: ?Notify = null;
    pub var enumerator: *win32.IMMDeviceEnumerator = undefined;
};

pub const Device = struct {
    /// Stable endpoint id (UTF-16, NUL-terminated). The match key for
    /// device-change events; never shown to the user.
    id: [:0]const u16,
    /// Friendly name (UTF-16, NUL-terminated).
    name: [:0]const u16,
};

pub var devices: std.ArrayList(Device) = .empty;

pub fn init(gpa: std.mem.Allocator, notify: Notify, err: *HResultError) error{HResult}!void {
    std.debug.assert(global.notify == null);
    global.notify = notify;

    {
        const hr = win32.CoCreateInstance(
            win32.CLSID_MMDeviceEnumerator,
            null,
            win32.CLSCTX_ALL,
            win32.IID_IMMDeviceEnumerator,
            @ptrCast(&global.enumerator),
        );
        if (hr < 0) return err.set(hr, "CoCreateInstance(MMDeviceEnumerator)");
    }
    {
        const hr = global.enumerator.RegisterEndpointNotificationCallback(&notification_client);
        if (hr < 0) return err.set(hr, "RegisterEndpointNotificationCallback");
    }

    try sync(gpa, err);
}

pub const Notify = struct {
    hwnd: win32.HWND,
    msg: u32,
};

pub fn indexOfId(id: []const u16) ?usize {
    for (devices.items, 0..) |dev, i| {
        if (std.mem.eql(u16, dev.id, id)) return i;
    }
    return null;
}

pub fn defaultRenderIndex(err: *HResultError) error{HResult}!?usize {
    var device: *win32.IMMDevice = undefined;
    {
        const hr = global.enumerator.GetDefaultAudioEndpoint(win32.eRender, win32.eConsole, @ptrCast(&device));
        if (hr == win32.E_NOTFOUND) return null; // no default output device
        if (hr < 0) return err.set(hr, "GetDefaultAudioEndpoint");
    }
    defer _ = device.IUnknown.Release();

    var id_pwsz: ?win32.PWSTR = null;
    {
        const hr = device.GetId(&id_pwsz);
        if (hr < 0) return err.set(hr, "IMMDevice.GetId");
    }
    defer win32.CoTaskMemFree(@ptrCast(id_pwsz));

    return indexOfId(std.mem.span(id_pwsz orelse return null));
}

/// Make `id` the default render (output) endpoint for every role. Uses the
/// undocumented IPolicyConfig interface; there's no public API to set the default.
pub fn setDefaultRender(id: [:0]const u16, err: *HResultError) error{HResult}!void {
    var policy: *IPolicyConfig = undefined;
    {
        const hr = win32.CoCreateInstance(
            &CLSID_PolicyConfigClient,
            null,
            win32.CLSCTX_ALL,
            &IID_IPolicyConfig,
            @ptrCast(&policy),
        );
        if (hr < 0) return err.set(hr, "CoCreateInstance(PolicyConfigClient)");
    }
    defer _ = @as(*const win32.IUnknown, @ptrCast(policy)).Release();

    // for ([_]win32.ERole{ win32.eConsole, win32.eMultimedia, win32.eCommunications }) |role| {
    for ([_]win32.ERole{win32.eConsole}) |role| {
        const hr = policy.SetDefaultEndpoint(id.ptr, role);
        if (hr < 0) return err.set(hr, "IPolicyConfig.SetDefaultEndpoint");
    }
}

// The undocumented IPolicyConfig interface, the only way to set the default audio
// endpoint. Only SetDefaultEndpoint is used, but the preceding vtable slots must be
// present and in order for the layout to line up.
const CLSID_PolicyConfigClient = win32.Guid.initString("870af99c-171d-4f9e-af0d-e63df40c2bc9");
const IID_IPolicyConfig = win32.Guid.initString("f8679f50-850a-41cf-9c72-430f290290c8");
const IPolicyConfig = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        base: win32.IUnknown.VTable,
        GetMixFormat: *const anyopaque,
        GetDeviceFormat: *const anyopaque,
        ResetDeviceFormat: *const anyopaque,
        SetDeviceFormat: *const anyopaque,
        GetProcessingPeriod: *const anyopaque,
        SetProcessingPeriod: *const anyopaque,
        GetShareMode: *const anyopaque,
        SetShareMode: *const anyopaque,
        GetPropertyValue: *const anyopaque,
        SetPropertyValue: *const anyopaque,
        SetDefaultEndpoint: *const fn (
            self: *const IPolicyConfig,
            device_id: [*:0]const u16,
            role: win32.ERole,
        ) callconv(.winapi) win32.HRESULT,
        SetEndpointVisibility: *const anyopaque,
    };
    pub fn SetDefaultEndpoint(self: *const IPolicyConfig, device_id: [*:0]const u16, role: win32.ERole) win32.HRESULT {
        return self.vtable.SetDefaultEndpoint(self, device_id, role);
    }
};

pub fn add(gpa: std.mem.Allocator, id: []const u16, name: []const u16) void {
    if (indexOfId(id) != null) return;
    const id_copy = gpa.dupeZ(u16, id) catch |e| oom(e);
    errdefer gpa.free(id_copy);
    const name_copy = gpa.dupeZ(u16, name) catch |e| oom(e);
    errdefer gpa.free(name_copy);
    devices.append(gpa, .{ .id = id_copy, .name = name_copy }) catch |e| oom(e);
}

pub fn removeById(gpa: std.mem.Allocator, id: []const u16) void {
    const i = indexOfId(id) orelse return;
    const dev = devices.orderedRemove(i);
    gpa.free(dev.id);
    gpa.free(dev.name);
}

pub fn sync(gpa: std.mem.Allocator, err: *HResultError) error{HResult}!void {
    var collection: *win32.IMMDeviceCollection = undefined;
    {
        const hr = global.enumerator.EnumAudioEndpoints(win32.eRender, win32.DEVICE_STATE_ACTIVE, @ptrCast(&collection));
        if (hr < 0) return err.set(hr, "EnumAudioEndpoints");
    }
    defer _ = collection.IUnknown.Release();

    var count: u32 = 0;
    {
        const hr = collection.GetCount(&count);
        if (hr < 0) return err.set(hr, "IMMDeviceCollection.GetCount");
    }

    // Add endpoints not already in the list (addDevice no-ops on a known id).
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var device: *win32.IMMDevice = undefined;
        {
            const hr = collection.Item(i, @ptrCast(&device));
            if (hr < 0) return err.set(hr, "IMMDeviceCollection.Item");
        }
        defer _ = device.IUnknown.Release();
        try addDevice(gpa, device, err);
    }

    // Remove entries whose endpoint is no longer present.
    var di: usize = 0;
    while (di < devices.items.len) {
        if (try collectionContainsId(collection, count, devices.items[di].id, err)) {
            di += 1;
        } else {
            const dev = devices.orderedRemove(di);
            gpa.free(dev.id);
            gpa.free(dev.name);
        }
    }
}

fn collectionContainsId(collection: *win32.IMMDeviceCollection, count: u32, id: []const u16, err: *HResultError) error{HResult}!bool {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var device: *win32.IMMDevice = undefined;
        {
            const hr = collection.Item(i, @ptrCast(&device));
            if (hr < 0) return err.set(hr, "IMMDeviceCollection.Item");
        }
        defer _ = device.IUnknown.Release();

        var id_pwsz: ?win32.PWSTR = null;
        {
            const hr = device.GetId(&id_pwsz);
            if (hr < 0) return err.set(hr, "IMMDevice.GetId");
        }
        defer win32.CoTaskMemFree(@ptrCast(id_pwsz));
        if (std.mem.eql(u16, std.mem.span(id_pwsz orelse continue), id)) return true;
    }
    return false;
}

/// Add a single IMMDevice (by reading its id + friendly name) to the list.
/// Exposed so a device-added event can add just the one new device.
pub fn addDevice(gpa: std.mem.Allocator, device: *win32.IMMDevice, err: *HResultError) error{HResult}!void {
    var id_pwsz: ?win32.PWSTR = null;
    {
        const hr = device.GetId(&id_pwsz);
        if (hr < 0) return err.set(hr, "IMMDevice.GetId");
    }
    defer win32.CoTaskMemFree(@ptrCast(id_pwsz));
    const id = std.mem.span(id_pwsz orelse return);

    var props: *win32.IPropertyStore = undefined;
    {
        const hr = device.OpenPropertyStore(win32.STGM_READ, @ptrCast(&props));
        if (hr < 0) return err.set(hr, "OpenPropertyStore");
    }
    defer _ = props.IUnknown.Release();

    var prop: win32.PROPVARIANT = undefined;
    {
        const hr = props.GetValue(&win32.PKEY_Device_FriendlyName, &prop);
        if (hr < 0) return err.set(hr, "GetValue(FriendlyName)");
    }
    defer {
        const clear_hr = win32.PropVariantClear(&prop);
        if (clear_hr < 0) win32.panicHresult("PropVariantClear", clear_hr);
    }

    const value = &prop.Anonymous.Anonymous;
    const name: []const u16 = if (value.vt == win32.VT_LPWSTR)
        (if (value.Anonymous.pwszVal) |p| std.mem.span(p) else &[_]u16{})
    else
        &[_]u16{};

    add(gpa, id, name);
}

// A process-singleton IMMNotificationClient. Its callbacks run on a COM thread, so
// they only PostMessage to the UI thread (which owns the device list) — they never
// touch the list themselves.
var notification_client: win32.IMMNotificationClient = .{ .vtable = &notification_vtable };
const notification_vtable: win32.IMMNotificationClient.VTable = .{
    .base = .{
        .QueryInterface = nc_QueryInterface,
        .AddRef = nc_AddRef,
        .Release = nc_Release,
    },
    .OnDeviceStateChanged = nc_OnDeviceStateChanged,
    .OnDeviceAdded = nc_OnDeviceAdded,
    .OnDeviceRemoved = nc_OnDeviceRemoved,
    .OnDefaultDeviceChanged = nc_OnDefaultDeviceChanged,
    .OnPropertyValueChanged = nc_OnPropertyValueChanged,
};

pub const ChangeKind = enum(u3) {
    devices,
    default_render_console,
    default_render_media,
    default_render_comms,
    default_capture_console,
    default_capture_media,
    default_capture_comms,
};

fn postChanged(kind: ChangeKind) void {
    if (0 == win32.PostMessageW(global.notify.?.hwnd, global.notify.?.msg, @intFromEnum(kind), 0))
        win32.panicWin32("PostMessage", win32.GetLastError());
}

fn guidEql(a: *const win32.Guid, b: *const win32.Guid) bool {
    return std.mem.eql(u8, &a.Bytes, &b.Bytes);
}

// Singleton with no real reference counting: hand back ourselves for the
// interfaces we actually implement. We still honor the COM contract — reject
// unknown IIDs with E_NOINTERFACE and null out the result — so a conformant
// caller (or a debugging/instrumentation layer) sees correct behavior.
fn nc_QueryInterface(self: *const win32.IUnknown, riid: *const win32.Guid, ppv: **anyopaque) callconv(.winapi) win32.HRESULT {
    if (guidEql(riid, win32.IID_IUnknown) or guidEql(riid, win32.IID_IMMNotificationClient)) {
        ppv.* = @ptrCast(@constCast(self));
        return win32.S_OK;
    }
    // ppv is typed **anyopaque (non-optional), but the contract requires writing
    // NULL on failure; reinterpret to express that.
    @as(*?*anyopaque, @ptrCast(ppv)).* = null;
    return win32.E_NOINTERFACE;
}
fn nc_AddRef(self: *const win32.IUnknown) callconv(.winapi) u32 {
    _ = self;
    return 1;
}
fn nc_Release(self: *const win32.IUnknown) callconv(.winapi) u32 {
    _ = self;
    return 1;
}
fn nc_OnDeviceStateChanged(self: *const win32.IMMNotificationClient, id: ?[*:0]const u16, state: u32) callconv(.winapi) win32.HRESULT {
    _ = self;
    _ = id;
    _ = state;
    postChanged(.devices);
    return win32.S_OK;
}
fn nc_OnDeviceAdded(self: *const win32.IMMNotificationClient, id: ?[*:0]const u16) callconv(.winapi) win32.HRESULT {
    _ = self;
    _ = id;
    postChanged(.devices);
    return win32.S_OK;
}
fn nc_OnDeviceRemoved(self: *const win32.IMMNotificationClient, id: ?[*:0]const u16) callconv(.winapi) win32.HRESULT {
    _ = self;
    _ = id;
    postChanged(.devices);
    return win32.S_OK;
}
fn nc_OnDefaultDeviceChanged(
    self: *const win32.IMMNotificationClient,
    flow: win32.EDataFlow,
    role: win32.ERole,
    id: ?[*:0]const u16,
) callconv(.winapi) win32.HRESULT {
    _ = self;
    _ = id;
    postChanged(switch (flow) {
        .eRender => switch (role) {
            .eConsole => .default_render_console,
            .eMultimedia => .default_render_media,
            .eCommunications => .default_render_comms,
            else => unreachable,
        },
        .eCapture => switch (role) {
            .eConsole => .default_capture_console,
            .eMultimedia => .default_capture_media,
            .eCommunications => .default_capture_comms,
            else => unreachable,
        },
        else => unreachable,
    });
    return win32.S_OK;
}
fn nc_OnPropertyValueChanged(self: *const win32.IMMNotificationClient, id: ?[*:0]const u16, key: win32.PROPERTYKEY) callconv(.winapi) win32.HRESULT {
    _ = self;
    _ = id;
    _ = key;
    return win32.S_OK;
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const win32 = @import("win32").everything;
const HResultError = @import("win32/HResultError.zig");
