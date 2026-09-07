# frozen_string_literal: true

require "rspec"
require_relative "../ruby/compiler/compiler_frontend" unless defined?(CompilerFrontend)
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering)
require_relative "../ruby/mir/mir_checker" unless defined?(MIRChecker::FsmStructureError)

# Returning a COPY of a `?U@boxed` field, where U is a UNION, lowers to a deep
# copy that a heap cell then boxes. The cell's operand is still an
# un-materialized expression when the cell is built, so the transfer had
# nowhere to be recorded and the copy reached the checker with an ErrCleanup
# and no matching TransferMark. A STRUCT payload copies inline and never hit
# this. Both shapes below are the ones the translated annotator uses.
RSpec.describe "boxed union return ownership" do
  DIRECT_SOURCE = <<~CLEAR
    STRUCT Leaf { name: String }
    STRUCT Twig { name: String }
    UNION Locatable { Leaf: Leaf, Twig: Twig }
    STRUCT GetField { target: ?Locatable@boxed }

    PUB FN target(value: GetField) RETURNS ?Locatable@boxed ->
      RETURN COPY value.target;
    END
  CLEAR

  MATCHED_SOURCE = <<~CLEAR
    STRUCT Leaf { name: String }
    STRUCT Twig { name: String }
    UNION Locatable { Leaf: Leaf, Twig: Twig }
    STRUCT GetField { target: ?Locatable@boxed }
    STRUCT GetIndex { target: ?Locatable@boxed }
    UNION AccessPathNode { GetField: GetField, GetIndex: GetIndex }

    PUB FN target(value: AccessPathNode) RETURNS ?Locatable@boxed ->
      PARTIAL MATCH value START
        AccessPathNode.GetField AS item -> RETURN COPY item.target;,
        AccessPathNode.GetIndex AS item -> RETURN COPY item.target;,
        DEFAULT -> RETURN NIL;
      END
      RETURN NIL;
    END
  CLEAR

  def lower(source)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    frontend = CompilerFrontend.compile(source, importer: importer, source_dir: Dir.pwd)
    MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: frontend.struct_schemas,
      enum_schemas: frontend.enum_schemas,
      union_schemas: frontend.union_schemas,
      fn_sigs: frontend.fn_sigs,
      moved_guard_info: frontend.moved_guard_info,
      lifecycle_registry: frontend.lifecycle_registry,
      importer: importer,
      source_dir: Dir.pwd,
    )).lower_program(frontend.ast)
  end

  it "records the transfer for a boxed union copied straight out of a field" do
    errors = MIRChecker.new.check_program!(lower(DIRECT_SOURCE), strict: true)

    expect(errors.grep(/ERRCLEANUP_WITHOUT_TRANSFER|OWNERSHIP_USE_AFTER_TRANSFER/)).to be_empty
  end

  it "records it for every arm of a MATCH returning one" do
    errors = MIRChecker.new.check_program!(lower(MATCHED_SOURCE), strict: true)

    expect(errors.grep(/ERRCLEANUP_WITHOUT_TRANSFER|OWNERSHIP_USE_AFTER_TRANSFER/)).to be_empty
  end
end
