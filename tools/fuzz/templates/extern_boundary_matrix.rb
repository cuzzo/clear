# Template: EXTERN declaration and call lowering boundaries.
#
# The native modules intentionally do not exist in the fuzz output directory,
# so these are negative cells. They still exercise parser, annotator, and MIR
# lowering through extern signatures, type declarations, trampolines, methods,
# generic/comptime params, and tight-loop admission.

EXTERN_BOUNDARY_CELLS = [
  { shape: :safe_free_fn, expected: :compile_error },
  { shape: :trampoline_free_fn, expected: :compile_error },
  { shape: :extern_struct_method, expected: :compile_error },
  { shape: :extern_resource_close, expected: :compile_error },
  { shape: :generic_comptime_fn, expected: :compile_error },
  { shape: :tight_loop_reject, expected: :compile_error },
].freeze

FuzzGenerator.register(:extern_boundary_matrix, cells: EXTERN_BOUNDARY_CELLS) do |p|
  case p[:shape]
  when :safe_free_fn
    <<~CHT
      EXTERN FN fast_add(a: Float64, b: Float64) RETURNS Float64 EFFECTS :safe FROM "native_math";

      FN main() RETURNS Void ->
        v = fast_add(1.0, 2.0);
        ASSERT v >= 0.0, "extern safe";
        RETURN;
      END
    CHT

  when :trampoline_free_fn
    <<~CHT
      EXTERN FN native_add(a: Float64, b: Float64) RETURNS Float64 FROM "native_math";

      FN main() RETURNS Void ->
        v = native_add(1.0, 2.0);
        ASSERT v >= 0.0, "extern trampoline";
        RETURN;
      END
    CHT

  when :extern_struct_method
    <<~CHT
      EXTERN STRUCT Dir {} FROM "std.fs";
      EXTERN FN cwd() RETURNS Dir FROM "std.fs";
      EXTERN FN Dir.makePath(self: Dir, path: String) RETURNS !Void FROM "std.fs";

      FN main() RETURNS !Void ->
        d = cwd();
        d.makePath("tmp") OR RAISE;
        RETURN;
      END
    CHT

  when :extern_resource_close
    <<~CHT
      EXTERN STRUCT Buffer { data: String } CLOSE "deinit" FROM "native_resource";
      EXTERN FN createBuffer(content: String) RETURNS Buffer FROM "native_resource";
      EXTERN FN bufferLength(buf: Buffer) RETURNS Int64 EFFECTS :safe FROM "native_resource";

      FN main() RETURNS Void ->
        b = createBuffer("abc");
        ASSERT bufferLength(b) >= 0_i64, "extern resource";
        RETURN;
      END
    CHT

  when :generic_comptime_fn
    <<~CHT
      EXTERN STRUCT Parsed {} FROM "std.json";
      EXTERN FN parseFromSlice<T>(comptime: T, content: String) RETURNS !Parsed EFFECTS :alloc:heap FROM "std.json";

      FN main() RETURNS !Void ->
        parsed = parseFromSlice(Parsed, "{}") OR RAISE;
        RETURN;
      END
    CHT

  when :tight_loop_reject
    <<~CHT
      EXTERN FN native_sqrt(x: Float64) RETURNS Float64 FROM "math";

      FN main() RETURNS Void ->
        LOOP TIGHT 4 DO
          _ = native_sqrt(4.0);
        END
        RETURN;
      END
    CHT
  end
end
