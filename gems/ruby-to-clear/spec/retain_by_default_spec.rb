# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Ruby retain-by-default ownership" do
  ITEM = <<~RUBY
    class Item
      def initialize
        @name = T.let("item", String)
      end
    end
  RUBY

  def transpile_with_ir(source)
    parsed = Prism.parse(source)
    transpiler = RubyToClear::Transpiler.new(source)
    [transpiler.transpile(parsed.value), transpiler.typed_ir]
  end

  it "retains an external Ruby object when a local alias escapes" do
    clear, ir = transpile_with_ir(ITEM + <<~RUBY)
      sig { params(item: Item).returns(Item) }
      def alias_item(item)
        other = item
        item.to_s
        other
      end
    RUBY

    expect(ir.storage_ownership.values.map(&:mode)).to include(:retain)
    expect(clear).to include("MUTABLE other: Item@multiowned = item;")
    expect(clear).not_to include("MUTABLE other: Item@multiowned = COPY item;")
  end

  it "uses KEEP when a retained owned local remains live" do
    clear, ir = transpile_with_ir(ITEM + <<~RUBY)
      sig { returns(Item) }
      def fan_out
        item = Item.new
        other = item
        item.to_s
        other
      end
    RUBY

    expect(ir.storage_ownership.values.map(&:mode)).to include(:retain)
    expect(clear).to include("MUTABLE other: Item@multiowned = KEEP item;")
  end

  it "moves a retained owned local at its last use" do
    clear, ir = transpile_with_ir(ITEM + <<~RUBY)
      sig { returns(Item) }
      def move_last
        item = Item.new
        other = item
        other
      end
    RUBY

    expect(ir.storage_ownership.values.map(&:mode)).to include(:move)
    expect(clear).to include("MUTABLE other = item;")
    expect(clear).not_to match(/MUTABLE other.*(?:KEEP|COPY) item/)
  end

  it "keeps explicit dup as an independent payload copy" do
    clear, = transpile_with_ir(ITEM + <<~RUBY)
      sig { returns(Item) }
      def duplicate
        item = Item.new
        other = item.dup
        item.to_s
        other
      end
    RUBY

    expect(clear).to include("MUTABLE other = OWN COPY item;")
    expect(clear).not_to include("MUTABLE other = KEEP item;")
  end

  it "retains rather than structurally copying borrowed array elements" do
    clear, ir = transpile_with_ir(ITEM + <<~RUBY)
      class Bag < T::Struct
        prop :items, T::Array[Item]
      end

      sig { params(bag: Bag, item: Item).void }
      def append_item(bag, item)
        bag.items << item
        item.to_s
      end
    RUBY

    expect(ir.storage_ownership.values.map(&:mode)).to include(:retain)
    expect(clear).to include("&bag.items.append(item);")
    expect(clear).not_to include("&bag.items.append(COPY item);")
  end

  it "retains rather than structurally copying borrowed map values" do
    clear, ir = transpile_with_ir(ITEM + <<~RUBY)
      class Registry < T::Struct
        prop :items, T::Hash[String, Item]

        sig { params(name: String, item: Item).returns(Item) }
        def []=(name, item)
          @items[name] = item
          item
        end
      end
    RUBY

    expect(ir.storage_ownership.values.map(&:mode)).to include(:retain)
    expect(clear).to include("self.items[name] = item;")
    expect(clear).not_to include("self.items[name] = COPY item;")
  end

  it "materializes a borrowed union element before moving it into another array" do
    clear, = transpile_with_ir(<<~RUBY)
      class Signature
        LifetimeSource = T.type_alias { T.any(String, Symbol) }

        sig { params(raw: T::Array[LifetimeSource]).returns(T::Array[LifetimeSource]) }
        def normalize(raw)
          out = T.let([], T::Array[LifetimeSource])
          item = raw.fetch(0)
          if item.is_a?(Symbol)
            out << item.to_s
          else
            out << item
          end
          out
        end
      end
    RUBY

    expect(clear).to include("MUTABLE item = COPY UNWRAP (raw[0]);")
    expect(clear).to include("&out.append(item);")
  end

  it "does not retain a nested field whose imported identity is finalized as a value" do
    clear, = transpile_with_ir(<<~RUBY)
      # ruby-to-clear: value
      class Type
      end

      class SymbolEntry
        class BindingLifecycleFacts < T::Struct
          prop :type, Type
        end

        sig { params(lifecycle: BindingLifecycleFacts).void }
        def initialize(lifecycle)
          @lifecycle = T.let(lifecycle, BindingLifecycleFacts)
        end

        sig { returns(BindingLifecycleFacts) }
        attr_reader :lifecycle

        sig { returns(Type) }
        def type = lifecycle.type
      end
    RUBY

    expect(clear).to include("RETURN COPY rtoc_self_view.lifecycle.type;")
    expect(clear).not_to include("KEEP rtoc_self_view.lifecycle.type")
  end
end
