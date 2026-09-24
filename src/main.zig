pub const std_os_options: std.Options.OperatingSystem = horizon.default_std_os_options;
pub const panic = horizon.debug.simple_errdisp_panic;
pub const zitrus_options: zitrus.Options = .{
    .stack_size = switch (@import("builtin").mode) {
        else => 32 * 1024, // We'll stack overflow otherwise
        .ReleaseSafe, .ReleaseSmall, .ReleaseFast => null, // Use the kernel-provided stack (4096 bytes in this case)
    },
};

pub fn main() void {
    {
        // This is setting the nfc_1 pin
        var dir = gpio.@"3".direction;
        dir.set(7, .output);
        gpio.@"3".direction = dir;

        var data = gpio.@"3".data;
        data.set(7, false);
        gpio.@"3".data = data;
    }

    const srv = assertResult(ServiceManager.openWithResult());
    defer srv.close();

    const tls = horizon.tls.get();
    const ipc = &tls.ipc;

    assertResult(srv.sendWithResult(.RegisterClient, .{}, .{}));

    var session_port_mapping_buffer: [service_names.len]u32 = undefined;
    var session_port_mapping: std.ArrayList(u32) = .initBuffer(&session_port_mapping_buffer);

    var handles: [1 + service_names.len * 2]horizon.Synchronization = undefined;
    var ports: std.ArrayList(Port.Server) = .initBuffer(@ptrCast(handles[1..][0..service_names.len]));
    defer for (ports.items) |port| port.close();
    var sessions: std.ArrayList(Session.Server) = .initBuffer(@ptrCast(handles[1 + service_names.len ..][0..service_names.len]));
    defer for (sessions.items) |remote| remote.close();

    handles[0] = @bitCast(assertResult(srv.sendWithResult(.EnableNotification, {}, .{})));
    defer handles[0].close();

    for (service_names) |name| ports.appendAssumeCapacity(assertResult(srv.sendWithResult(.RegisterService, .init(name, 1), .{})).wrapped);
    defer for (service_names) |name| assertResult(srv.sendWithResult(.UnregisterService, .embedded(name), .{}));

    var bound_irqs: std.EnumArray(hw.Pin, horizon.Interruptable) = .initFill(.none);
    var bound_irq_mask: std.EnumSet(hw.Pin) = .empty;

    var stop = false;
    var remote_reply: Session.Server = .none;
    var remote_reply_idx: ?u32 = null;
    while (true) {
        if (remote_reply == Session.Server.none) {
            if (stop and sessions.items.len == 0) break;

            ipc.packed_command.header = .none;
        }

        const res = horizon.replyAndReceive(handles[0 .. 1 + ports.items.len + sessions.items.len], remote_reply);
        const last_remote_reply_idx = remote_reply_idx;
        remote_reply, remote_reply_idx = .{ .none, null };

        const idx: usize = if (res.value < 0)
            (if (last_remote_reply_idx) |idx| idx else {
                assertCode(.failure);
                unreachable;
            })
        else
            @intCast(res.value);

        if (!res.code.isSuccess()) switch (res.code) {
            .os_session_closed_by_remote => {
                const closed_remote_idx = idx - remotes_begin;

                _ = sessions.swapRemove(closed_remote_idx).close();
                const port_idx = session_port_mapping.swapRemove(closed_remote_idx);

                const service_set: std.enums.EnumSet(hw.Pin) = .{ .bits = .{ .mask = @truncate(service_pin_access[port_idx].int()) } };
                var it = service_set.iterator();

                while (it.next()) |pin| if (bound_irq_mask.contains(pin)) {
                    defer bound_irqs.set(pin, .none);
                    defer bound_irq_mask.setPresent(pin, false);

                    const int = bound_irqs.get(pin);
                    defer int.close();

                    assertCode(horizon.unbindInterrupt(pin.irq().?, int));
                };
                continue;
            },
            else => assertCode(res.code),
        };

        switch (idx) {
            0 => switch (assertResult(srv.sendWithResult(.ReceiveNotification, {}, .{}))) {
                .must_terminate => stop = true,
                else => {},
            },
            ports_begin...ports_end => {
                const port_idx = idx - ports_begin;
                const port = ports.items[port_idx];

                sessions.appendAssumeCapacity(assertResult(horizon.acceptSession(port)));
                session_port_mapping.appendAssumeCapacity(port_idx);
            },
            remotes_begin...remotes_end => {
                remote_reply_idx = idx;
                const session_idx = idx - remotes_begin;
                remote_reply = sessions.items[session_idx];

                const port_idx = session_port_mapping.items[session_idx];
                const pin_access = service_pin_access[port_idx];

                if (ipc.readRequestId(Gpio.command.Id)) |id| switch (id) {
                    .get_direction => if (ipc.readRequest(Gpio.command.GetDirection)) |req|
                        ipc.writeResponse(Gpio.command.GetDirection, blk: {
                            if ((req.int() & ~pin_access.int()) != 0) break :blk .of(.gpio_permission_denied, .empty);
                            if ((req.int() & ~hw.Pin.configurable.int()) != 0) break :blk .of(.gpio_not_found, .empty);
                            var directions: u32 = 0;

                            if ((req.int() & hw.Pin.gpio2.int()) != 0) {
                                directions |= readMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"2".data)), (req.int() & hw.Pin.gpio2.int()), -5);
                            }

                            if ((req.int() & hw.Pin.gpio3.int()) != 0) {
                                directions |= readMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"3".data)), (req.int() & hw.Pin.gpio3.int()), -10);
                            }

                            break :blk .of(.success, @bitCast(directions));
                        }),
                    .set_direction => if (ipc.readRequest(Gpio.command.SetDirection)) |req|
                        ipc.writeResponse(Gpio.command.SetDirection, blk: {
                            if ((req.mask.int() & ~pin_access.int()) != 0) break :blk .of(.gpio_permission_denied, {});
                            if ((req.mask.int() & ~hw.Pin.configurable.int()) != 0) break :blk .of(.gpio_not_found, {});

                            if ((req.mask.int() & hw.Pin.gpio2.int()) != 0) {
                                writeMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"2".data)), req.value.int(), (req.mask.int() & hw.Pin.gpio2.int()), 5);
                            }

                            if ((req.mask.int() & hw.Pin.gpio3.int()) != 0) {
                                writeMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"3".data)), req.value.int(), (req.mask.int() & hw.Pin.gpio3.int()), 10);
                            }

                            break :blk .of(.success, {});
                        }),
                    .get_interrupt_configuration => if (ipc.readRequest(Gpio.command.GetInterruptConfiguration)) |req|
                        ipc.writeResponse(Gpio.command.GetInterruptConfiguration, blk: {
                            if ((req.int() & ~pin_access.int()) != 0) break :blk .of(.gpio_permission_denied, .empty);
                            if ((req.int() & ~hw.Pin.configurable.int()) != 0) break :blk .of(.gpio_not_found, .empty);
                            var irq_config: u32 = 0;

                            if ((req.int() & hw.Pin.gpio2.int()) != 0) {
                                irq_config |= readMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"2".data)), (req.int() & hw.Pin.gpio2.int()), -13);
                            }

                            if ((req.int() & hw.Pin.gpio3.int()) != 0) {
                                irq_config |= readMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"3".irq_config)), (req.int() & hw.Pin.gpio3.int()), 6);
                            }

                            break :blk .of(.success, @bitCast(irq_config));
                        }),
                    .set_interrupt_configuration => if (ipc.readRequest(Gpio.command.SetInterruptConfiguration)) |req|
                        ipc.writeResponse(Gpio.command.SetInterruptConfiguration, blk: {
                            if ((req.mask.int() & ~pin_access.int()) != 0) break :blk .of(.gpio_permission_denied, {});
                            if ((req.mask.int() & ~hw.Pin.configurable.int()) != 0) break :blk .of(.gpio_not_found, {});

                            if ((req.mask.int() & hw.Pin.gpio2.int()) != 0) {
                                writeMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"2".data)), req.value.int(), (req.mask.int() & hw.Pin.gpio2.int()), 13);
                            }

                            if ((req.mask.int() & hw.Pin.gpio3.int()) != 0) {
                                writeMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"3".irq_config)), req.value.int(), (req.mask.int() & hw.Pin.gpio3.int()), -6);
                            }

                            break :blk .of(.success, {});
                        }),
                    .is_interrupt_enabled => if (ipc.readRequest(Gpio.command.IsInterruptEnabled)) |req|
                        ipc.writeResponse(Gpio.command.IsInterruptEnabled, blk: {
                            if ((req.int() & ~pin_access.int()) != 0) break :blk .of(.gpio_permission_denied, .empty);
                            if ((req.int() & ~hw.Pin.configurable.int()) != 0) break :blk .of(.gpio_not_found, .empty);
                            var irq_config: u32 = 0;

                            if ((req.int() & hw.Pin.gpio2.int()) != 0) {
                                irq_config |= readMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"2".data)), (req.int() & hw.Pin.gpio2.int()), -21);
                            }

                            if ((req.int() & hw.Pin.gpio3.int()) != 0) {
                                irq_config |= readMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"3".irq_config)), (req.int() & hw.Pin.gpio3.int()), -10);
                            }

                            break :blk .of(.success, @bitCast(irq_config));
                        }),
                    .set_interrupt_enabled => if (ipc.readRequest(Gpio.command.SetInterruptEnabled)) |req|
                        ipc.writeResponse(Gpio.command.SetInterruptEnabled, blk: {
                            if ((req.mask.int() & ~pin_access.int()) != 0) break :blk .of(.gpio_permission_denied, {});
                            if ((req.mask.int() & ~hw.Pin.configurable.int()) != 0) break :blk .of(.gpio_not_found, {});

                            if ((req.mask.int() & hw.Pin.gpio2.int()) != 0) {
                                writeMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"2".data)), req.value.int(), (req.mask.int() & hw.Pin.gpio2.int()), 21);
                            }

                            if ((req.mask.int() & hw.Pin.gpio3.int()) != 0) {
                                writeMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"3".irq_config)), req.value.int(), (req.mask.int() & hw.Pin.gpio3.int()), 10);
                            }

                            break :blk .of(.success, {});
                        }),
                    .get_data => if (ipc.readRequest(Gpio.command.GetData)) |req|
                        ipc.writeResponse(Gpio.command.GetData, blk: {
                            if ((req.int() & ~pin_access.int()) != 0) break :blk .of(.gpio_permission_denied, .empty);
                            if ((req.int() & ~hw.Pin.input.int()) != 0) break :blk .of(.gpio_not_found, .empty);
                            var data: u32 = 0;

                            if ((req.int() & hw.Pin.gpio1.int()) != 0) {
                                data |= readMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"1".data)), (req.int() & hw.Pin.gpio1.int()), 0);
                            }

                            if ((req.int() & hw.Pin.gpio2.int()) != 0) {
                                data |= readMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"2".data)), (req.int() & hw.Pin.gpio2.int()), 3);
                            }

                            if ((req.int() & hw.Pin.gpio2_extra.int()) != 0) {
                                data |= readMaskedShifted(u16, @ptrCast(@alignCast(&gpio.@"2".extra)), (req.int() & hw.Pin.gpio2_extra.int()), 5);
                            }

                            if ((req.int() & hw.Pin.gpio3.int()) != 0) {
                                data |= readMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"3".data)), (req.int() & hw.Pin.gpio3.int()), 6);
                            }

                            if ((req.int() & hw.Pin.gpio3_extra.int()) != 0) {
                                data |= readMaskedShifted(u16, @ptrCast(@alignCast(&gpio.@"3".extra)), (req.int() & hw.Pin.gpio3_extra.int()), 18);
                            }
                            break :blk .of(.success, @bitCast(data));
                        }),
                    .set_data => if (ipc.readRequest(Gpio.command.SetData)) |req|
                        ipc.writeResponse(Gpio.command.SetData, blk: {
                            if ((req.mask.int() & ~pin_access.int()) != 0) break :blk .of(.gpio_permission_denied, {});
                            if ((req.mask.int() & ~hw.Pin.output.int()) != 0) break :blk .of(.gpio_not_found, {});

                            if ((req.mask.int() & hw.Pin.gpio2.int()) != 0) {
                                writeMaskedShifted(u32, @ptrCast(@alignCast(&gpio.@"2".data)), req.value.int(), (req.mask.int() & hw.Pin.gpio2.int()), -3);
                            }

                            if ((req.mask.int() & hw.Pin.gpio2_extra.int()) != 0) {
                                writeMaskedShifted(u16, @ptrCast(@alignCast(&gpio.@"2".extra)), req.value.int(), (req.mask.int() & hw.Pin.gpio2_extra.int()), -5);
                            }

                            if ((req.mask.int() & hw.Pin.gpio3.int()) != 0) {
                                writeMaskedShifted(u16, @ptrCast(@alignCast(&gpio.@"3".data)), req.value.int(), (req.mask.int() & hw.Pin.gpio3.int()), -6);
                            }

                            if ((req.mask.int() & hw.Pin.gpio3_extra.int()) != 0) {
                                writeMaskedShifted(u16, @ptrCast(@alignCast(&gpio.@"3".extra)), req.value.int(), (req.mask.int() & hw.Pin.gpio3_extra.int()), -18);
                            }

                            break :blk .of(.success, {});
                        }),
                    .bind_interrupt => if (ipc.readRequest(Gpio.command.BindInterrupt)) |req|
                        ipc.writeResponse(Gpio.command.BindInterrupt, blk: {
                            var bound = false;
                            defer if (!bound) req.int.close();

                            if ((bound_irq_mask.bits.mask & req.mask.int()) != 0) break :blk .of(.gpio_busy, {});
                            if ((req.mask.int() & ~pin_access.int()) != 0) break :blk .of(.gpio_permission_denied, {});

                            const binding: std.EnumSet(hw.Pin) = .{ .bits = .{ .mask = @truncate(req.mask.int()) } };
                            const pin: hw.Pin = @enumFromInt(binding.bits.findFirstSet() orelse break :blk .of(.gpio_not_found, {}));
                            const irq: horizon.Interrupt = pin.irq() orelse break :blk .of(.gpio_not_found, {});

                            assertCode(horizon.bindInterrupt(irq, req.int, req.priority, false));
                            bound = true;
                            bound_irq_mask.setPresent(pin, true);
                            bound_irqs.set(pin, req.int);
                            break :blk .of(.success, {});
                        }),
                    .unbind_interrupt => if (ipc.readRequest(Gpio.command.UnbindInterrupt)) |req|
                        ipc.writeResponse(Gpio.command.UnbindInterrupt, blk: {
                            defer req.int.close();

                            if ((bound_irq_mask.bits.mask & req.mask.int()) == 0) break :blk .of(.gpio_busy, {});
                            if ((req.mask.int() & ~pin_access.int()) != 0) break :blk .of(.gpio_permission_denied, {});
                            const binding: std.EnumSet(hw.Pin) = .{ .bits = .{ .mask = @truncate(req.mask.int()) } };
                            const pin: hw.Pin = @enumFromInt(binding.bits.findFirstSet() orelse break :blk .of(.gpio_not_found, {}));
                            const irq: horizon.Interrupt = pin.irq() orelse break :blk .of(.gpio_not_found, {});

                            assertCode(horizon.unbindInterrupt(irq, req.int));
                            bound_irq_mask.setPresent(pin, false);
                            bound_irqs.get(pin).close();
                            bound_irqs.set(pin, .none);
                            break :blk .of(.success, {});
                        }),
                };
            },
            else => unreachable,
        }
    }
}

fn readMaskedShifted(comptime T: type, ptr: *volatile T, mask: u32, left_shift: i6) u32 {
    return std.math.shl(u32, ptr.*, left_shift) & mask;
}

fn writeMaskedShifted(comptime T: type, ptr: *volatile T, value: u32, mask: u32, left_shift: i6) void {
    const shifted_mask = std.math.shl(u32, mask, left_shift);
    ptr.* = @truncate((ptr.* & ~shifted_mask) | (std.math.shl(u32, value, left_shift) & shifted_mask));
}

const assertResult = ErrorDisplayManager.assertResult;
const assertCode = ErrorDisplayManager.assertCode;

const ports_begin = 1;
const ports_end = 1 + service_names.len - 1;

const remotes_begin = 1 + service_names.len;
const remotes_end = 1 + (service_names.len * 2) - 1;

const service_names: []const []const u8 = &.{ "gpio:CDC", "gpio:MCU", "gpio:HID", "gpio:NWM", "gpio:IR", "gpio:NFC", "gpio:QTM" };
const service_pin_access: []const Gpio.Pin.Mask = &.{
    .init(.{ .headphones_inserted = true, .@"ctr_depop/new_hid" = true }),
    .init(.{ .wifi_mode = true, .mcu = true, .wifi_enable = true }),
    .init(.{ .debug_pad = true, .gyroscope = true, .new_hid_stop = true, .headphones_button = true }),
    .init(.{ .wifi_mode = true, .wifi_enable = true }),
    .init(.{ .@"ctr_depop/new_hid" = true, .ir = true, .new_hid_stop = true, .ir_tx = true, .ir_rx = true }),
    .init(.{ .nfc_0 = true, .nfc_1 = true, .nfc_2 = true }),
    .init(.{ .qtm = true }),
};

const std = @import("std");
const zitrus = @import("zitrus");

const hardware = zitrus.hardware;

const horizon = zitrus.horizon;
const ServiceManager = horizon.ServiceManager;
const ErrorDisplayManager = horizon.ErrorDisplayManager;

const Port = horizon.Port;
const Session = horizon.Session;
const Code = horizon.result.Code;

const hw = zitrus.hardware.gpio;

const Gpio = horizon.services.Gpio;
const gpio = horizon.memory.gpio;
