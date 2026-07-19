# A nested-field op's allocator must match its root container's AllocMark;
# divergence is INLINE_ALLOC_MISMATCH or a UAF.

require "rspec"
require "stringio"
require_relative "../ruby/mir/mir" unless defined?(MIR::StdlibDefFsCoercion)
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering::OwnershipSurfaceScan)
require_relative "../ruby/mir/mir_checker" unless defined?(MIRChecker::FsmStructureError)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/compiler/module_importer" unless defined?(ModuleImporter)
require_relative "../ruby/compiler/compiler_frontend" unless defined?(CompilerFrontend)

RSpec.describe "nested-@list-field append inherits root container allocator" do
  NESTED_FIELD_SRC = <<~CHT
    STRUCT Handle { values: []Int64 }

    FN run(n: Int64) RETURNS !Int64 ->
        MUTABLE handles: []Handle = List[];
        MUTABLE i: Int64 = 0_i64;
        WHILE i < n DO
            MUTABLE scratch: []Int64 = List[];
            &scratch.append(i);
            &handles.append(Handle{ values: [] });
            IF handles[i] EXISTS AS handle THEN
                &handle.values.append(scratch[0] OR_ELSE panic("scratch index invariant"));
            END
            i = i + 1_i64;
        END
        RETURN length(handles);
    END

    FN main() RETURNS Void ->
        r: Int64 = run(3_i64) OR_ELSE PASS;
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
    low = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: fe.struct_schemas,
      enum_schemas: fe.enum_schemas,
      union_schemas: fe.union_schemas,
      lifecycle_registry: fe.lifecycle_registry,
      fn_sigs: fe.fn_sigs,
      moved_guard_info: fe.moved_guard_info,
      importer: importer,
      source_dir: Dir.pwd # default Zig target; :bc skips structural allocator checks
    ))
    low.lower_program(fe.ast)
  end

  def each_mir(node, seen = {}, &blk)
    return if node.nil?
    return if seen[node.object_id]
    seen[node.object_id] = true
    if node.is_a?(Array)
      node.each { |c| each_mir(c, seen, &blk) }
      return
    end
    if node.is_a?(MIR::Program)
      each_mir(node.items, seen, &blk)
      return
    end
    return unless node.class.name.to_s.start_with?("MIR::")
    blk.call(node)
    if node.is_a?(Struct)
      node.members.each { |m| each_mir(node[m], seen, &blk) }
    elsif node.respond_to?(:each_pair)
      node.each_pair { |_name, value| each_mir(value, seen, &blk) }
    end
  end

  let(:program) { lower_program(NESTED_FIELD_SRC) }

  it "lowers a nested-field append using the root AllocMark placement" do
    alloc_marks = {}
    ops_targeting_handles = []
    each_mir(program) do |n|
      alloc_marks[n.name] = n if n.is_a?(MIR::AllocMark)
      if (n.is_a?(MIR::RegistryCall) || n.is_a?(MIR::IndexedStore)) && n.respond_to?(:target_var) && n.target_var == "handles"
        ops_targeting_handles << n
      end
    end
    expect(alloc_marks["handles"]).not_to be_nil
    expect(alloc_marks["handles"].scope).not_to eq(:iteration),
      "root container placement must outlive each loop iteration"
    expect(ops_targeting_handles.any? { |op| op.allocs&.primary }).to be(true)
  end

  it "resolves every handles-targeting op to the same allocator as the root AllocMark (the contract)" do
    alloc_marks = {}
    ops = []
    each_mir(program) do |n|
      alloc_marks[n.name] = n if n.is_a?(MIR::AllocMark)
      ops << n if (n.is_a?(MIR::RegistryCall) || n.is_a?(MIR::IndexedStore)) && n.respond_to?(:target_var) && n.target_var == "handles"
    end
    root_alloc = alloc_marks["handles"].alloc
    ops.each do |op|
      op_alloc = op.allocs&.primary
      next unless op_alloc
      expect(op_alloc).to eq(root_alloc),
        "op alloc :#{op_alloc} disagrees with root 'handles' AllocMark :#{root_alloc} " \
        "(resolver/checker root divergence -> INLINE_ALLOC_MISMATCH / UAF)"
    end
  end

  it "passes MIRChecker with zero INLINE_ALLOC_MISMATCH" do
    errors = MIRChecker.new.check_program!(program, strict: true) || []
    mismatches = errors.select { |e| e.to_s.include?("INLINE_ALLOC_MISMATCH") }
    expect(mismatches).to be_empty, "got: #{mismatches.join("\n")}"
  end
end
