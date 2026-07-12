# Weak-reference lifecycle matrix for the compiler-used Rc/Arc control blocks.

LR_CELLS = %i[live multiple].product(%i[multiowned shared]).map do |operation, capability|
  { operation: operation, capability: capability }
end
LR_CELLS.concat(%i[struct_field list dead].map { |operation| { operation: operation, capability: :multiowned } })

FuzzGenerator.register(:link_resolve_matrix, cells: LR_CELLS) do |p|
  cap = p[:capability] == :shared ? "@shared" : "@multiowned"
  suffix = p[:capability].to_s
  helpers = ""
  body = case p[:operation]
  when :live
    "strong = Node{ value: 7, text: COPY \"live\" } #{cap}; weak = LINK strong; ASSERT (RESOLVE weak)?.value == 7;"
  when :struct_field
    "strong = Node{ value: 8, text: COPY \"field\" } #{cap}; edge = Edge{ target: LINK strong }; ASSERT (RESOLVE edge.target)?.text == \"field\";"
  when :list
    "strong = Node{ value: 9, text: COPY \"list\" } #{cap}; MUTABLE links: Node@link[]@list = []; links.append(LINK strong); IF links[0] AS weak THEN IF RESOLVE weak AS resolved THEN ASSERT resolved.value == 9; ELSE ASSERT FALSE; END ELSE ASSERT FALSE; END"
  when :multiple
    "strong = Node{ value: 10, text: COPY \"many\" } #{cap}; first = LINK strong; second = LINK strong; ASSERT (RESOLVE first)?.value == 10; ASSERT (RESOLVE second)?.value == 10;"
  when :dead
    helpers = <<~CLEAR
      FN makeDead_#{suffix}() RETURNS !Node@link ->
          strong = Node{ value: 11, text: COPY "dead" } #{cap};
          RETURN LINK strong;
      END
    CLEAR
    "weak = makeDead_#{suffix}(); resolved = RESOLVE weak; value = resolved?.value OR -1_i64; ASSERT value == -1_i64;"
  end

  <<~CLEAR
    STRUCT Node { value: Int64, text: String }
    STRUCT Edge { target: Node@link }
    #{helpers}
    FN main() RETURNS Void ->
        #{body}
        RETURN;
    END
  CLEAR
end
