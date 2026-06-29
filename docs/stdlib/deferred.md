<!-- GENERATED FILE. Source: tools/stdlib_docs.rb. -->

# Deferred Stdlib Surfaces

> [!WARNING]
> This is the current **planned** CLEAR stdlib design. Full stdlib
> implementation and stabilization are not planned until v0.3. Treat these
> pages as design direction, not as a compatibility promise.


These packages are important, but they should not block the first
self-host stdlib prototype.

## Regex And Scanner

Regex and scanner support are self-host relevant, but they are deferred
for implementation planning because there is not yet a Zig stdlib fallback
we can rely on.

The design direction remains:

- no Ruby-style global match state;
- explicit `Match` values;
- explicit scanner position/matched text;
- unsupported regex constructs fail closed.

## Network

TCP resources exist as intrinsics today, but broad network design is not
self-host critical. Network APIs need package permissions and explicit
`NETWORK_READ` / `NETWORK_WRITE` effects before they become public.

## Crypto, Compression, Archives, HTTP, TLS

These are launch-quality stdlib candidates, not self-host blockers. They
should wait until the core error/effect/capability/package model is
stable enough that we can avoid redesigning them immediately.
