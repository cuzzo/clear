# Shared dimensions for the cleanup-correctness matrix templates
# (loop_cleanup, branch_cleanup, error_cleanup). Loaded by the auto-loader
# but doesn't call FuzzGenerator.register, so it's a no-op as a template
# and just exposes constants/helpers via require_relative.
#
# Adding a new alloc kind here propagates to all three templates. Adding
# a new control-flow shape goes in the relevant template (its dimension
# is template-specific by design).

module CleanupDims
  # What gets allocated. Each kind has different cleanup requirements:
  #   :heap_list           — `MUTABLE v: Int64[]@list = []` ; ArrayList deinit
  #   :heap_string         — `MUTABLE s: String = ""`       ; alloc.free
  #   :frame_string_concat — `s: String = "a" $+ i.toString()` ; frame mark/rewind
  #   :frame_list          — `xs: Int64[] = [i, i+1]`        ; frame mark/rewind
  ALLOC_KINDS = [:heap_list, :heap_string, :frame_string_concat, :frame_list]

  # What ultimately happens to the allocated value. Affects whether the
  # cleanup happens locally (via mark/rewind / scope-end deinit) or whether
  # the value escapes (forcing heap promotion).
  VALUE_DESTS = [:locally_cleaned, :appended_to_outer]

  # Emit the allocation declaration line. `idx_expr` is the Int64
  # expression substituted into the constructor (loops pass "i"; branch /
  # error contexts pass a literal like "1_i64").
  def self.alloc_decl(kind, varname: "v", idx_expr: "1_i64")
    case kind
    when :heap_list
      "MUTABLE #{varname}: Int64[]@list = [];"
    when :heap_string
      "MUTABLE #{varname}: String = \"\";"
    when :frame_string_concat
      "#{varname}: String = \"a\" $+ #{idx_expr}.toString();"
    when :frame_list
      "#{varname}: Int64[] = [#{idx_expr}, #{idx_expr} + 1_i64];"
    end
  end

  # Emit a "use" statement that exercises the allocated value.
  def self.use_stmt(kind, varname: "v", idx_expr: "1_i64")
    case kind
    when :heap_list           then "#{varname}.append(#{idx_expr});"
    when :heap_string         then "#{varname} = #{varname} $+ #{idx_expr}.toString();"
    when :frame_string_concat then "_ = #{varname}.length();"
    when :frame_list          then "_ = #{varname}[0_i64];"
    end
  end

  # Type of the value (for use in struct/list element types).
  def self.value_type(kind)
    case kind
    when :heap_list, :frame_list           then "Int64[]@list"
    when :heap_string, :frame_string_concat then "String"
    end
  end

  def self.outer_list_type(kind)
    case kind
    when :heap_list, :frame_list           then "Int64[][]@list"
    when :heap_string, :frame_string_concat then "String[]@list"
    end
  end

  # The outer collection's element type when value_dest is :appended_to_outer.
  # Outer is always heap; element matches the inner alloc's type.
  def self.outer_decl_for(kind, varname = "outer")
    "MUTABLE #{varname}: #{outer_list_type(kind)} = [];"
  end

  def self.outer_append(kind, outer_var, value_var)
    "#{outer_var}.append(#{value_var});"
  end
end
