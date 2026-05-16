# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../src/ast/type"
require_relative "../src/mir/mir"
require_relative "../src/ast/std_lib"
require_relative "../src/annotator-helpers/intrinsic_registry"

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

  it "yields a pure Type return_type and Proc resolver fidelity" do
    REGISTRIES.each_value do |reg|
      reg.each do |mname, entry|
        next unless entry.is_a?(Hash)

        fs = IntrinsicRegistry.convert_entry(mname, entry, REGISTRIES)
        expect(fs.return_type).to be_a(Type)
        src = entry.key?(:return_type) ? entry[:return_type] : entry[:return]
        expect(fs.return_resolver).to be_a(Proc) if src.is_a?(Proc)
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
    expect(fs.return_resolver).to be_a(Proc)

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
