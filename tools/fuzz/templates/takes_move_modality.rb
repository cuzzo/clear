# Template: ownership-transfer move modality x owning collection shape.
#
# An owning collection/array passed to a `TAKES` parameter must transfer the
# owning container. Implicit move into TAKES is valid CLEAR -- `consume(xs)`
# needs NO explicit `GIVE`. This template exercises every {shape, modality}
# combination as a regression gate against three proven lowering bugs
# (now fixed; cells flipped to :pass):
#
#   #37  @list/@set/@pool/@map via `bare`(implicit) or `COPY` -- mis-lowered
#        as a slice; callsite collection? discriminator routes owning
#        collection args by pointer; COPY of @list -> TAKES routes through
#        CheatLib.dupeValue for an owning ArrayList. (ad7a29bf3 / cf150a29b)
#   #39  dynamic `Int64[]` -> TAKES -- broken with GIVE because the slice
#        path's CopyNode/MoveNode syntax exclusions prevented .items
#        extraction. Exclusions dropped (cf150a29b).
#   #40  nested `Int64[][]@list` -> TAKES -- :list_with_elem_cleanup
#        emitted a mutable `xs.deinit(alloc)` failing on const-bound
#        anytype params; outer deinit @constCast'd (6e9c6463d).
#
# Why the class went undetected: every TAKES-bearing template hardcoded
# `GIVE` as a literal; the move modality was never a fuzz axis. Worse,
# surface_registry.rb's access_gate baseline claims escape_sinks
# :takes_arg/:give_arg coverage -- true only for a struct (Counter) -- so the
# coverage reporter marked the whole takes/give surface covered, masking the
# collection-shape gap (#41). This template is the truthful owner of
# takes_arg/give_arg across collection shapes (registered in
# surface_registry.rb TEMPLATE_COVERAGE).
#
# All cells now :pass. Historical gating (flipping :in_dev -> :pass was the
# regression acceptance test):
#
#   shape\modality   give     bare         copy
#   list/set/pool/map :pass    :in_dev #37  :in_dev #37
#   dynarr            :in_dev  :in_dev      :in_dev   (all #39)
#   nested            :in_dev  :in_dev      :in_dev   (all #40)
#
# CLONE is out of scope (CLONE of a non-RC collection is a distinct
# front-end concern, not the implicit-move-into-TAKES class).

# shape => [prelude, param_type, decl_block, mutate_stmt, consume_body]
TAKES_MOVE_SHAPE_SPECS = {
  list: ["", "Int64[]@list",
         "MUTABLE xs: Int64[]@list = [];", "xs.append(4_i64);",
         "RETURN xs.length();"],
  set: ["", "Int64[]@set",
        "MUTABLE xs: Int64[]@set = [];", "xs.insert(4_i64);",
        "RETURN xs.length();"],
  pool: ["STRUCT It { v: Int64 }\n", "It[8]@pool",
         "MUTABLE xs: It[8]@pool = [];", "_ = xs.insert(It{ v: 4_i64 });",
         "RETURN xs.length();"],
  map: ["", "HashMap<Int64>",
        "MUTABLE xs: HashMap<Int64> = {};", "xs[\"k\"] = 4_i64;",
        "RETURN xs.count();"],
  dynarr: ["", "Int64[]",
           "MUTABLE xs: Int64[] = [];", "xs.append(4_i64);",
           "RETURN xs.length();"],
  nested: ["", "Int64[][]@list",
           "MUTABLE inner: Int64[]@list = [];\n    inner.append(5_i64);\n" \
           "    MUTABLE xs: Int64[][]@list = [];", "xs.append(inner);",
           "RETURN xs.length();"],
}.freeze

TAKES_MOVE_CELLS = TAKES_MOVE_SHAPE_SPECS.keys.flat_map do |shape|
  %i[give bare copy].map do |modality|
    # All cells now :pass. #39 (dynarr give/bare/copy) fixed by extending
    # EscapeAnalysis condition 8 to plain T[], plus dropping the !MoveNode
    # exclusion at 1797/1880, plus wrapping lower_copy's plain-array source
    # in the safe ItemsAccess.
    { shape: shape, modality: modality, expected: :pass }
  end
end

FuzzGenerator.register(:takes_move_modality, cells: TAKES_MOVE_CELLS) do |p|
  prelude, ptype, decl, mutate, body = TAKES_MOVE_SHAPE_SPECS.fetch(p[:shape])

  arg = case p[:modality]
        when :give then "GIVE xs"
        when :copy then "COPY xs"
        when :bare then "xs"
        end

  <<~CHT
    #{prelude}FN consume(TAKES xs: #{ptype}) RETURNS Int64 -> #{body} END

    FN main() RETURNS Void ->
        #{decl}
        #{mutate}
        n: Int64 = consume(#{arg});
        ASSERT n == 1_i64, "takes #{p[:shape]} via #{p[:modality]}";
        RETURN;
    END
  CHT
end
