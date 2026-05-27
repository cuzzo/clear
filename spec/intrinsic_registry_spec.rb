# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../src/ast/type"
require_relative "../src/mir/mir"
require_relative "../src/ast/std_lib"
require_relative "../src/annotator/helpers/intrinsic_registry"

# Totality + fidelity: every real registry entry must convert without
# error (T::Struct raises on any mistyped IntrinsicEmit prop, so this
# proves the typed model fits the real authoring data), and key
# semantics must round-trip.
RSpec.describe IntrinsicRegistry do
  REGISTRIES = {
    STD_LIB: STD_LIB, POOL_METHODS: POOL_METHODS, SET_METHODS: SET_METHODS,
    MAP_METHODS: MAP_METHODS, INDEX_OPS: INDEX_OPS, BUILTIN_OPS: BUILTIN_OPS
  }.freeze

  it "converts every entry in every registry without error (totality)" do
    REGISTRIES.each do |rname, reg|
      reg.each do |mname, entry|
        next unless entry.is_a?(Hash)

        expect { IntrinsicRegistry.convert_entry(mname, entry, REGISTRIES) }
          .not_to(raise_error, "#{rname}[#{mname.inspect}] failed to convert")
      end
    end
  end

  it "yields a pure Type return_type and a typed FunctionReturn (no Proc/Hash)" do
    REGISTRIES.each_value do |reg|
      reg.each do |mname, entry|
        next unless entry.is_a?(Hash)

        fs = IntrinsicRegistry.convert_entry(mname, entry, REGISTRIES)
        expect(fs.return_type).to be_a(Type)
        expect(fs.return_def).to be_a(FunctionReturn)
        src = entry.key?(:return_type) ? entry[:return_type] : entry[:return]
        # No Proc/Hash leakage: every descriptor maps to a closed
        # FunctionReturn variant, and the static return_type matches
        # the FunctionReturn for the Fixed case.
        expect(src).not_to be_a(Proc)
        if fs.return_def.kind == FunctionReturn::Kind::Fixed
          expect(fs.return_type).to eq(fs.return_def.fixed)
        else
          expect(fs.return_type.resolved).to eq(:Any)
        end
        case src
        when :r_element_of
          expect(fs.return_def.kind).to eq(FunctionReturn::Kind::ElementOf)
        when :r_id_element
          expect(fs.return_def.kind).to eq(FunctionReturn::Kind::IdOfElement)
        when :r_optional_value
          expect(fs.return_def.kind).to eq(FunctionReturn::Kind::OptionalOfValue)
        end
        expect(fs.emit).to be_a(IntrinsicEmit).or be_nil
        expect(fs.intrinsic).to be(true)
      end
    end
  end

  it "round-trips representative emit fields incl. recursion" do
    fs = IntrinsicRegistry.convert_entry(
      "insert", POOL_METHODS["insert"], REGISTRIES
    )
    expect(fs.emit.tag).to eq(:pool_method)
    expect(fs.emit.is_method).to be(true)
    expect(fs.emit.zig).to be_a(String)
    # POOL_METHODS["insert"] returns `Id<element>` -> IdOfElement variant.
    expect(fs.return_def).to be_a(FunctionReturn)
    expect(fs.return_def.kind).to eq(FunctionReturn::Kind::IdOfElement)

    # Nested recursive sub-descriptor (eql/cleanup/... -> IntrinsicEmit)
    nested = REGISTRIES.each_value.flat_map(&:values)
                       .select { |e| e.is_a?(Hash) }
                       .find { |e| e[:eql].is_a?(Hash) || e[:cleanup].is_a?(Hash) }
    if nested
      fe = IntrinsicRegistry.convert_entry("x", nested, REGISTRIES)
      sub = fe.emit.eql || fe.emit.cleanup
      expect(sub).to be_a(IntrinsicEmit)
    end
  end
end
