comptime {
    godot.registerExtension(Extension, .{ .entry_symbol = "my_extension_init" });
}

// WASM cannot use DebugAllocator in Zig ~0.15
const wasm_allocator: Allocator = godot.engine_allocator;

pub const Extension = struct {
    gpa: if (builtin.os.tag == .emscripten) void else DebugAllocator(.{}),
    allocator: Allocator,

    pub fn create() !*Extension {
        if (builtin.os.tag == .emscripten) {
            const self = try wasm_allocator.create(Extension);
            self.allocator = wasm_allocator;
            return self;
        } else {
            var gpa: DebugAllocator(.{}) = .init;
            const self = try gpa.allocator().create(Extension);
            self.gpa = gpa;
            self.allocator = self.gpa.allocator();
            return self;
        }
    }

    pub fn init(self: *Extension, level: InitializationLevel) void {
        std.log.info("here3!!!", .{});
        if (level == .scene) {
            godot.registerClass(ExampleNode, .{ .userdata = &self.allocator });
            godot.registerMethod(ExampleNode, .onTimeout);
            godot.registerMethod(ExampleNode, .onResized);
            godot.registerMethod(ExampleNode, .onItemFocused);

            godot.registerClass(GuiNode, .{ .userdata = &self.allocator });
            godot.registerMethod(GuiNode, .onPressed);
            godot.registerMethod(GuiNode, .onToggled);

            godot.registerClass(SignalNode, .{ .userdata = &self.allocator });
            godot.registerMethod(SignalNode, .onSignal1);
            godot.registerMethod(SignalNode, .onSignal2);
            godot.registerMethod(SignalNode, .onSignal3);
            godot.registerMethod(SignalNode, .emitSignal1);
            godot.registerMethod(SignalNode, .emitSignal2);
            godot.registerMethod(SignalNode, .emitSignal3);
            godot.registerSignal(SignalNode, SignalNode.Signal1);
            godot.registerSignal(SignalNode, SignalNode.Signal2);
            godot.registerSignal(SignalNode, SignalNode.Signal3);

            godot.registerClass(SpriteNode, .{ .userdata = &self.allocator });
        }
    }

    pub fn destroy(self: *Extension) void {
        std.log.info("here4!!!", .{});
        if (builtin.os.tag == .emscripten) {
            std.heap.wasm_allocator.destroy(self);
        } else {
            var gpa = self.gpa;
            gpa.allocator().destroy(self);
            assert(gpa.deinit() == .ok);
        }
    }
};

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator;
const WasmAllocator = std.heap.WasmAllocator;
const InitializationLevel = godot.InitializationLevel;

const godot = @import("gdzig");
const builtin = @import("builtin");

const ExampleNode = @import("ExampleNode.zig");
const GuiNode = @import("GuiNode.zig");
const SignalNode = @import("SignalNode.zig");
const SpriteNode = @import("SpriteNode.zig");
