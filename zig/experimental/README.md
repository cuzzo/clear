## Unwinding

```bash
zig test unwind-test.zig unwind.S -lc -lunwind   -O Debug   -fno-strip   -rdynamic   --eh-frame-hdr
```
