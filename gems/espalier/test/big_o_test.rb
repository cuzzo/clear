# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier/big_o_analyzer"
require_relative "../lib/espalier/structural_big_o"
require_relative "../lib/espalier/nil_kill_evidence"

class BigOTest < Minitest::Test
  def test_multiply_complexity
    analyzer = Espalier::BigOAnalyzer.new

    # Basic multiplications
    assert_equal "O(N)", analyzer.send(:multiply_complexity, "O(1)", "O(N)")
    assert_equal "O(N)", analyzer.send(:multiply_complexity, "O(N)", "O(1)")
    assert_equal "O(N^2)", analyzer.send(:multiply_complexity, "O(N)", "O(N)")
    assert_equal "O(N^3)", analyzer.send(:multiply_complexity, "O(N^2)", "O(N)")
    assert_equal "O(N^5)", analyzer.send(:multiply_complexity, "O(N^2)", "O(N^3)")
    assert_equal "O(N^2 log N)", analyzer.send(:multiply_complexity, "O(N log N)", "O(N)")
    assert_equal "O(N^3 log N)", analyzer.send(:multiply_complexity, "O(N^2 log N)", "O(N)")
    assert_equal "O(log N)", analyzer.send(:multiply_complexity, "O(log N)", "O(1)")
    assert_equal "O(2^N)", analyzer.send(:multiply_complexity, "O(2^N)", "O(N)")
    assert_equal "O(N!)", analyzer.send(:multiply_complexity, "O(N!)", "O(N^3)")
  end

  def test_resolve_type_with_nil_kill_evidence
    ivar_types = {
      "@receiver_state" => "ReceiverState",
      "@items" => "Array"
    }

    # Mock NilKillEvidence signatures
    nil_kill = Object.new
    def nil_kill.method_signatures
      {
        "ReceiverState#scopes" => "sig { returns(T::Array[Scope]) }",
        "SemanticAnnotator#receiver_state" => "def receiver_state() -> ReceiverState"
      }
    end

    analyzer = Espalier::BigOAnalyzer.new(
      class_name: "SemanticAnnotator",
      ivar_types: ivar_types,
      nil_kill: nil_kill
    )

    # 1. Resolve 'self'
    assert_equal "SemanticAnnotator", analyzer.send(:resolve_type, "self", 10)

    # 2. Resolve ivar with @
    assert_equal "ReceiverState", analyzer.send(:resolve_type, "@receiver_state", 10)

    # 3. Resolve ivar without @
    assert_equal "Array", analyzer.send(:resolve_type, "items", 10)

    # 4. Resolve method call on self
    assert_equal "ReceiverState", analyzer.send(:resolve_type, "receiver_state", 10)

    # 5. Resolve dotted chain
    assert_equal "Array", analyzer.send(:resolve_type, "receiver_state.scopes", 10)
  end

  def test_analyze_method
    nil_kill_evidence = {
      "10" => { "items" => "Array" }
    }

    analyzer = Espalier::BigOAnalyzer.new(nil_kill_evidence: nil_kill_evidence)

    ast_mock = [
      { type: :call, receiver: "items", method: "sort", line: 10 },
      { type: :loop, line: 11 },
      { type: :callback, line: 12 }
    ]

    result = analyzer.analyze_method("process_items", ast_mock)

    assert_equal "process_items", result[:method]
    assert_equal "O(N log N)", result[:lower_bound_complexity]
    assert_empty result[:unknown_operations]
    assert_equal 1, result[:warnings].size
    assert_match(/Function pointer \/ callback/, result[:warnings].first)
  end

  def test_param_type_drives_sort_by_complexity
    analyzer = Espalier::BigOAnalyzer.new

    result = analyzer.analyze_method(
      "renumber",
      [{ type: :call, receiver: "segments", method: "sort_by", line: 10 }],
      local_types: { "segments" => "T::Array[Segment]" }
    )

    assert_equal "O(N log N)", result[:lower_bound_complexity]
    assert_empty result[:unknown_operations]
  end

  def test_hash_sort_is_n_log_n
    analyzer = Espalier::BigOAnalyzer.new(
      class_name: "Snapshot",
      ivar_types: { "@alloc_kinds" => "Hash" }
    )

    assert_equal "Array", analyzer.send(:resolve_type, "alloc_kinds.map", 10)

    result = analyzer.analyze_method(
      "summary",
      [{ type: :call, receiver: "alloc_kinds", method: "sort", line: 10 }]
    )

    assert_equal "O(N log N)", result[:lower_bound_complexity]
    assert_empty result[:unknown_operations]
  end

  def test_flattened_chain_uses_stdlib_return_type
    analyzer = Espalier::BigOAnalyzer.new(
      class_name: "Snapshot",
      ivar_types: { "@alloc_kinds" => "Hash" }
    )

    result = analyzer.analyze_method(
      "summary",
      [
        { type: :call, receiver: "alloc_kinds", method: "map", line: 10 },
        { type: :call, receiver: "alloc_kinds", method: "join", line: 10 }
      ]
    )

    assert_equal "O(N)", result[:lower_bound_complexity]
    refute_includes result[:unknown_operations], "Hash#join"
  end

  def test_flattened_same_line_chain_uses_accessor_return_type
    nil_kill = Object.new
    def nil_kill.method_signatures
      {}
    end
    def nil_kill.state_types
      { "FunctionCFG" => { "@blocks" => "Array" } }
    end

    analyzer = Espalier::BigOAnalyzer.new(
      class_name: "OwnershipDataflow",
      ivar_types: { "@cfg" => "FunctionCFG" },
      nil_kill: nil_kill
    )

    result = analyzer.analyze_method(
      "analyze!",
      [
        { type: :call, receiver: "cfg", method: "blocks", line: 20 },
        { type: :call, receiver: "cfg", method: "sort_by", line: 20 }
      ]
    )

    assert_equal "O(N log N)", result[:lower_bound_complexity]
    refute_includes result[:unknown_operations], "FunctionCFG#sort_by"

    accessor_result = analyzer.analyze_method(
      "blocks_only",
      [{ type: :call, receiver: "cfg", method: "blocks", line: 20 }]
    )

    assert_equal "O(1)", accessor_result[:lower_bound_complexity]
    refute_includes accessor_result[:unknown_operations], "FunctionCFG#blocks"
  end

  def test_flat_sequential_loop_evidence_does_not_imply_nested_exponent
    analyzer = Espalier::BigOAnalyzer.new

    result = analyzer.analyze_method("sequential_loops", [
      { type: :loop, line: 10 },
      { type: :loop, line: 20 },
      { type: :loop, line: 30 }
    ])

    assert_equal "O(N)", result[:lower_bound_complexity]
  end

  def test_structural_hint_promotes_loop_contained_linear_work
    analyzer = Espalier::BigOAnalyzer.new

    result = analyzer.analyze_method("fixpoint", [
      { type: :loop, line: 10 },
      {
        type: :structural,
        line: 12,
        complexity: "O(N^2)",
        operation: "items.each",
        reason: "linear stdlib call inside loop"
      }
    ])

    assert_equal "O(N^2)", result[:lower_bound_complexity]
    assert_match(/Structural Big-O hint/, result[:warnings].first)
  end

  def test_structural_hint_ranks_super_polynomial_work
    analyzer = Espalier::BigOAnalyzer.new

    result = analyzer.analyze_method("search", [
      { type: :structural, line: 10, complexity: "O(N^4)", operation: "nested", reason: "nested loop containment depth 4" },
      { type: :structural, line: 20, complexity: "O(2^N)", operation: "fib", reason: "multiple recursive branches" },
      { type: :structural, line: 30, complexity: "O(N!)", operation: "permute", reason: "recursive branching over shrinking collection" }
    ])

    assert_equal "O(N!)", result[:lower_bound_complexity]
    assert_equal 3, result[:warnings].size
  end

  def test_space_complexity_calculation
    analyzer = Espalier::BigOAnalyzer.new

    # 1. Default/pure iterative space
    result_default = analyzer.analyze_method("iterative", [
      { type: :loop, line: 10 }
    ])
    assert_equal "O(1)", result_default[:space_complexity]

    # 2. Divide and conquer space
    result_dc = analyzer.analyze_method("binary_search", [
      { type: :structural, line: 10, complexity: "O(log N)", space: "O(log N)", operation: "search" }
    ])
    assert_equal "O(log N)", result_dc[:space_complexity]

    # 3. Linear recursion space
    result_linear = analyzer.analyze_method("factorial", [
      { type: :structural, line: 10, complexity: "O(N)", space: "O(N)", operation: "factorial" }
    ])
    assert_equal "O(N)", result_linear[:space_complexity]
  end

  def test_recursion_detection_types
    require_relative "../lib/espalier/structural_big_o"

    # Mock source cache
    source_cache = {
      "fact.rb" => [
        "def factorial(n)\n",
        "  return 1 if n <= 1\n",
        "  n * factorial(n - 1)\n",
        "end\n"
      ],
      "fib.rb" => [
        "def fib(n)\n",
        "  return n if n <= 1\n",
        "  fib(n - 1) + fib(n - 2)\n",
        "end\n"
      ],
      "dc.rb" => [
        "def bsearch(n)\n",
        "  return if n <= 1\n",
        "  bsearch(n / 2)\n",
        "end\n"
      ],
      "branching_dc.rb" => [
        "def split_search(n)\n",
        "  return if n <= 1\n",
        "  split_search(n / 2)\n",
        "  split_search(n / 2)\n",
        "end\n"
      ],
      "perm.rb" => [
        "def permute(arr)\n",
        "  arr.each do |x|\n",
        "    permute(arr - [x])\n",
        "  end\n",
        "end\n"
      ]
    }

    s = Espalier::StructuralBigO.new(source_cache: source_cache)

    # 1. Linear recursion: factorial(n - 1)
    hints = s.hints_for("fact.rb", { name: "factorial", line: 1, span: [1, 0, 4, 3] }, "Math")
    assert_equal 1, hints.size
    assert_equal "O(N)", hints[0][:complexity]
    assert_equal "O(N)", hints[0][:space]
    assert_equal true, hints[0][:is_dynamic]
    assert_equal "line 1", hints[0][:trigger]

    # Two half-size calls visit a linear number of recursion nodes; classifying
    # this as logarithmic ignores the second branch.
    hints = s.hints_for("branching_dc.rb", { name: "split_search", line: 1, span: [1, 0, 5, 3] }, "Math")
    assert_equal 1, hints.size
    assert_equal "O(N)", hints[0][:complexity]
    assert_equal "O(log N)", hints[0][:space]

    # 2. Exponential recursion: fib(n - 1) + fib(n - 2)
    hints = s.hints_for("fib.rb", { name: "fib", line: 1, span: [1, 0, 4, 3] }, "Math")
    assert_equal 1, hints.size
    assert_equal "O(2^N)", hints[0][:complexity]
    assert_equal "O(N)", hints[0][:space]
    assert_equal true, hints[0][:is_dynamic]
    assert_equal "line 1", hints[0][:trigger]

    # 3. Divide and conquer: bsearch(n / 2)
    hints = s.hints_for("dc.rb", { name: "bsearch", line: 1, span: [1, 0, 4, 3] }, "Math")
    assert_equal 1, hints.size
    assert_equal "O(log N)", hints[0][:complexity]
    assert_equal "O(log N)", hints[0][:space]
    assert_equal true, hints[0][:is_dynamic]
    assert_equal "line 1", hints[0][:trigger]

    # 4. Factorial recursion: permute(arr - [x]) in loop
    hints = s.hints_for("perm.rb", { name: "permute", line: 1, span: [1, 0, 5, 3] }, "Math")
    # Might include both permute (O(N!)) and collection scan / expensive call hints.
    factorial_hint = hints.find { |h| h[:complexity] == "O(N!)" }
    refute_nil factorial_hint
    assert_equal "O(N)", factorial_hint[:space]
    assert_equal true, factorial_hint[:is_dynamic]
    assert_equal "line 1", factorial_hint[:trigger]
  end

  def test_loop_complexity_classification_and_trigger_tracking
    require_relative "../lib/espalier/structural_big_o"

    source_cache = {
      "demo.rb" => [
        "def process(n)\n",
        "  limit = 100\n",
        "  5.times do |i|\n",
        "    (0..limit).each do |j|\n",
        "      (0..n).each do |k|\n",
        "        # nested loops\n",
        "      end\n",
        "    end\n",
        "  end\n",
        "end\n"
      ],
      "demo_const.rb" => [
        "LIMIT = 100\n",
        "def run()\n",
        "  (0..LIMIT).each do |i|\n",
        "    (0..10).each do |j|\n",
        "      # nested\n",
        "    end\n",
        "  end\n",
        "end\n"
      ]
    }

    s = Espalier::StructuralBigO.new(source_cache: source_cache)

    # 1. Test process(n):
    # - 5.times -> static
    # - (0..limit) -> static (limit = 100 constant assignment)
    # - (0..n) -> dynamic (n parameter)
    hints = s.hints_for("demo.rb", { name: "process", line: 1, span: [1, 0, 10, 3] }, "Demo")
    nested_hint = hints.find { |h| h[:complexity] == "O(N^2)" }
    refute_nil nested_hint
    assert_equal true, nested_hint[:is_dynamic]
    assert_equal "line 1", nested_hint[:trigger] # 'n' parameter defined on line 1

    # Check loop classifications manually
    constants = Set.new
    lines = source_cache["demo.rb"]
    c1 = s.send(:classify_loop, "5.times do |i|", 3, 1, lines, constants)
    assert_equal false, c1[:is_dynamic]

    c2 = s.send(:classify_loop, "(0..limit).each do |j|", 4, 1, lines, constants)
    assert_equal false, c2[:is_dynamic]

    c3 = s.send(:classify_loop, "(0..n).each do |k|", 5, 1, lines, constants)
    assert_equal true, c3[:is_dynamic]
    assert_equal "line 1", c3[:trigger]

    # 2. Test demo_const.rb:
    # - LIMIT is defined as a constant
    # - (0..LIMIT).each -> static
    # - (0..10).each -> static
    hints2 = s.hints_for("demo_const.rb", { name: "run", line: 2, span: [2, 0, 8, 3] }, "DemoConst")
    nested_hint2 = hints2.find { |h| h[:complexity] == "O(N^2)" }
    refute_nil nested_hint2
    assert_equal false, nested_hint2[:is_dynamic]
    assert_nil nested_hint2[:trigger]

    # 3. Test Go loops:
    go_lines = [
      "func process(n int) {\n",
      "\tlimit := 10\n",
      "\tfor i := 0; i < limit; i++ {\n",
      "\t\tfor j := 0; j < n; j++ {\n",
      "\t\t\t// nested\n",
      "\t\t}\n",
      "\t}\n",
      "}\n"
    ]
    go_constants = Set.new(["limit"])
    # - Loop 1: i < limit -> static
    g1 = s.send(:classify_loop, "for i := 0; i < limit; i++ {", 3, 1, go_lines, go_constants)
    assert_equal false, g1[:is_dynamic]
    # - Loop 2: j < n -> dynamic
    g2 = s.send(:classify_loop, "for j := 0; j < n; j++ {", 4, 1, go_lines, go_constants)
    assert_equal true, g2[:is_dynamic]
    assert_equal "line 1", g2[:trigger] # parameter 'n' defined on line 1

    source_cache["go_case.go"] = go_lines
    go_hints = s.hints_for(
      "go_case.go",
      { name: "process", line: 1, span: [1, 0, 8, 1] },
      "Go"
    )
    go_nested = go_hints.find { |hint| hint[:complexity] == "O(N^2)" }
    refute_nil go_nested
    assert_equal true, go_nested[:is_dynamic]
    assert_equal "line 1", go_nested[:trigger]

    # 4. Test Rust loops:
    rust_lines = [
      "fn run(items: Vec<i32>) {\n",
      "\tconst LIMIT: usize = 5;\n",
      "\tfor i in 0..LIMIT {\n",
      "\t\tfor item in &items {\n",
      "\t\t\t// nested\n",
      "\t\t}\n",
      "\t}\n",
      "}\n"
    ]
    rust_constants = Set.new(["LIMIT"])
    # - Loop 1: 0..LIMIT -> static
    r1 = s.send(:classify_loop, "for i in 0..LIMIT {", 3, 1, rust_lines, rust_constants)
    assert_equal false, r1[:is_dynamic]
    # - Loop 2: in &items -> dynamic
    r2 = s.send(:classify_loop, "for item in &items {", 4, 1, rust_lines, rust_constants)
    assert_equal true, r2[:is_dynamic]
    assert_equal "line 1", r2[:trigger] # parameter 'items' defined on line 1

    # 5. Test Java/C loops:
    c_lines = [
      "void run(int n) {\n",
      "\tconst int LIMIT = 8;\n",
      "\tfor (int i = 0; i < LIMIT; i++) {\n",
      "\t\tfor (int j = 0; j < n; j++) {\n",
      "\t\t\t// nested\n",
      "\t\t}\n",
      "\t}\n",
      "}\n"
    ]
    c_constants = Set.new(["LIMIT"])
    # - Loop 1: i < LIMIT -> static
    c1 = s.send(:classify_loop, "for (int i = 0; i < LIMIT; i++) {", 3, 1, c_lines, c_constants)
    assert_equal false, c1[:is_dynamic]
    # - Loop 2: j < n -> dynamic
    c2 = s.send(:classify_loop, "for (int j = 0; j < n; j++) {", 4, 1, c_lines, c_constants)
    assert_equal true, c2[:is_dynamic]
    assert_equal "line 1", c2[:trigger] # parameter 'n' defined on line 1
  end

  def test_brace_matching_ignores_braces_in_strings_and_comments
    source_cache = {
      "literal_braces.rb" => [
        "def run(items)\n",
        "  items.each do |x|\n",
        "    if x.trim_end_matches('{') == '}' # comment with {\n",
        "      puts \"{\"\n",
        "    end\n",
        "  end\n",
        "end\n"
      ]
    }
    s = Espalier::StructuralBigO.new(source_cache: source_cache)
    hints = s.hints_for("literal_braces.rb", { name: "run", line: 1, span: [1, 0, 7, 3] }, "LiteralBraces")
    # Should only find the one collection loop (items.each) at depth 1 (O(N)),
    # NOT nested loops or deeper complexity from false brace nesting.
    nested_hint = hints.find { |h| h[:complexity] == "O(N^2)" }
    assert_nil nested_hint
  end

  def test_shrinking_collection_ignores_plain_slice
    source_cache = {
      "plain_slice.rb" => [
        "def walk(node)\n",
        "  return unless node\n",
        "  val = node.slice.to_s\n",
        "  node.child_nodes.each do |child|\n",
        "    walk(child)\n",
        "  end\n",
        "end\n"
      ]
    }
    s = Espalier::StructuralBigO.new(source_cache: source_cache)
    hints = s.hints_for("plain_slice.rb", { name: "walk", line: 1, span: [1, 0, 7, 3] }, "PlainSlice")
    # walk is recursive but does not have a shrinking collection.
    # It should be classified as O(N) (linear recursion fallback), NOT O(N!) (factorial).
    factorial_hint = hints.find { |h| h[:complexity] == "O(N!)" }
    assert_nil factorial_hint
  end

  def test_python_indentation_blocks
    source_cache = {
      "python_loops.py" => [
        "def run():\n",
        "    for i in range(10):\n",
        "        print(i)\n",
        "    for j in range(10):\n",
        "        print(j)\n"
      ]
    }
    s = Espalier::StructuralBigO.new(source_cache: source_cache)
    hints = s.hints_for("python_loops.py", { name: "run", line: 1, span: [1, 0, 5, 0] }, "PythonLoops")
    # Sequential loops in Python should not be treated as nested (maximum depth 1, O(N)).
    nested_hint = hints.find { |h| h[:complexity] == "O(N^2)" }
    assert_nil nested_hint
  end

  def test_exhaustive_big_o_coverage
    analyzer = Espalier::BigOAnalyzer.new

    # 1. Test clean_type_name
    assert_nil analyzer.send(:clean_type_name, nil)
    assert_equal "User", analyzer.send(:clean_type_name, "T.nilable(User)")
    assert_equal "User", analyzer.send(:clean_type_name, "T.any(NilClass, User)")
    assert_equal "User", analyzer.send(:clean_type_name, "T.any(User, nil)")
    assert_equal "User", analyzer.send(:clean_type_name, "T.any(nil, User)")
    assert_equal "Array", analyzer.send(:clean_type_name, "T::Array[User]")
    assert_equal "Hash", analyzer.send(:clean_type_name, "T.Hash[String, Integer]")
    assert_equal "Set", analyzer.send(:clean_type_name, "T.Set[Symbol]")
    assert_equal "Enumerable", analyzer.send(:clean_type_name, "T.Enumerable[Float]")
    assert_equal "User", analyzer.send(:clean_type_name, "User")
    assert_equal "Array", analyzer.send(:clean_type_name, "T.nilable(T::Array[User])")

    # 2. Test complexity_rank
    assert_equal 1, analyzer.send(:complexity_rank, nil)
    assert_equal 1, analyzer.send(:complexity_rank, "O(1)")
    assert_equal 2, analyzer.send(:complexity_rank, "O(log N)")
    assert_equal 10, analyzer.send(:complexity_rank, "O(N)")
    assert_equal 11, analyzer.send(:complexity_rank, "O(N log N)")
    assert_equal 14, analyzer.send(:complexity_rank, "O(N * M)")
    assert_equal 14, analyzer.send(:complexity_rank, "O(N^2)")
    assert_equal 15, analyzer.send(:complexity_rank, "O(N^2 log N)")
    assert_equal 18, analyzer.send(:complexity_rank, "O(N^4)")
    assert_equal 100, analyzer.send(:complexity_rank, "O(2^N)")
    assert_equal 200, analyzer.send(:complexity_rank, "O(N!)")
    assert_equal 1, analyzer.send(:complexity_rank, "O(unknown)")

    # 3. Test space_complexity_rank
    assert_equal 10, analyzer.send(:space_complexity_rank, "O(N)")
    assert_equal 5, analyzer.send(:space_complexity_rank, "O(log N)")
    assert_equal 1, analyzer.send(:space_complexity_rank, "O(1)")
    assert_equal 1, analyzer.send(:space_complexity_rank, "O(unknown)")

    # 4. Test multiply_complexity edge cases
    assert_equal "O(N!)", analyzer.send(:multiply_complexity, "O(N!)", "O(1)")
    assert_equal "O(N!)", analyzer.send(:multiply_complexity, "O(1)", "O(N!)")
    assert_equal "O(2^N)", analyzer.send(:multiply_complexity, "O(2^N)", "O(1)")
    assert_equal "O(2^N)", analyzer.send(:multiply_complexity, "O(1)", "O(2^N)")
    assert_equal "O(log N)", analyzer.send(:multiply_complexity, "O(log N)", "O(log N)")
    assert_equal "O(N^5 log N)", analyzer.send(:multiply_complexity, "O(N^2 log N)", "O(N^3 log N)")
    assert_equal "O(N^2)", analyzer.send(:multiply_complexity, "O(N)", "O(N)")
    assert_equal "O(N^3)", analyzer.send(:multiply_complexity, "O(N^2)", "O(N)")
    assert_equal "O(1)", analyzer.send(:multiply_complexity, "O(1)", "O(1)")

    # 5. Test resolve_type dotted chains & accessor types
    nil_kill = Object.new
    def nil_kill.method_signatures
      { "User#address" => "def address() -> Address" }
    end
    def nil_kill.state_types
      { "Address" => { "@city" => "City" } }
    end
    def nil_kill.respond_to?(method_name)
      method_name == :state_types || super
    end

    analyzer_resolve = Espalier::BigOAnalyzer.new(
      class_name: "User",
      ivar_types: { "@self" => "User" },
      nil_kill: nil_kill
    )
    assert_equal "Address", analyzer_resolve.send(:resolve_type, "self.address", 10)
    assert_equal "City", analyzer_resolve.send(:resolve_type, "self.address.city", 10)

    # 6. Test structural loop ranges and block finishes
    source_cache = {
      "python_case.py" => [
        "for i in range(10):\n",
        "  pass\n",
        "print('done')\n"
      ],
      "brace_case.rb" => [
        "items.each { |x|\n",
        "  puts x\n",
        "}\n"
      ],
      "multiline_comment.rs" => [
        "fn run() {\n",
        "  /* block\n",
        "     comment */\n",
        "  for i in 0..10 {\n",
        "    // line comment\n",
        "    let x = \"string { brace }\";\n",
        "  }\n",
        "}\n"
      ]
    }
    s = Espalier::StructuralBigO.new(source_cache: source_cache)
    
    # Python block finish
    hints_py = s.hints_for("python_case.py", { name: "run", line: 1, span: [1, 0, 3, 0] }, "PythonCase")
    refute_nil hints_py

    # Brace block finish
    hints_brace = s.hints_for("brace_case.rb", { name: "run", line: 1, span: [1, 0, 3, 0] }, "BraceCase")
    refute_nil hints_brace

    # Multiline comment & string literal brace matching
    hints_comment = s.hints_for("multiline_comment.rs", { name: "run", line: 1, span: [1, 0, 8, 0] }, "MultilineComment")
    # Should only find 1 loop at depth 1, no nested loops inside comments/strings
    assert_equal 0, hints_comment.select { |h| h[:complexity] == "O(N^2)" }.size

    # Single-statement loops in C-style languages
    c_single_loops = {
      "single_loop.zig" => [
        "fn test() void {\n",
        "  while (cond)\n",
        "    std.Thread.yield() catch {};\n",
        "  for (0..5) |i| self.run(i);\n",
        "}\n"
      ]
    }
    s_single = Espalier::StructuralBigO.new(source_cache: c_single_loops)
    hints_single = s_single.hints_for("single_loop.zig", { name: "test", line: 1, span: [1, 0, 5, 0] }, "SingleLoop")
    # Neither loop is nested, so no O(N^2) hints should be produced (depth of both is 1)
    assert_equal 0, hints_single.select { |h| h[:complexity] == "O(N^2)" }.size
  end
end
