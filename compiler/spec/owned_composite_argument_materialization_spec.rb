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

  COPIED_MAP_MERGE_RETURN_SOURCE = <<~CLEAR
    UNION Field {
      SymbolValue: String@symbol,
      StringValue: String,
    }

    STRUCT Context {
      placeholder_name: ?String,
      acc_placeholder: ?String,
      join_param_map: ?{String}String,
      bindings: {String}String,
      each_mode: Bool,
      rewrite_active: Bool,
      needed_fields: [Set]Field,
    }

    FN withBinding(self: Context, clear_name: String, zig_var: String) RETURNS Context ->
      RETURN Context{
        placeholder_name: COPY self.placeholder_name,
        acc_placeholder: COPY self.acc_placeholder,
        join_param_map: COPY self.join_param_map,
        bindings: COPY {clear_name: zig_var}.keys() |> REDUCE(COPY self.bindings) {
          acc[_] = COPY ({clear_name: zig_var}[_] OR_ELSE panic("missing hash key"));
          acc
        },
        each_mode: self.each_mode,
        rewrite_active: self.rewrite_active,
        needed_fields: COPY self.needed_fields,
      };
    END
  CLEAR

  RETAINED_DESTINATION_COPY_SOURCE = <<~CLEAR
    STRUCT Item {
      value: String,
    }

    FN retainBorrowed(item: Item) RETURNS Item@multiowned ->
      retained: Item@multiowned = COPY item;
      RETURN retained;
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
    nodes = []
    MIR.each_node(body) { |node| nodes << node }
    composite_names = nodes.grep(MIR::AllocMark).filter_map do |mark|
      mark.name.to_s if mark.type_info.resolved.to_s == "RegisterValue"
    end.to_set
    composite_lets = nodes.grep(MIR::Let).select { |stmt| composite_names.include?(stmt.name.to_s) }

    expect(composite_lets.length).to eq(3)
    composite_lets.each do |let|
      name = let.name.to_s
      marker_classes = nodes.select do |stmt|
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

      cleanup = nodes.find do |stmt|
        stmt.is_a?(MIR::ErrCleanup) && stmt.name.to_s == name
      end
      expect(cleanup.cleanup_entry.lifecycle_plan).not_to be_nil
      expect(cleanup.cleanup_entry.lifecycle_plan.type_key).to start_with("RegisterValue|")
    end

    allocated = nodes.grep(MIR::AllocMark).map { |mark| mark.name.to_s }.to_set
    transferred = nodes.grep(MIR::TransferMark).map { |mark| mark.name.to_s }.to_set
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

  it "keeps copied map-merge parameters borrowed and transfers only allocated temporaries" do
    program = lower(COPIED_MAP_MERGE_RETURN_SOURCE)
    fn = T.must(program.items.grep(MIR::FnDef).find { |item| item.name.to_s == "withBinding" })
    allocated = fn.body.grep(MIR::AllocMark).map { |mark| mark.name.to_s }.to_set
    transferred = fn.body.grep(MIR::TransferMark).map { |mark| mark.name.to_s }.to_set

    expect(transferred).not_to include("clear_name", "zig_var")
    expect(transferred - allocated).to be_empty
    expect { MIRChecker.new.check_program!(program, strict: true) }.not_to raise_error
  end

  it "never structurally copies an Rc handle when a plain payload fills a retained destination" do
    program = lower(RETAINED_DESTINATION_COPY_SOURCE)
    copies = []
    wrappers = []
    MIR.each_node(program.items) do |node|
      copies << node if node.is_a?(MIR::DeepCopy)
      wrappers << node if node.is_a?(MIR::CapWrap)
    end

    expect(copies.map(&:zig_type)).not_to include("CheatLib.Rc(Item)")
    expect(copies.map(&:zig_type)).to include("Item")
    expect(wrappers.map(&:own_fn)).to include("rcCreate")
    expect { MIRChecker.new.check_program!(program, strict: true) }.not_to raise_error
  end
end
