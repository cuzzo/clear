# Unit guard for the "nested-@list-field append allocator not inherited
# from root container" bug (docs/agents/vm-bugs.md).
#
# The bug class: mir_lowering's allocator resolution and mir_checker's
# container attribution independently walk a receiver to find its root
# container. If they disagree on the root, a nested-field op
# (`root[i].field.append(x)`) resolves :frame while the heap-promoted
# root's AllocMark says :heap -> INLINE_ALLOC_MISMATCH (or, worse, a
# silent use-after-free if the checker is the one that's wrong).
#
# This spec pins the *contract* directly via the checker, so it stays
# valid no matter which promotion path heap-promotes the root or which
# receiver shape is added later: it does NOT hardcode "should be :heap".
# It also asserts the program genuinely exercises the path (a
# nested-field-append InlineZig whose root has a :heap AllocMark), so a
# future lowering change that stops generating that shape can't make
# the guard pass vacuously.

require "rspec"
require "stringio"
require_relative "../src/mir/mir"
require_relative "../src/mir/mir_lowering"
require_relative "../src/mir/mir_checker"
require_relative "../src/ast/ast"
require_relative "../src/backends/importer"
require_relative "../src/backends/compiler_frontend"

RSpec.describe "nested-@list-field append inherits root container allocator" do
  # Loop-spanning @list whose element has a nested @list, mutated via a
  # nested-field append inside a non-tight loop whose body frame-
  # allocates (forces saveLoopMark -> heap-promotes the root).
  SRC = <<~CHT
    STRUCT Handle { values: Int64[]@list }

    FN run(n: Int64) RETURNS !Int64 ->
        MUTABLE handles: Handle[]@list = List[];
        MUTABLE i: Int64 = 0_i64;
        WHILE i < n DO
            MUTABLE scratch: Int64[]@list = List[];
            scratch.append(i);
            handles.append(Handle{ values: [] });
            handles[i].values.append(scratch[0]);
            i = i + 1_i64;
        END
        RETURN length(handles);
    END

    FN main() RETURNS Void ->
        r: Int64 = run(3_i64) OR PASS;
        ASSERT r == 3_i64, "three handles";
        RETURN;
    END
  CHT

  def lower_program(src)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    out, err = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    begin
      fe = CompilerFrontend.compile(src, importer: importer, source_dir: Dir.pwd)
    ensure
      $stdout, $stderr = out, err
    end
    low = MIRLowering.new(
      struct_schemas: fe.struct_schemas,
      enum_schemas: fe.enum_schemas,
      union_schemas: fe.union_schemas,
      fn_sigs: fe.fn_sigs,
      moved_guard_info: fe.moved_guard_info,
      importer: importer,
      source_dir: Dir.pwd
      # Default (Zig) target: this is where INLINE_ALLOC_MISMATCH is
      # checked (on MIR::InlineZig nodes). :bc lowers appends to MIR
      # calls and never exercises verify_inline_alloc_contracts!.
    )
    low.lower_program(fe.ast)
  end

  # Generic structural walk: recurse every Struct member (MIR nodes are
  # Structs) and every Array. No per-shape member list -> the test
  # walker itself can't drift as MIR node shapes change.
  def each_mir(node, seen = {}, &blk)
    return if node.nil?
    return if seen[node.object_id]
    seen[node.object_id] = true
    if node.is_a?(Array)
      node.each { |c| each_mir(c, seen, &blk) }
      return
    end
    return unless node.is_a?(Struct) && node.class.name.to_s.start_with?("MIR::")
    blk.call(node)
    node.members.each { |m| each_mir(node[m], seen, &blk) }
  end

  let(:program) { lower_program(SRC) }

  it "lowers a nested-field append whose root has a :heap AllocMark (path is exercised)" do
    alloc_marks = {}
    inline_targeting_handles = []
    each_mir(program) do |n|
      alloc_marks[n.name] = n if n.is_a?(MIR::AllocMark)
      if n.is_a?(MIR::InlineZig) && n.respond_to?(:target_var) && n.target_var == "handles"
        inline_targeting_handles << n
      end
    end
    expect(alloc_marks["handles"]).not_to be_nil
    expect(alloc_marks["handles"].alloc).to eq(:heap),
      "root container must be heap-promoted by the loop rewind for this guard to be meaningful"
    # The nested-field append `handles[i].values.append(...)` is an
    # InlineZig whose target_var resolves (via root_receiver_node) to
    # the root "handles" -- proves we're exercising the bug path.
    expect(inline_targeting_handles.any? { |iz| iz.allocs&.key?(:alloc) }).to be(true)
  end

  it "resolves every handles-targeting op to the same allocator as the root AllocMark (the contract)" do
    alloc_marks = {}
    ops = []
    each_mir(program) do |n|
      alloc_marks[n.name] = n if n.is_a?(MIR::AllocMark)
      ops << n if n.is_a?(MIR::InlineZig) && n.respond_to?(:target_var) && n.target_var == "handles"
    end
    root_alloc = alloc_marks["handles"].alloc
    ops.each do |iz|
      next unless iz.allocs&.key?(:alloc)
      expect(iz.allocs[:alloc]).to eq(root_alloc),
        "op alloc :#{iz.allocs[:alloc]} disagrees with root 'handles' AllocMark :#{root_alloc} " \
        "(resolver/checker root divergence -> INLINE_ALLOC_MISMATCH / UAF)"
    end
  end

  it "passes MIRChecker with zero INLINE_ALLOC_MISMATCH" do
    errors = MIRChecker.new.check_program!(program, strict: true) || []
    mismatches = errors.select { |e| e.to_s.include?("INLINE_ALLOC_MISMATCH") }
    expect(mismatches).to be_empty, "got: #{mismatches.join("\n")}"
  end
end
