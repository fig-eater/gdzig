const SimpleNode = @This();

base: *Node2D,
t: f64 = 0,

pub fn init(base: *Node2D) SimpleNode {
    std.log.info("init {s}", .{@typeName(SimpleNode)});

    return .{ .base = base };
}

pub fn deinit(self: *SimpleNode) void {
    std.log.info("deinit {s}", .{@typeName(@TypeOf(self))});
}

pub fn _enterTree(_: *SimpleNode) void {
    std.log.info("enter tree!!", .{});
}

pub fn _process(self: *SimpleNode, dt: f64) void {
    // std.log.info("process!!", .{});
    self.t += dt;
    if (self.t > std.math.tau) {
        self.t -= std.math.tau;
    }
    self.base.setPosition(.initXY((std.math.cos(self.t) * 32.0) + 200, (std.math.sin(self.t) * 32.0) + 200));
}

const std = @import("std");

const godot = @import("gdzig");
const Node2D = godot.class.Node2D;
