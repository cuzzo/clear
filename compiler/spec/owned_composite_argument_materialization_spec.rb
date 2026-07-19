# frozen_string_literal: true

require "rspec"
require "set"
require_relative "../ruby/compiler/compiler_frontend" unless defined?(CompilerFrontend)
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering)
require_relative "../ruby/mir/mir_checker" unless defined?(MIRChecker::FsmStructureError)

RSpec.describe "owned composite argument materialization" do
  OWNED_COMPOSITE_SOURCE = <<~CLEAR
    UNION RegisterValue {
      Nil,
      Int64Val: Int64,
      Number: Float64,
      Str: String,
    }

    FN materialize(
      sregs: [4]String,
      iregs: [4]Int64,
      fregs: [4]Float64,
      src: Int64
    ) RETURNS !Void ->
      MUTABLE values: []RegisterValue = [];
      &values.append(RegisterValue{ Str: COPY sregs[src] });
      &values.append(RegisterValue{ Int64Val: iregs[src] });
      &values.append(RegisterValue{ Number: fregs[src] });
      RETURN;
    END
  CLEAR

  OWNED_COMPOSITE_NESTED_RECEIVER_SOURCE = <<~CLEAR
    UNION RegisterValue {
      Nil,
      Int64Val: Int64,
      Number: Float64,
      Str: String,
    }

    STRUCT Slot {
      values: []RegisterValue,
    }

    FN materializeNested(
      sregs: [4]String,
      iregs: [4]Int64,
      fregs: [4]Float64,
      MUTABLE slots: []Slot
    ) RETURNS !Void ->
      MUTABLE index: Int64 = 0_i64;
      WHILE index < slots.length() DO
        IF slots[index] EXISTS AS slot THEN
          &slot.values.append(RegisterValue{ Str: COPY sregs[index] });
          &slot.values.append(RegisterValue{ Int64Val: iregs[index] });
          &slot.values.append(RegisterValue{ Number: fregs[index] });
        END
        index += 1_i64;
      END
      RETURN;
    END
  CLEAR

  SELF_FALLBACK_REASSIGN_SOURCE = <<~CLEAR
    FN maybe(value: String) RETURNS !String ->
      IF value.length() == 0 THEN RAISE "empty"; END
      RETURN COPY value;
    END

    FN main() RETURNS Void ->
      MUTABLE current = "initial";
      current = maybe("replacement") OR_ELSE current;
      ASSERT current == "replacement";
      RETURN;
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

  def materialize_body(program)
    program.items.grep(MIR::FnDef).find { |fn| fn.name.to_s == "materialize" }.body
  end

  it "uses the standard owned-binding lifecycle for COPY and scalar union arguments" do
    body = materialize_body(lower(OWNED_COMPOSITE_SOURCE))
    composite_lets = body.grep(MIR::Let).select do |stmt|
      stmt.init.is_a?(MIR::StructInit) && stmt.init.zig_type.to_s == "RegisterValue"
    end

    expect(composite_lets.length).to eq(3)
    composite_lets.each do |let|
      name = let.name.to_s
      marker_classes = body.select do |stmt|
        stmt.respond_to?(:name) && stmt.name.to_s == name &&
          (stmt.is_a?(MIR::AllocMark) || stmt.is_a?(MIR::Let) ||
           stmt.is_a?(MIR::Cleanup) || stmt.is_a?(MIR::ErrCleanup) ||
           stmt.is_a?(MIR::TransferMark))
      end.map(&:class)

      expect(marker_classes).to eq([
        MIR::AllocMark,
        MIR::Let,
        MIR::ErrCleanup,
        MIR::TransferMark,
      ])

      cleanup = body.find do |stmt|
        stmt.is_a?(MIR::ErrCleanup) && stmt.name.to_s == name
      end
      expect(cleanup.cleanup_entry.lifecycle_plan).not_to be_nil
      expect(cleanup.cleanup_entry.lifecycle_plan.type_key).to start_with("RegisterValue|")
    end

    allocated = body.grep(MIR::AllocMark).map { |mark| mark.name.to_s }.to_set
    transferred = body.grep(MIR::TransferMark).map { |mark| mark.name.to_s }.to_set
    expect(transferred - allocated).to be_empty
  end

  it "passes strict linear ownership verification" do
    program = lower(OWNED_COMPOSITE_SOURCE)

    expect { MIRChecker.new.check_program!(program, strict: true) }.not_to raise_error
  end

  it "registers ResourceClose in linear statement traversal" do
    expect(MIRChecker::LINEAR_STATEMENT_NODE_TYPES).to include(MIR::ResourceClose)
    expect(MIRChecker::AUDITED_EMITTABLE_NODE_TYPES).to include(MIR::ResourceClose)

    close = MIR::ResourceClose.new(
      MIR::Ident.new("handle"),
      Schemas::ResourceClosePlan.method("close"),
    )
    fn = MIR::FnDef.new("close_handle", [], "void", [close], :pub, false, nil)

    errors = MIRChecker.new.check_fn!(fn)

    expect(errors.grep(/LINEAR_STMT_NOT_REGISTERED/)).to be_empty
  end

  it "materializes owned composite arguments through nested optional field receivers" do
    program = lower(OWNED_COMPOSITE_NESTED_RECEIVER_SOURCE)
    errors = MIRChecker.new.check_program!(program, strict: true)

    expect(errors.grep(/TRANSFER_WITHOUT_ALLOC|FRAME_NO_REWIND/)).to be_empty
  end

  it "does not transfer the old owner through a self-fallback reassignment" do
    program = lower(SELF_FALLBACK_REASSIGN_SOURCE)
    main = T.must(program.items.grep(MIR::FnDef).find { |fn| fn.name.to_s == "clearMain" })

    expect { MIRChecker.new.check_program!(program, strict: true) }.not_to raise_error
    expect(main.body.grep(MIR::TransferMark).map(&:name)).not_to include("current")
  end
end
