# Lock-free Slab Allocator

Introduce the Atomic Mailbox (~100 LOC): Remove the magazine ownership flushing logic entirely. Implement an atomic, lock-free free list inside SlabHeader so remote threads can return objects without touching your compat.Mutex.

Here is the targeted structural diff to convert your single-threaded lock approach for cross-thread deallocations into a lock-free atomic mailbox system, matching the core architecture used by mimalloc.

This removes the ensureMagazineOwnership cross-instance locking vulnerability entirely. Instead, if a thread frees an object belonging to a slab owned by a different allocator instance, it uses a lock-free, atomic Compare-And-Swap (CAS) loop to drop it into that slab's mailbox (thread_free). The owning thread then reclaims these objects during its slow-path execution.

The Architectural Transition
Instead of locking an entire foreign allocator instance to return an object, threads now locate the slab header via pointer masking and atomically push the node onto a lock-free stack.

[Remote Thread] ──► [Mask Pointer] ──► Atomic Push ──► [SlabHeader.thread_free Mailbox]
                                                                  │
                                                      (Owning Thread Reclaims)
                                                                  ▼
                                                      [SlabHeader.free_head]
The Code Diff
Diff
--- slab_allocator_original.zig
+++ slab_allocator_atomic_mailbox.zig
@@ -20,11 +20,6 @@
             count: usize = 0,
-            owner: ?*Self = null, // which instance owns these objects
         };
         // Scale magazine size inversely with object size to keep total
         // pre-allocated memory per thread roughly constant (~1 MB).
@@ -41,6 +36,11 @@
             free_head: ?*Node,
+            /// Lock-free mailbox where remote threads push freed objects.
+            /// This shields the allocator from cross-thread lock contention.
+            thread_free: Atomic(?*Node),
             used_count: usize,
             is_full: bool,
             id: u32,
@@ -87,41 +87,22 @@
             return .{
                 .allocator = allocator,
                 .slab_size = slab_size,
             };
         }

         pub fn deinit(self: *Self) void {
             local_alloc_mag = .{};
             local_free_mag = .{};
-            // INTENTIONALLY no flushThreadCache call here. The reset
-            // above already nukes the magazines...

             self.lock.lock();
             defer self.lock.unlock();

             var it = self.partial_slabs;
             while (it) |slab| {
                 const next = slab.next;
                 self.freeSlabMemory(slab);
                 it = next;
             }
@@ -134,29 +115,7 @@
         }

-        /// If the threadlocal magazine belongs to a different instance, flush it.
-        fn ensureMagazineOwnership(self: *Self) void {
-            if (local_alloc_mag.owner != null and local_alloc_mag.owner != self) {
-                // Magazine has objects from a different instance — flush them
-                // back to their owner before we use the magazine.
-                const old_owner = local_alloc_mag.owner.?;
-                old_owner.lock.lock();
-                for (local_alloc_mag.objects[0..local_alloc_mag.count]) |o| {
-                    old_owner.destroyToDepot(o.?);
-                }
-                old_owner.lock.unlock();
-                local_alloc_mag = .{};
-            }
-            if (local_free_mag.owner != null and local_free_mag.owner != self) {
-                const old_owner = local_free_mag.owner.?;
-                old_owner.lock.lock();
-                for (local_free_mag.objects[0..local_free_mag.count]) |o| {
-                    old_owner.destroyToDepot(o.?);
-                }
-                old_owner.lock.unlock();
-                local_free_mag = .{};
-            }
-            local_alloc_mag.owner = self;
-            local_free_mag.owner = self;
-        }
-
         pub fn create(self: *Self) !*T {
-            self.ensureMagazineOwnership();
             // Try local magazine first (no lock!)
             if (local_free_mag.count > 0) {
                 local_free_mag.count -= 1;
                 return local_free_mag.objects[local_free_mag.count].?;
             }

@@ -176,14 +135,28 @@
             self.lock.lock();
             defer self.lock.unlock();

+            // First, harvest items from any slab mailboxes that have received remote frees.
+            // This avoids expanding the heap unnecessarily if items are waiting in the mailboxes.
+            var it = self.partial_slabs;
+            while (it) |slab| : (it = slab.next) {
+                if (slab.thread_free.swap(null, .acquire)) |remote_nodes| {
+                    self.reclaimMailboxNodes(slab, remote_nodes);
+                }
+            }
+            var full_it = self.full_slabs;
+            while (full_it) |slab| : (full_it = slab.next) {
+                if (slab.thread_free.swap(null, .acquire)) |remote_nodes| {
+                    self.reclaimMailboxNodes(slab, remote_nodes);
+                }
+            }
+
             // Refill magazine with a batch
             var refilled: usize = 0;
             while (refilled < MAGAZINE_SIZE) {
                 const obj = self.createFromDepot() catch break;
                 local_alloc_mag.objects[refilled] = obj;
                 refilled += 1;
             }

             if (refilled == 0) {
@@ -237,13 +210,29 @@
         }

+        fn reclaimMailboxNodes(self: *Self, slab: *SlabHeader, nodes: *Node) void {
+            var curr: ?*Node = nodes;
+            while (curr) |node| {
+                const next = node.next;
+                node.next = slab.free_head;
+                slab.free_head = node;
+                std.debug.assert(slab.used_count > 0);
+                slab.used_count -= 1;
+                curr = next;
+            }
+            if (slab.is_full and slab.free_head != null) {
+                self.removeSlab(slab, &self.full_slabs);
+                self.prependSlab(slab, &self.partial_slabs);
+                slab.is_full = false;
+            }
+            if (slab.used_count == 0) {
+                self.empty_slab_count += 1;
+            }
+        }
+
         pub fn destroy(self: *Self, obj: *T) void {
-            self.ensureMagazineOwnership();
             // Try local free magazine first (no lock!)
             if (local_free_mag.count < MAGAZINE_SIZE) {
                 local_free_mag.objects[local_free_mag.count] = obj;
                 local_free_mag.count += 1;
                 return;
             }

@@ -253,10 +242,10 @@
         fn destroySlow(self: *Self, obj: *T) void {
-            self.lock.lock();
-            defer self.lock.unlock();
-
             // Magazine is full — flush all objects back to depot
+            self.lock.lock();
             for (local_free_mag.objects[0..local_free_mag.count]) |o| {
                 self.destroyToDepot(o.?);
             }
-            local_free_mag = .{ .owner = self };
+            self.lock.unlock();
+            local_free_mag = .{};

             self.destroyToDepot(obj);
         }

         fn destroyToDepot(self: *Self, obj: *T) void {
             const ptr_addr = @intFromPtr(obj);
             const mask = ~(self.slab_size - 1);
             const header_addr = ptr_addr & mask;
             const slab = @as(*SlabHeader, @ptrFromInt(header_addr));

+            // If this thread does not own the slab, bypass the lock entirely and
+            // deposit the object into the slab's atomic thread_free mailbox.
+            if (!self.ownsSlab(obj)) {
+                const node: *Node = @ptrCast(@alignCast(obj));
+                var head = slab.thread_free.load(.monotonic);
+                while (true) {
+                    node.next = head;
+                    head = slab.thread_free.compareAndSwap(
+                        head,
+                        node,
+                        .release,
+                        .monotonic,
+                    ) orelse break;
+                }
+                return;
+            }
+
+            self.lock.lock();
+            defer self.lock.unlock();
+
             const node: *Node = @ptrCast(@alignCast(obj));
             node.next = slab.free_head;
             slab.free_head = node;
@@ -298,6 +303,7 @@
             slab.* = .{
                 .prev = null,
                 .next = null,
                 .free_head = null,
+                .thread_free = Atomic(?*Node).init(null),
                 .used_count = 0,
                 .is_full = false,
                 .id = slot_id,
                 .epoch = slot_epoch,
@@ -370,12 +376,6 @@
         pub fn flushThreadCache(self: *Self) void {
             self.lock.lock();
             defer self.lock.unlock();

-            // Only flush if this thread's magazine belongs to this instance.
-            if (local_alloc_mag.owner == self) {
-                for (local_alloc_mag.objects[0..local_alloc_mag.count]) |o| {
-                    self.destroyToDepot(o.?);
-                }
-                local_alloc_mag = .{};
-            }
-            if (local_free_mag.owner == self) {
-                for (local_free_mag.objects[0..local_free_mag.count]) |o| {
-                    self.destroyToDepot(o.?);
-                }
-                local_free_mag = .{};
-            }
+            for (local_alloc_mag.objects[0..local_alloc_mag.count]) |o| {
+                self.destroyToDepot(o.?);
+            }
+            local_alloc_mag = .{};
+            for (local_free_mag.objects[0..local_free_mag.count]) |o| {
+                self.destroyToDepot(o.?);
             }
+            local_free_mag = .{};
         }
Key Highlights of the Changes
SlabHeader.thread_free Mailbox: Added as a lock-free link layer using an atomic head pointer.

Lockless Remote destroy: destroyToDepot uses a self.ownsSlab(obj) check. If a thread determines it is executing a remote free, it avoids grabbing self.lock. Instead, it fires a Compare-And-Swap loop to prepend the node to the slab's atomic thread_free pointer stack.

Owning-Thread Reclaim Strategy: In createSlow, right before processing a batch refill, the owner iterates through its slabs, pops the accumulated mailbox lists atomically via a single swap(null, .acquire) call, and integrates those nodes into the primary free_head chains via reclaimMailboxNodes.

This completely decouples your threads when passing pointers cross-boundary, transforming the scaling properties of your allocator to mirror those of mimalloc and jemalloc.


## Other Areas of Improvement:

1. Implement Zig's Standard mem.Allocator Interface
Currently, your SlabAllocator exposes a custom API:

Code snippet
pub fn create(self: *Self) !*T
pub fn destroy(self: *Self, obj: *T) void
While clean, this locks you out of the entire Zig standard library ecosystem. You cannot pass your allocator to std.ArrayList(T).init(allocator), nor can you use it with std.json, std.fmt, or any library expecting a generic std.mem.Allocator.

adma successfully wraps its internal slab mechanics in the standard interface. You can adapt this for your single-type allocator by writing a tiny shim that verifies the requested size matches @sizeOf(T) and then redirects to your magazine logic.

How to adapt this into your SlabAllocator:
Add an exposed allocator() function that constructs the interface, using type-erased wrapper functions:

Code snippet
pub fn allocator(self: *Self) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        },
    };
}

fn alloc(ctx: *void, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    // Enforce that this allocator only handles its specialized type
    if (len != @sizeOf(T) or ptr_align > @alignOf(T)) return null;

    const obj = self.create() catch return null;
    return @ptrCast(obj);
}

fn resize(ctx: *void, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    // Slabs of fixed-size items cannot be resized
    return new_len == buf.len;
}

fn free(ctx: *void, buf: []u8, buf_align: u8, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const obj: *T = @ptrCast(@alignCast(buf.ptr));
    self.destroy(obj);
}


std.builtin.single_threaded branch ->	If you ever compile this code with -fsingle-threaded, you can bypass the compat.Mutex entirely for an extra performance boost. -> we do!
