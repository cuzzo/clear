require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Ownership surface matrix — spec/ownership_surface_matrix_spec.rb
#
# Companion to pipeline_position_matrix_spec.rb for the NON-pipeline ownership
# surface: every owned value KIND x every consuming OPERATION x binding
# CONTEXT.
#
#   KINDS: owned String (call result / concat), built list, struct with owned
#          field, nested struct, union with a String variant, optional owned,
#          map with owned values, @multiowned / @shared handles.
#   OPS:   declare+read, reassign (old value freed), GIVE -> TAKES, COPY
#          independence (mutate one, assert the other unchanged), return,
#          store into a struct field, store into a list, kind-specific
#          destructuring (MATCH AS / EXISTS AS / map index).
#   CONTEXTS (applied to the decl_read + reassign core): top level, IF branch,
#          FOR body, WHILE body, early-RETURN from a loop with the value live,
#          CONTINUE/BREAK paths with the value pending.
#
# Same discipline as the pipeline matrix, two lanes:
#   - compile lane: every cell transpiles clean OR is in KNOWN_FAILURES with
#     its exact code (strict both directions);
#   - discovery: MATRIX_REPORT=1 prints the cell map.
#
# This is a transpile-only matrix. The runtime ownership surface — leaks,
# invalid frees, wrong values — belongs to the fuzz harness, whose cells are
# `FN main` programs that actually execute: `ownership_surface_smoke` and the
# per-sink truthful owners in tools/fuzz/surface_registry.rb cover a strictly
# wider shape x sink product than these cells do.

module OwnershipSurfaceMatrix
  extend self

  PRELUDE = <<~CLEAR
    STRUCT Person { name: String, age: Int64 }
    STRUCT Outer { inner: Person, tag: String }
    STRUCT Bag { items: String[] }
    UNION Val { None, Str: String }

    FN dup(s: String) RETURNS String ->
        RETURN COPY s;
    END
  CLEAR

  # Each kind: make (expression producing the value), ty, obs (exact-value
  # assertion for a binding named by the argument), sink (TAKES fn body added
  # to the prelude when used), plus optional per-kind capabilities.
  KINDS = {
    "owned_str" => {
      ty: "String", make: "dup(\"ab\")", make2: "dup(\"xyz\")",
      obs: ->(v) { "ASSERT #{v} == \"ab\", \"#{v} exact\";" },
      obs2: ->(v) { "ASSERT #{v} == \"xyz\", \"#{v} exact2\";" },
    },
    "concat_str" => {
      ty: "String", make: "\"a\" $+ \"bc\"", make2: "\"x\" $+ \"y\"",
      obs: ->(v) { "ASSERT #{v} == \"abc\", \"#{v} exact\";" },
      obs2: ->(v) { "ASSERT #{v} == \"xy\", \"#{v} exact2\";" },
    },
    "built_list" => {
      ty: "String[]", make: :list_build, make2: :list_build2,
      obs: ->(v) { "ASSERT (#{v}).join(\"-\") == \"a-bc\", \"#{v} exact\";" },
      obs2: ->(v) { "ASSERT (#{v}).join(\"-\") == \"z\", \"#{v} exact2\";" },
    },
    "struct_owned" => {
      ty: "Person", make: "Person{ name: dup(\"ann\"), age: 3 }", make2: "Person{ name: dup(\"bo\"), age: 4 }",
      obs: ->(v) { "ASSERT #{v}.name == \"ann\", \"#{v} exact\";\n    ASSERT #{v}.age == 3_i64, \"#{v} age\";" },
      obs2: ->(v) { "ASSERT #{v}.name == \"bo\", \"#{v} exact2\";" },
    },
    "nested_struct" => {
      ty: "Outer", make: "Outer{ inner: Person{ name: dup(\"in\"), age: 1 }, tag: dup(\"t\") }",
      make2: "Outer{ inner: Person{ name: dup(\"in2\"), age: 2 }, tag: dup(\"u\") }",
      obs: ->(v) { "ASSERT #{v}.inner.name == \"in\", \"#{v} exact\";\n    ASSERT #{v}.tag == \"t\", \"#{v} tag\";" },
      obs2: ->(v) { "ASSERT #{v}.inner.name == \"in2\", \"#{v} exact2\";" },
    },
    "union_str" => {
      ty: "Val", make: "Val{ Str: dup(\"uv\") }", make2: "Val{ Str: dup(\"uw\") }",
      obs: ->(v) { "PARTIAL MATCH #{v} START Val.Str AS s -> ASSERT s == \"uv\", \"#{v} exact\";, DEFAULT -> ASSERT FALSE, \"#{v} wrong variant\"; END" },
      obs2: ->(v) { "PARTIAL MATCH #{v} START Val.Str AS s -> ASSERT s == \"uw\", \"#{v} exact2\";, DEFAULT -> ASSERT FALSE, \"#{v} wrong variant2\"; END" },
    },
    "map_owned" => {
      ty: "{String}String", make: :map_build, make2: :map_build2,
      obs: ->(v) { "IF #{v}[\"k\"] EXISTS AS got THEN\n      ASSERT got == \"vv\", \"#{v} exact\";\n    ELSE\n      ASSERT FALSE, \"#{v} missing key\";\n    END" },
      obs2: ->(v) { "IF #{v}[\"k\"] EXISTS AS got THEN\n      ASSERT got == \"ww\", \"#{v} exact2\";\n    ELSE\n      ASSERT FALSE, \"#{v} missing key2\";\n    END" },
    },
    "rc_struct" => {
      ty: "Person", make: "Person{ name: dup(\"rc\"), age: 5 } @multiowned", make2: "Person{ name: dup(\"rc2\"), age: 6 } @multiowned",
      obs: ->(v) { "ASSERT #{v}.name == \"rc\", \"#{v} exact\";" },
      obs2: ->(v) { "ASSERT #{v}.name == \"rc2\", \"#{v} exact2\";" },
    },
    "shared_struct" => {
      ty: "Person", make: "Person{ name: dup(\"sh\"), age: 7 } @shared", make2: "Person{ name: dup(\"sh2\"), age: 8 } @shared",
      obs: ->(v) { "ASSERT #{v}.name == \"sh\", \"#{v} exact\";" },
      obs2: ->(v) { "ASSERT #{v}.name == \"sh2\", \"#{v} exact2\";" },
    },
  }.freeze

  # Multi-statement makers (bound to the given name, MUTABLE when mut).
  def make_stmts(kind_name, kind, var, which: :make, mut: false)
    maker = kind[which]
    always_mut = [:list_build, :list_build2, :map_build, :map_build2].include?(maker)
    kw = (mut || always_mut) ? "MUTABLE " : ""
    case maker
    when :list_build
      "#{kw}#{var}: String[] = List[];\n    &#{var}.push(dup(\"a\"));\n    &#{var}.push(dup(\"bc\"));"
    when :list_build2
      "#{kw}#{var}: String[] = List[];\n    &#{var}.push(dup(\"z\"));"
    when :map_build
      "#{kw}#{var}: {String}String = {};\n    #{var}[\"k\"] = dup(\"vv\");"
    when :map_build2
      "#{kw}#{var}: {String}String = {};\n    #{var}[\"k\"] = dup(\"ww\");"
    else
      "#{kw}#{var}: #{kind[:ty]} = #{maker};"
    end
  end

  # Reassign the existing binding to the make2 value (maps/lists rebuild).
  def reassign_stmts(kind, var)
    case kind[:make2]
    when :list_build2
      "#{var} = List[];\n    &#{var}.push(dup(\"z\"));"
    when :map_build2
      "#{var} = {};\n    #{var}[\"k\"] = dup(\"ww\");"
    else
      "#{var} = #{kind[:make2]};"
    end
  end

  # ---- operations ---------------------------------------------------------
  # Each op yields the body of `FN t() RETURNS Void` (called from a TEST).
  # nil => op not applicable to the kind.
  def op_body(op, kind_name, kind)
    case op
    when "decl_read"
      "#{make_stmts(kind_name, kind, 'v')}\n    #{kind[:obs].call('v')}"
    when "reassign"
      "#{make_stmts(kind_name, kind, 'v', mut: true)}\n    #{reassign_stmts(kind, 'v')}\n    #{kind[:obs2].call('v')}"
    when "give_takes"
      return nil if %w[rc_struct shared_struct].include?(kind_name) # bare handle into TAKES is rejected by carrier rules (RETAINED_NEEDS_OWN_COPY) by design
      # sink defined per kind in program(); moves the value out.
      "#{make_stmts(kind_name, kind, 'v')}\n    sink#{kind_name}(GIVE v);"
    when "copy_independent"
      return nil if %w[rc_struct shared_struct].include?(kind_name) # COPY of handles is its own carrier ruleset
      "#{make_stmts(kind_name, kind, 'v')}\n    c = COPY v;\n    #{kind[:obs].call('c')}\n    #{kind[:obs].call('v')}"
    when "ret"
      return nil if %w[rc_struct shared_struct].include?(kind_name) # RETURNS Person cannot carry the handle; carrier-typed returns are the carrier specs' surface
      # mk fn defined per kind in program()
      "r = mk#{kind_name}();\n    #{kind[:obs].call('r')}"
    when "elem_store"
      return nil unless %w[owned_str concat_str struct_owned].include?(kind_name)
      inner = make_stmts(kind_name, kind, 'e')
      obs = kind_name == "struct_owned" ?
        "IF box[0] EXISTS AS got THEN\n      ASSERT got.name == \"ann\", \"elem exact\";\n    ELSE\n      ASSERT FALSE, \"elem missing\";\n    END" :
        "IF box[0] EXISTS AS got THEN\n      ASSERT got.length() >= 2_i64, \"elem read\";\n    ELSE\n      ASSERT FALSE, \"elem missing\";\n    END"
      "MUTABLE box: #{kind[:ty]}[] = List[];\n    #{inner}\n    &box.push(GIVE e);\n    #{obs}"
    when "field_store"
      return nil unless kind_name == "built_list"
      "#{make_stmts(kind_name, kind, 'e')}\n    b = Bag{ items: GIVE e };\n    ASSERT (b.items).join(\"-\") == \"a-bc\", \"field exact\";"
    end
  end

  OPS = %w[decl_read reassign give_takes copy_independent ret elem_store field_store].freeze

  # ---- contexts (applied to decl_read + reassign for every kind) ----------
  CONTEXTS = {
    "top"      => ->(body) { body },
    "in_if"    => ->(body) { "IF 1_i64 > 0_i64 THEN\n    #{body}\n    END" },
    "in_for"   => ->(body) { "FOR i IN (1_i64..=2_i64) DO\n    #{body}\n    END" },
    "in_while" => ->(body) { "MUTABLE w: Int64 = 0_i64;\n    WHILE w < 2_i64 DO\n    #{body}\n    w = w + 1_i64;\n    END" },
    "continue_path" => ->(body) { "FOR i IN (1_i64..=3_i64) DO\n    #{body}\n    IF i == 2_i64 THEN\n      CONTINUE;\n    END\n    END" },
    "break_path"    => ->(body) { "FOR i IN (1_i64..=3_i64) DO\n    #{body}\n    IF i == 2_i64 THEN\n      BREAK;\n    END\n    END" },
  }.freeze

  Cell = Struct.new(:id, :op, :kind_name, :ctx) do
    def program
      kind = KINDS.fetch(kind_name)
      body = OwnershipSurfaceMatrix.op_body(op, kind_name, kind)
      return nil unless body

      body = CONTEXTS.fetch(ctx).call(body)
      extras = +""
      if op == "give_takes"
        extras << "FN sink#{kind_name}(TAKES v: #{kind[:ty]}) RETURNS Void ->\n    #{kind[:obs].call('v')}\n    RETURN;\nEND\n\n"
      end
      if op == "ret"
        mk = OwnershipSurfaceMatrix.make_stmts(kind_name, kind, 'out')
        extras << "FN mk#{kind_name}() RETURNS #{kind[:ty]} ->\n    #{mk}\n    RETURN out;\nEND\n\n"
      end
      <<~CLEAR
        #{PRELUDE}
        #{extras}FN t() RETURNS Void ->
            #{body}
            RETURN;
        END

        TEST Surface DO
            t();
        END
      CLEAR
    end
  end

  def cells
    out = []
    OPS.each do |op|
      KINDS.each do |kind_name, kind|
        ctxs = %w[decl_read reassign].include?(op) ? CONTEXTS.keys : ["top"]
        ctxs.each do |ctx|
          cell = Cell.new("#{kind_name}/#{op}/#{ctx}", op, kind_name, ctx)
          out << cell unless cell.program.nil?
        end
      end
    end
    out
  end

  def check(cell)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(
      cell.program, source_dir: Dir.pwd, ownership_mode: :default
    )
    nil
  rescue StandardError => e
    e.message[/\[([A-Z_0-9]+)\]/, 1] ||
      e.message.gsub(/\e\[[0-9;]*m/, "").lines.map(&:strip).reject(&:empty?).first.to_s[0, 80].rstrip
  end
end

RSpec.describe "Ownership surface matrix" do
  KNOWN_FAILURES = {
    # --- filled by discovery; see MATRIX_REPORT=1 ---
  }.freeze

  if ENV["MATRIX_REPORT"]
    it "reports every cell (discovery mode)" do
      OwnershipSurfaceMatrix.cells.each do |cell|
        err = OwnershipSurfaceMatrix.check(cell)
        puts format("%-45s %s", cell.id, err || "ok")
      end
    end
  else
    OwnershipSurfaceMatrix.cells.each do |cell|
      expected = KNOWN_FAILURES[cell.id]
      it "#{cell.id}#{expected ? " (known: #{expected})" : ""}" do
        err = OwnershipSurfaceMatrix.check(cell)
        if expected
          expect(err).to eq(expected),
            err.nil? ? "cell now PASSES — remove '#{cell.id}' from KNOWN_FAILURES" :
                       "expected #{expected}, got #{err}"
        else
          expect(err).to be_nil, "cell regressed: #{err}\n---\n#{cell.program}"
        end
      end
    end
  end
end
