//! structures to help with the creation of pipelines attached to processors.

const std = @import("std");

pub fn buildPipeline(provider: anytype) PipelineBuilder(@TypeOf(provider)) {
    return .init(provider);
}

pub fn PipelineBuilder(comptime ProviderT: type) type {
    const ProviderContainer = switch (@typeInfo(ProviderT)) {
        .pointer => |ptr_info| ptr_info.child,
        else => ProviderT,
    };
    const registerProcessor = if (@hasDecl(ProviderContainer, "registerReader")) ProviderContainer.registerReader else ProviderContainer.registerProcessor;
    return union(enum) {
        const Self = @This();
        const ProviderType = ProviderT;

        provider: ProviderType,
        invalid: anyerror,

        pub fn init(provider: ProviderType) Self {
            return .{
                .provider = provider,
            };
        }

        /// Connect a processor / reader to the provider.
        pub fn with(self: Self, link: anytype) Self {
            return self.withCaptured(link, null);
        }

        /// Connect a processor / reader and capture a pointer to the concrete type.
        ///
        /// This is meant for testing, to allow interacting with the processor to create specific scenarios.
        pub fn withCaptured(self: Self, link: anytype, ptr: ?**@TypeOf(link).ConcreteType) Self {
            switch (self) {
                .provider => |provider| {
                    const LinkType = @TypeOf(link);

                    // Inject provider's resource into the step config if the config
                    // has a `resource` field and the provider has one. This ensures
                    // processors see the correct resource without callers having to
                    // duplicate it in their BatchConfig.
                    var configured_link = link;
                    if (comptime @hasDecl(LinkType, "ContextType") and @hasField(LinkType.ContextType, "resource") and @hasField(ProviderContainer, "resource")) {
                        configured_link.context.resource = provider.resource;
                    }

                    const processor_raw = configured_link.make(provider.allocator) catch |e| return .{ .invalid = e };
                    const processor_interface = LinkType.convertFn(processor_raw);

                    registerProcessor(provider, processor_interface) catch |e| {
                        if (@hasDecl(LinkType.ConcreteType, "deinit")) processor_raw.deinit();
                        provider.allocator.destroy(processor_raw);
                        return .{ .invalid = e };
                    };

                    if (ptr) |captured| {
                        captured.* = processor_raw;
                    }

                    return .{ .provider = provider };
                },
                .invalid => |e| return .{ .invalid = e },
            }
        }

        /// executed all the `with*` links and capture and pointers needed.
        pub fn done(self: Self) !void {
            return switch (self) {
                .provider => {},
                .invalid => |e| e,
            };
        }
    };
}

/// Instructions for how to create a step in a pipeline.
///
/// ConcreteT is a concrete processor or reader type, not an interface to a type.
/// InterfaceT is is the SDK interface the type implements (what the user of the pipeline will interact with)
/// ContextT is the type passed as context for the initFunc closure.
/// convertFunc must have the signature `fn(*ConcreteT) InterfaceT`
/// initFunc must have the signature `fn (*ConcreteT, ContextT, allocator) !void`
/// connectFunc must have the signature `fn (*ConcreteT, TailT.InterfaceType) !void`
pub fn PipelineStepInstructions(
    comptime ConcreteT: type,
    comptime InterfaceT: type,
    comptime ContextT: type,
    comptime ConvertFunc: anytype,
    comptime InitFunc: anytype,
    comptime ConnectFunc: anytype,
) type {
    return struct {
        const Self = @This();
        pub const ConcreteType = ConcreteT;
        pub const InterfaceType = InterfaceT;
        pub const ContextType = ContextT;
        pub const convertFn = ConvertFunc;
        pub const initFn = InitFunc;
        pub const connectFn = ConnectFunc;

        context: ContextType,

        pub fn init(ctx: ContextType) Self {
            return .{ .context = ctx };
        }

        pub fn make(self: Self, allocator: std.mem.Allocator) !*ConcreteType {
            const head_ptr = try allocator.create(ConcreteType);
            errdefer allocator.destroy(head_ptr);
            try initFn(head_ptr, self.context, allocator);
            errdefer if (@hasDecl(ConcreteType, "deinit")) head_ptr.deinit() else {};
            return head_ptr;
        }

        pub fn make_internal(self: Self, ptr: *ConcreteType, allocator: std.mem.Allocator) !void {
            try initFn(ptr, self.context, allocator);
        }

        pub fn flowTo(self: Self, next_step: anytype) PipelineStepLink(Self, @TypeOf(next_step), Self.connectFn) {
            return .init(self, next_step);
        }
    };
}

pub fn PipelineStepLink(comptime HeadT: type, comptime TailT: type, comptime connectFunc: anytype) type {
    return struct {
        const Self = @This();
        pub const ConcreteType = HeadT.ConcreteType;
        pub const InterfaceType = HeadT.InterfaceType;
        pub const convertFn = HeadT.convertFn;

        pub const Head = HeadT;
        pub const Tail = TailT;

        head_step: Head,
        tail_step: Tail,

        pub fn make_internal(self: Self, ptr: *Head.ConcreteType, allocator: std.mem.Allocator) !void {
            try self.head_step.make_internal(ptr, allocator);
        }

        pub fn init(head_step: Head, tail_step: Tail) Self {
            return .{
                .head_step = head_step,
                .tail_step = tail_step,
            };
        }

        pub fn make(self: Self, allocator: std.mem.Allocator) !*Head.ConcreteType {
            const tail_raw = try allocator.create(Tail.ConcreteType);
            errdefer allocator.destroy(tail_raw);
            try self.tail_step.make_internal(tail_raw, allocator);
            errdefer if (@hasDecl(Tail.ConcreteType, "deinit")) tail_raw.deinit() else {};
            const tail_interface = Tail.convertFn(tail_raw);

            const head_raw = try allocator.create(Head.ConcreteType);
            errdefer allocator.destroy(head_raw);
            try self.head_step.make_internal(head_raw, allocator);
            errdefer if (@hasDecl(Head.ConcreteType, "deinit")) head_raw.deinit() else {};
            try connectFunc(head_raw, tail_interface);

            return head_raw;
        }
    };
}

pub fn PipelineDeinitConnection(_: anytype, tail: anytype) !void {
    tail.deinit();
}
