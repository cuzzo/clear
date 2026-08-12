# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"

RSpec.describe "self-host non-ownership shrink regressions" do
  TMP_ROOT = File.expand_path("../../../tmp", __dir__)

  def transpile(source)
    RubyToClear.transpile(source)
  end

  def transpile_compiler(relative_path)
    path = File.expand_path("../../../compiler/ruby/#{relative_path}", __dir__)
    RubyToClear.transpile_file(path)
  end

  it "uses a statement MATCH for a heap-valued case assignment" do
    clear = transpile(<<~RUBY)
      class Result < T::Struct
      end
      sig { params(kind: Symbol).returns(Result) }
      def choose(kind)
        result = case kind
        when :one then Result.new
        else Result.new
        end
        result
      end
    RUBY

    expect(clear).to include("MUTABLE result_branch_value: ?Result = NIL;")
    expect(clear).not_to include("MUTABLE result = PARTIAL MATCH")
  end

  it "keeps a nested conditional in a heap-valued MATCH arm statement-shaped" do
    clear = transpile(<<~RUBY)
      class Result < T::Struct
      end
      sig { params(kind: Symbol, use_first: T::Boolean).returns(Result) }
      def choose(kind, use_first)
        result = case kind
        when :one
          if use_first
            Result.new
          else
            Result.new
          end
        else
          Result.new
        end
        result
      end
    RUBY

    expect(clear).to include("MUTABLE result_branch_value: ?Result = NIL;")
    expect(clear).to include("IF use_first THEN")
    expect(clear).to include("result_branch_value = Result")
    expect(clear).not_to include("result_branch_value = IF")
  end

  it "uses string concatenation for a typed String +=" do
    clear = transpile(<<~RUBY)
      sig { returns(String) }
      def message
        out = T.let("", String)
        out += "suffix"
        out
      end
    RUBY

    expect(clear).to include('out = (out $+ "suffix")')
    expect(clear).not_to include('out = (out + "suffix")')
  end

  it "expands differently sized symbol alternatives without a mixed tuple pipeline" do
    clear = transpile(<<~RUBY)
      sig { params(values: T::Set[Symbol]).returns(T::Set[Symbol]) }
      def expand(values)
        out = T.let(Set.new, T::Set[Symbol])
        values.each do |value|
          if value == :wide
            out.add(:left)
            out.add(:right)
          else
            out.add(value)
          end
        end
        out
      end
    RUBY

    expect(clear).to include("&out.insert(:left);")
    expect(clear).not_to include("|> UNNEST")
  end

  it "propagates explicitly known fallibility to sibling calls" do
    clear = transpile(<<~RUBY)
      module Planner
        sig { returns(String) }
        # ruby-to-clear: fallible
        def self.plan
          raise "no plan"
        end

        sig { returns(String) }
        def self.use
          value = plan
          value
        end
      end
    RUBY

    expect(clear).to include("MUTABLE value = TRY (planner__plan());")
  end

  it "keeps a fallible projected-value choice statement-shaped" do
    clear = transpile(<<~RUBY)
      class Value < T::Struct
      end
      module Projection
        sig { returns(Value) }
        # ruby-to-clear: fallible
        def self.key
          raise "missing key"
        end

        sig { params(member: Symbol).returns(T.nilable(Value)) }
        def self.pick(member)
          projected = T.let(nil, T.nilable(Value))
          if member == :key
            projected = key
          end
          projected
        end
      end
    RUBY

    expect(clear).to include("projected = TRY (projection__key());")
    expect(clear).not_to include("projected = IF")
  end

  it "preserves narrowing when sibling union classes have the same fields" do
    clear = transpile(<<~RUBY)
      class RaiseNode < T::Struct
        const :kind, Symbol
      end
      class ExitNode < T::Struct
        const :kind, Symbol
      end
      Node = T.type_alias { T.any(RaiseNode, ExitNode) }
      sig { params(node: Node).returns(Symbol) }
      def kind_of(node)
        case node
        when RaiseNode
          node.kind
        when ExitNode
          node.kind
        end
      end
    RUBY

    expect(clear).to include("Node.RaiseNode AS raise_node")
    expect(clear).to include("Node.ExitNode AS exit_node")
    expect(clear).not_to include("node.kind()")
  end

  it "keeps a ReturnNode narrowed after separately checking its optional value" do
    clear = transpile(<<~RUBY)
      class Expr < T::Struct
      end
      class ReturnNode < T::Struct
        const :value, T.nilable(Expr)
      end
      class OtherNode < T::Struct
      end
      Node = T.type_alias { T.any(ReturnNode, OtherNode) }
      sig { params(node: Node).returns(T.nilable(Expr)) }
      def return_value(node)
        return nil unless node.is_a?(ReturnNode)
        value = node.value
        return nil unless value
        value
      end
    RUBY

    expect(clear).to include("IS_A ReturnNode")
    expect(clear).to include(".value")
    expect(clear).not_to include("node.value()")
  end

  it "builds a typed map from heterogeneous key/value pairs without to_h tuple inference" do
    clear = transpile(<<~RUBY)
      class Param < T::Struct
        const :name, String
      end
      sig { params(parameters: T::Array[Param]).returns(T::Hash[String, Param]) }
      def index(parameters)
        result = T.let({}, T::Hash[String, Param])
        parameters.each { |parameter| result[parameter.name] = parameter }
        result
      end
    RUBY

    expect(clear).to include("MUTABLE result: {String}Param = {};")
    expect(clear).not_to include("|> TO_HASH")
  end

  it "does not redeclare a union owned by an imported file" do
    Dir.mktmpdir("rtoc-union-", TMP_ROOT) do |dir|
      dependency = File.join(dir, "token.rb")
      root = File.join(dir, "state.rb")
      File.write(dependency, "TokenValue = T.type_alias { T.any(String, Integer) }\n")
      File.write(root, <<~RUBY)
        require_relative "token"
        sig { params(value: TokenValue).returns(TokenValue) }
        def identity(value)
          value
        end
      RUBY

      clear = RubyToClear.transpile_file(root)
      expect(clear).to include('REQUIRE "token.clear"')
      expect(clear).not_to include("UNION TokenValue")
    end
  end

  it "constructs tense variants through the declared union boundary" do
    clear = transpile(<<~RUBY)
      module Kind; end
      class Inner < T::Struct
      end
      class Fallible < T::Struct
        include Kind
        const :inner, Inner
      end
      class Other < T::Struct
        include Kind
      end
      KindValue = T.type_alias { T.any(Fallible, Other) }
      class Wrapper < T::Struct
        const :kind, KindValue
      end
      sig { params(inner: Inner).returns(Wrapper) }
      def wrap(inner)
        Wrapper.new(kind: Fallible.new(inner: inner))
      end
    RUBY

    expect(clear).to include("kind: KindValue{ Fallible:")
  end

  it "lowers optional boolean disjunction only after a presence guard" do
    clear = transpile(<<~RUBY)
      sig { params(values: T.nilable(T::Set[Symbol])).returns(T::Boolean) }
      def effect?(values)
        return false unless values
        values.include?(:io) || values.include?(:extern)
      end
    RUBY

    expect(clear).to include("values_value.contains?(:io) OR values_value.contains?(:extern)")
    expect(clear).not_to include("OR_ELSE")
  end

  it "checks named template keys without materializing a fallible key list" do
    clear = transpile(<<~RUBY)
      sig { params(template: String, values: T::Hash[Symbol, String]).returns(T::Boolean) }
      def complete?(template, values)
        offset = T.let(0, Integer)
        loop do
          start_index = template.index("%{", offset)
          break unless start_index
          end_index = template.index("}", start_index + 2)
          break unless end_index
          key = T.must(template[(start_index + 2)...end_index]).to_sym
          return false unless values.key?(key)
          offset = end_index + 1
        end
        true
      end
    RUBY

    expect(clear).not_to include("MUTABLE keys")
    expect(clear).to include("values.contains?(key)")
  end

  it "makes an explicit dup independent before a later mutating call" do
    clear = transpile(<<~RUBY)
      class Rule < T::Struct
        const :match, String
      end
      sig { params(rule: Rule).returns(String) }
      def scan(rule)
        pattern = rule.match.dup
        pattern
      end
    RUBY

    expect(clear).to include("MUTABLE pattern = COPY rule.match;")
  end

  it "normalizes String-or-Symbol map keys before indexing" do
    clear = transpile(<<~RUBY)
      Name = T.type_alias { T.any(String, Symbol) }
      sig { params(name: Name).returns(Symbol) }
      def normalize(name)
        name.is_a?(Symbol) ? name : name.to_sym
      end
      sig { params(name: Name, values: T::Hash[Symbol, Integer]).returns(T.nilable(Integer)) }
      def lookup(name, values)
        values[normalize(name)]
      end
    RUBY

    expect(clear).to include("values[normalize(name)]")
    expect(clear).not_to include("values[name.to_sym()]")
  end

  it "resolves an instance helper from a required class reopening" do
    Dir.mktmpdir("rtoc-reopen-", TMP_ROOT) do |dir|
      state = File.join(dir, "state.rb")
      types = File.join(dir, "types.rb")
      File.write(state, <<~RUBY)
        class Parser
          sig { params(kind: Symbol).returns(Integer) }
          def consume(kind)
            1
          end
        end
      RUBY
      File.write(types, <<~RUBY)
        require_relative "state"
        class Parser
          sig { returns(Integer) }
          def parse
            consume(:item)
          end
        end
      RUBY

      clear = RubyToClear.transpile_file(types)
      expect(clear).to include("parser__consume(rtoc_self_view, :item)")
      expect(clear).not_to include("RETURN consume(:item)")
    end
  end

  it "uses local function metadata instead of emitting an undefined reader helper" do
    clear = transpile(<<~RUBY)
      class Fn < T::Struct
        const :reentrance_kind, T.nilable(Symbol)
        const :effects_decl, T.nilable(Symbol)
      end
      sig { params(node: Fn).returns(T::Boolean) }
      def reentrant?(node)
        (node.reentrance_kind || node.effects_decl) == :reentrant
      end
    RUBY

    expect(clear).not_to include("declared_plain_reentrant")
    expect(clear).to include("node.reentrance_kind")
  end

  it "passes narrowed AST nodes directly to nilable node helpers" do
    clear = transpile(<<~RUBY)
      class Node < T::Struct
      end
      class Identifier < Node
      end
      sig { params(node: T.nilable(Node)).returns(T::Boolean) }
      def placeholder?(node)
        node.is_a?(Identifier)
      end
      sig { params(nodes: T::Array[Node]).returns(T::Boolean) }
      def any_placeholder?(nodes)
        nodes.any? { |node| placeholder?(node) }
      end
    RUBY

    expect(clear).to include("|> ANY placeholder?(_)")
  end

  it "uses statements rather than a heap-valued MATCH for ownership aliases" do
    clear = transpile(<<~RUBY)
      class Entry < T::Struct
      end
      class Left < T::Struct
        const :entry, T.nilable(Entry)
      end
      class Right < T::Struct
        const :entry, T.nilable(Entry)
      end
      Node = T.type_alias { T.any(Left, Right) }
      sig { params(node: Node).returns(T.nilable(Entry)) }
      def entry(node)
        value = T.let(nil, T.nilable(Entry))
        if node.is_a?(Left)
          value = node.entry
        elsif node.is_a?(Right)
          value = node.entry
        end
        value
      end
    RUBY

    expect(clear).not_to include("MUTABLE value = PARTIAL MATCH")
    expect(clear).to include("MUTABLE value: ?Entry = NIL;")
  end

  it "keeps an optional symbol local explicitly typed across conditional writes" do
    clear = transpile(<<~RUBY)
      sig { params(locked: T::Boolean, write_locked: T::Boolean).returns(T.nilable(Symbol)) }
      def value_sync(locked, write_locked)
        result = T.let(nil, T.nilable(Symbol))
        if locked
          result = :locked
        elsif write_locked
          result = :write_locked
        end
        result
      end
    RUBY

    expect(clear).to include("MUTABLE result: ?String@symbol = NIL;")
    expect(clear).not_to include("MUTABLE result = IF")
  end

  it "uses a typed branch slot for a non-optional symbol conditional" do
    clear = transpile(<<~RUBY)
      sig { params(dynamic: T::Boolean).returns(Symbol) }
      def collection_kind(dynamic)
        kind = T.let(dynamic ? :list : :array, Symbol)
        kind
      end
    RUBY

    expect(clear).to include("MUTABLE kind_branch_value: ?String@symbol = NIL;")
    expect(clear).to include("MUTABLE kind: String@symbol = kind_branch_value?;")
    expect(clear).not_to include("MUTABLE kind = NIL;")
  end

  it "passes the default positional diagnostic argument explicitly across modules" do
    clear = transpile(<<~RUBY)
      module Registry
        sig { params(code: Symbol, args: T::Array[String]).returns(T.nilable(String)) }
        def self.format(code, args = [])
          nil
        end
      end

      sig { returns(String) }
      def message
        T.must(Registry.format(:example, []))
      end
    RUBY

    expect(clear).to include("registry__format(:example, ")
    expect(clear).not_to include("registry__format(:example)")
  end

  it "explicitly upcasts a concrete variant at a union-valued field boundary" do
    clear = transpile(<<~RUBY)
      module ExpressionKind
        extend T::Helpers
        sealed!
      end
      class LinearExpression < T::Struct
        include ExpressionKind
        const :name, Symbol
      end
      class Expression < T::Struct
        const :kind, ExpressionKind
        sig { params(kind: ExpressionKind).returns(Expression) }
        def self.of(kind)
          new(kind: kind)
        end
      end
      sig { returns(Expression) }
      def expression
        Expression.new(kind: T.cast(LinearExpression.new(name: :list), ExpressionKind))
      end
    RUBY

    expect(clear).to include("CAST(LinearExpression")
    expect(clear).to include("AS ExpressionKind)")
  end

  it "explicitly upcasts a named synthetic token at a finding boundary" do
    clear = transpile(<<~RUBY)
      module TokenLike
        extend T::Helpers
        sealed!
      end
      class AnchorToken < T::Struct
        include TokenLike
        const :line, Integer
        const :column, Integer
      end
      class Finding < T::Struct
        const :token, TokenLike
      end
      sig { params(line: Integer, column: Integer).returns(Finding) }
      def finding(line, column)
        anchor = AnchorToken.new(line: line, column: column)
        Finding.new(token: T.cast(anchor, TokenLike))
      end
    RUBY

    expect(clear).to include("MUTABLE anchor = AnchorToken")
    expect(clear).to include("CAST(anchor AS TokenLike)")
    expect(clear).not_to include("AnonymousStruct")
  end

  it "uses declared scalar field types for positional Struct.new tokens" do
    clear = transpile(<<~RUBY)
      AnchorToken = Struct.new(:line, :column) do
        # ruby-to-clear: field-type line=Int64
        # ruby-to-clear: field-type column=Int64
      end

      sig { params(line: Integer, column: Integer).returns(AnchorToken) }
      def anchor(line, column)
        AnchorToken.new(line, column)
      end
    RUBY

    expect(clear).to include("STRUCT AnchorToken {\n  line: Int64,\n  column: Int64")
    expect(clear).not_to include("line: Any@multiowned")
    expect(clear).not_to include("column: Any@multiowned")
  end

  it "does not assign a terminal raise into a typed case branch slot" do
    clear = transpile(<<~RUBY)
      class Choice < T::Struct
      end
      sig { params(kind: Symbol).returns(Choice) }
      def choose(kind)
        choice = case kind
        when :valid
          Choice.new
        else
          raise "invalid choice"
        end
        choice
      end
    RUBY

    expect(clear).to include('panic("invalid choice")')
    expect(clear).not_to include('choice_branch_value = panic')
  end

  it "preserves union narrowing across a compound ReturnNode value guard" do
    clear = transpile(<<~RUBY)
      class Expr < T::Struct
      end
      class ReturnNode < T::Struct
        const :value, T.nilable(Expr)
      end
      class OtherNode < T::Struct
      end
      Node = T.type_alias { T.any(ReturnNode, OtherNode) }
      sig { params(node: Node).returns(T.nilable(Expr)) }
      def return_value(node)
        return nil unless node.is_a?(ReturnNode) && node.value
        node.value
      end
    RUBY

    expect(clear).to include("IS_A ReturnNode")
    expect(clear).not_to include("node.value()")
  end

  it "keeps block-form any as a pipeline for a fallible array receiver" do
    clear = transpile(<<~RUBY)
      class Type < T::Struct
        const :active, T::Boolean
        sig { returns(T::Boolean) }
        def any?
          active
        end
      end
      class Container
        extend T::Sig
        sig { returns(T::Array[Type]) }
        # ruby-to-clear: fallible
        def generic_args
          raise "missing items"
        end
        sig { returns(T::Boolean) }
        def active?
          generic_args.any? { |argument| argument.active }
        end
      end
    RUBY

    expect(clear).to include("TRY (container__generic_args")
    expect(clear).to include("|> ANY")
    expect(clear).not_to include("RETURN type__any?(")
  end

  it "types a heterogeneous tuple used as a map fetch default" do
    clear = transpile(<<~RUBY)
      class RootIndex
        extend T::Sig
        sig { void }
        def initialize
          @roots = T.let({}, T::Hash[Integer, [Integer, String]])
        end
        sig { params(id: Integer, name: String).returns([Integer, String]) }
        def root_or_default(id, name)
          root_id, root_name = @roots.fetch(id, [id, name])
          [root_id, root_name]
        end
      end
    RUBY

    expect(clear).to include("OR_ELSE CAST(Tuple{")
    expect(clear).not_to include("OR_ELSE [id, name]")
  end

  it "uses one nominal union for a marker interface and its exact type alias" do
    clear = transpile(<<~RUBY)
      module AST
        module Locatable
          sig { returns(Symbol) }
          def kind
            :node
          end
        end
        class Identifier < T::Struct
          include Locatable
        end
        Node = T.type_alias { Locatable }
      end
      sig { params(node: AST::Node).returns(Symbol) }
      def node_kind(node)
        node.is_a?(AST::Identifier) ? node.kind : :node
      end
    RUBY

    expect(clear).to include("node: Locatable")
    expect(clear).not_to include("UNION Node")
    expect(clear).not_to include("node.kind()")
  end

  it "flattens the canonical Locatable union when nested in a wider union" do
    clear = transpile(<<~RUBY)
      module AST
        module Locatable; end
        class Identifier < T::Struct
          include Locatable
        end
        class VarDecl < T::Struct
          include Locatable
        end
        Node = T.type_alias { Locatable }
      end
      Input = T.type_alias { T.any(AST::Node, String, Symbol) }
      sig { params(input: Input).returns(T::Boolean) }
      def declaration?(input)
        input.is_a?(AST::VarDecl)
      end
    RUBY

    expect(clear).to match(/UNION Input \{[^}]*Identifier: Identifier/)
    expect(clear).to match(/UNION Input \{[^}]*VarDecl: VarDecl/)
    expect(clear).not_to match(/UNION Input \{[^}]*Locatable: Locatable/)
  end

  it "does not redeclare a namespaced union owned by an imported file" do
    Dir.mktmpdir("rtoc-namespaced-union-", TMP_ROOT) do |dir|
      dependency = File.join(dir, "lexer.rb")
      root = File.join(dir, "state.rb")
      File.write(dependency, <<~RUBY)
        module Lexer
          TokenValue = T.type_alias { T.any(String, Integer, Float) }
          class Token < T::Struct
            const :value, TokenValue
          end
        end
      RUBY
      File.write(root, <<~RUBY)
        require_relative "lexer"
        sig { params(token: Lexer::Token).returns(Lexer::TokenValue) }
        def token_value(token)
          token.value
        end
      RUBY

      clear = RubyToClear.transpile_file(root)
      expect(clear).to include('REQUIRE "lexer.clear"')
      expect(clear).not_to include("UNION TokenValue")
    end
  end

  it "returns a next value from a value-producing callback" do
    clear = transpile(<<~RUBY)
      sig do
        params(value: Integer, visitor: T.proc.params(value: Integer).returns(Integer))
          .returns(Integer)
      end
      def transform(value, &visitor)
        visitor.call(value)
      end
      sig { params(value: Integer).returns(Integer) }
      def normalize(value)
        transform(value) do |candidate|
          next candidate unless candidate > 0
          candidate + 1
        end
      end
    RUBY

    expect(clear).to include("RETURN candidate;")
    expect(clear).not_to include("CONTINUE;")
  end

  it "tracks typed callback parameters while narrowing marker unions" do
    clear = transpile(<<~RUBY)
      module Item
        extend T::Helpers
        sealed!
      end
      class Left < T::Struct
        include Item
        const :kind, Symbol
      end
      class Right < T::Struct
        include Item
      end
      sig do
        params(items: T::Array[Item], visitor: T.proc.params(item: Item).void).void
      end
      def visit_items(items, &visitor)
        nil
      end
      sig { params(items: T::Array[Item]).void }
      def scan(items)
        visit_items(items) do |item|
          if item.is_a?(Left)
            item.kind
          end
        end
      end
    RUBY

    expect(clear).to include("IS_A Left AS left")
    expect(clear).to include("left.kind")
    expect(clear).not_to include("item.kind()")
  end

  it "lowers an optional collection test through an explicit presence check" do
    clear = transpile(<<~RUBY)
      class Branch < T::Struct
        const :items, T.nilable(T::Array[Integer])
      end
      sig { params(branch: Branch).returns(T::Boolean) }
      def populated?(branch)
        !branch.items.nil? && !T.must(branch.items).empty?
      end
    RUBY

    expect(clear).to match(/(?:!= NIL|== NIL)/)
    expect(clear).not_to match(/\\bitems\\s+AND/)
  end

  it "makes every enum arm of a declared non-optional return explicit" do
    clear = transpile(<<~RUBY)
      class Kind < T::Enum
        enums do
          Left = new(:left)
          Right = new(:right)
        end
      end
      sig { params(kind: Kind).returns(String) }
      def label(kind)
        case kind
        when Kind::Left then "left"
        when Kind::Right then "right"
        else
          raise "unknown kind"
        end
      end
    RUBY

    expect(clear).not_to include("RETURN NIL;")
  end

  it "merges typed maps using the supported indexed-write primitive" do
    clear = transpile(<<~RUBY)
      sig do
        params(target: T::Hash[Symbol, String], additions: T::Hash[Symbol, String])
          .returns(T::Hash[Symbol, String])
      end
      def merge_maps(target, additions)
        additions.each { |key, value| target[key] = value }
        target
      end
    RUBY

    expect(clear).to include("target[")
    expect(clear).not_to include("merge_mut")
  end

  it "preserves a SymbolEntry narrowing after an independent source guard" do
    clear = transpile(<<~RUBY)
      class SymbolEntry < T::Struct
        const :binding_id, Integer
      end
      class Source < T::Struct
      end
      sig do
        params(source: T.nilable(Source), symbol: T.nilable(SymbolEntry))
          .returns(T.nilable(Integer))
      end
      def binding(source, symbol)
        return nil unless source
        return nil unless symbol.is_a?(SymbolEntry)
        T.must(symbol).binding_id
      end
    RUBY

    expect(clear).to include("UNWRAP (symbol)")
  end

  it "materializes no-expand mixin storage on a T::Struct implementer" do
    clear = transpile(<<~RUBY)
      module AST
        # ruby-to-clear: no-expand
        module Locatable
          sig { returns(T.nilable(String)) }
          def type_object
            @type_object = T.let(@type_object, T.nilable(String))
          end
        end

        class ProtocolRequirement < T::Struct
          include Locatable
          const :name, String
        end
      end
    RUBY

    requirement = clear[/STRUCT ProtocolRequirement \{.*?\n\}/m]
    expect(requirement).to include("type_object: ?String")
    expect(requirement).to include("name: String")
  end

  it "exports data constants used from a required class reopening" do
    Dir.mktmpdir("rtoc-class-constant-", TMP_ROOT) do |dir|
      dependency = File.join(dir, "parser.rb")
      root = File.join(dir, "state.rb")
      File.write(dependency, <<~RUBY)
        class Parser
          # ruby-to-clear: data-api
          OPEN_VALUES = T.let("([{".freeze, String)
        end
      RUBY
      File.write(root, <<~RUBY)
        require_relative "parser"
        class Parser
          sig { params(value: String).returns(T::Boolean) }
          def open?(value)
            OPEN_VALUES.include?(value)
          end
        end
      RUBY

      dependency_clear = RubyToClear.transpile_file(dependency)
      root_clear = RubyToClear.transpile_file(root)
      expect(dependency_clear).to include("PUB FN ruby_constant_open_values() RETURNS String")
      expect(root_clear).to include('"([{".contains?(value)')
      expect(root_clear).not_to match(/\\bopen_values\\b/)
    end
  end

  it "emits a local typed frozen-array validation table" do
    clear = transpile(<<~RUBY)
      class Envelope
        extend T::Sig
        VALID_ORDERS = T.let(["", "!", "?"].freeze, T::Array[String])
        sig { params(order: String).returns(T::Boolean) }
        def valid?(order)
          VALID_ORDERS.include?(order)
        end
      end
    RUBY

    expect(clear).to include("valid_orders")
    expect(clear).to include("valid_orders.contains?(order)")
  end

  it "keeps a parser syntax-token table in the reopening that consumes it" do
    clear = transpile(<<~RUBY)
      class Parser
        extend T::Sig
        SYNTAX_TOKENS = T.let(%w[; THEN DO ->].freeze, T::Array[String])
        sig { params(value: String).returns(T::Boolean) }
        def statement_end_token?(value)
          SYNTAX_TOKENS.include?(value)
        end
      end
    RUBY

    expect(clear).to include("syntax_tokens")
    expect(clear).to include("syntax_tokens.contains?(value)")
    expect(clear).not_to include("SYNTAX_TOKENS")
  end

  it "checks presence before narrowing an optional marker union" do
    clear = transpile(<<~RUBY)
      module Node
        extend T::Helpers
        sealed!
      end
      class Identifier < T::Struct
        include Node
        const :name, String
      end
      class Literal < T::Struct
        include Node
      end
      sig { params(node: T.nilable(Node)).returns(T::Boolean) }
      def placeholder?(node)
        return false unless node
        node.is_a?(Identifier) && node.name == "_"
      end
    RUBY

    expect(clear).to match(/node (?:!= NIL|EXISTS)/)
    expect(clear).to include("IS_A Identifier")
    expect(clear).not_to include("IS_A requires")
  end

  it "upcasts an extern annotation at the signature boundary" do
    clear = transpile(<<~RUBY)
      module TypeInput
        extend T::Helpers
        sealed!
      end
      class Type < T::Struct
        include TypeInput
      end
      class ExternDecl < T::Struct
        const :annotation_return_type, T.nilable(Type)
      end
      class Signature < T::Struct
        const :return_type, T.nilable(TypeInput)
      end
      sig { params(node: ExternDecl).returns(Signature) }
      def signature(node)
        Signature.new(
          return_type: T.cast(node.annotation_return_type, T.nilable(TypeInput)),
        )
      end
    RUBY

    expect(clear).to include("CAST(node.annotation_return_type AS ?TypeInput)")
  end

  it "types the first element of an optional AST body before narrowing it" do
    clear = transpile(<<~RUBY)
      module Node
        extend T::Helpers
        sealed!
      end
      class ReturnNode < T::Struct
        include Node
        const :value, T.nilable(String)
      end
      class Literal < T::Struct
        include Node
      end
      class Branch < T::Struct
        const :body, T.nilable(T::Array[Node])
      end
      sig { params(branch: Branch).returns(T.nilable(String)) }
      def returned_value(branch)
        body = T.cast(branch.body, T.nilable(T::Array[Node]))
        return nil unless body
        body = T.must(body)
        ret = T.cast(body.first, T.nilable(Node))
        return nil unless ret.is_a?(ReturnNode) && ret.value
        ret.value
      end
    RUBY

    expect(clear).to include("IS_A ReturnNode")
    expect(clear).not_to match(/ret IS_A ReturnNode.*got Any/)
  end

  it "moves an outer pipeline capture into a typed helper boundary" do
    clear = transpile(<<~RUBY)
      class Event < T::Struct
        const :ordinal, Integer
        const :binding_id, Integer
      end
      class Fact < T::Struct
        const :ordinal, Integer
        const :source_id, Integer
      end
      class Facts
        extend T::Sig
        sig { void }
        def initialize
          @events = T.let([], T::Array[Event])
          @facts = T.let([], T::Array[Fact])
        end
        sig { returns(T::Array[T::Array[Event]]) }
        def decisions
          @facts.map { |fact| events_after(fact) }
        end
        sig { params(fact: Fact).returns(T::Array[Event]) }
        def events_after(fact)
          @events.select { |event| event.ordinal > fact.ordinal && event.binding_id == fact.source_id }
        end
      end
    RUBY

    expect(clear).to include("facts__events_after")
    expect(clear).not_to include("_.source_id")
  end

  it "reads a heap-valued shared-union field through a statement MATCH" do
    clear = transpile(<<~RUBY)
      class Type < T::Struct
        const :name, String
      end
      module Node
        extend T::Helpers
        sealed!
        sig { returns(T.nilable(Type)) }
        def type_object
          @type_object = T.let(@type_object, T.nilable(Type))
        end
      end
      class Identifier < T::Struct
        include Node
      end
      class Literal < T::Struct
        include Node
      end
      sig { params(node: Node).returns(T.nilable(Type)) }
      def inferred(node)
        type = node.type_object
        type
      end
    RUBY

    expect(clear).to include("MUTABLE type: ?Type")
    expect(clear).to match(/MATCH node START.*type = COPY item\.type_object/m)
    expect(clear).not_to include("MUTABLE type:? = (MATCH")
  end

  it "writes a heap-valued shared-union field through a statement MATCH" do
    clear = transpile(<<~RUBY)
      class SourceRange < T::Struct
        const :start_offset, Integer
      end
      module Locatable
        extend T::Helpers
        sealed!
        sig { params(range: SourceRange).void }
        def source_range=(range)
          @source_range = T.let(range, T.nilable(SourceRange))
        end
      end
      class Identifier < T::Struct
        include Locatable
      end
      class Literal < T::Struct
        include Locatable
      end
      Node = T.type_alias { Locatable }
      sig { params(node: Node, range: SourceRange).returns(Node) }
      def stamp(node, range)
        node.source_range = range
        node
      end
    RUBY

    expect(clear).to match(/MATCH node START.*Locatable\.Identifier AS item ->.*item_mutable\.source_range = COPY range;.*node = Locatable\{ Identifier: item_mutable \};.*Locatable\.Literal AS item ->.*item_mutable\.source_range = COPY range;.*node = Locatable\{ Literal: item_mutable \};/m)
    expect(clear).not_to include("node.source_range =")
  end

  it "materializes a heap-valued shared-union read before writing another union" do
    clear = transpile(<<~RUBY)
      class Type < T::Struct
        const :name, String
      end
      module Locatable
        extend T::Helpers
        sealed!
        sig { returns(T.nilable(Type)) }
        def type_object
          @type_object = T.let(@type_object, T.nilable(Type))
        end
        sig { params(value: T.nilable(Type)).void }
        def type_object=(value)
          @type_object = value
        end
      end
      class Identifier < T::Struct
        include Locatable
      end
      class Literal < T::Struct
        include Locatable
      end
      Node = T.type_alias { Locatable }
      sig { params(dst: Node, src: Node).returns(Node) }
      def copy_type(dst, src)
        dst.type_object = src.type_object
        dst
      end
    RUBY

    expect(clear).to match(/MUTABLE rtoc_union_field_value_\d+: \?Type.*MATCH src START.*rtoc_union_field_value_\d+ = COPY item\.type_object/m)
    expect(clear).to include("item_mutable.type_object = rtoc_union_field_value_")
    expect(clear).not_to include("item_mutable.type_object = (MATCH src START")
  end

  it "upcasts extern lifetime names into the declared union array" do
    clear = transpile(<<~RUBY)
      class FunctionSignature
        LifetimeSource = T.type_alias { T.any(String, Symbol) }
      end
      module Node
        extend T::Helpers
        sealed!
      end
      class Identifier < T::Struct
        include Node
        const :name, String
      end
      class Literal < T::Struct
        include Node
      end
      sig do
        params(nodes: T::Array[Node])
          .returns(T::Array[FunctionSignature::LifetimeSource])
      end
      def lifetime_names(nodes)
        paths = T.let([], T::Array[FunctionSignature::LifetimeSource])
        nodes.each do |source|
          next unless source.is_a?(Identifier)
          identifier = T.cast(source, Identifier)
          paths << identifier.name.to_s
        end
        paths
      end
    RUBY

    expect(clear).to include("IS_A Identifier")
    expect(clear).to include("MUTABLE paths: []FunctionSignatureLifetimeSource")
    expect(clear).to include("paths.append(FunctionSignatureLifetimeSource{ StringValue:")
    expect(clear).to include("RETURNS ![]FunctionSignatureLifetimeSource")
    expect(clear).not_to include("respondsTo?")
    expect(clear).not_to include("_.name()")
    expect(clear).not_to include("MUTABLE paths: []String")
  end

  it "keeps nilable boolean Struct fields typed through false defaults" do
    clear = transpile(<<~RUBY)
      Param = Struct.new(:mutable, :takes, :comptime, keyword_init: true) do
        # ruby-to-clear: field-type mutable=?Bool
        # ruby-to-clear: field-type takes=?Bool
        # ruby-to-clear: field-type comptime=?Bool
      end
      sig { params(param: Param).returns(Param) }
      def normalize_param(param)
        Param.new(
          mutable: param.mutable || false,
          takes: param.takes || false,
          comptime: param.comptime || false
        )
      end
    RUBY

    expect(clear).to include("mutable: ?Bool", "takes: ?Bool", "comptime: ?Bool")
    expect(clear).to match(/rtoc_optional_or_source_\d+: \?Bool = param\.mutable/)
    expect(clear).to match(/rtoc_optional_or_source_\d+: \?Bool = param\.takes/)
    expect(clear).to match(/rtoc_optional_or_source_\d+: \?Bool = param\.comptime/)
    expect(clear.scan(/ELSE rtoc_optional_or_result_\d+ = FALSE/).length).to eq(3)
    expect(clear).not_to include("mutable: (param.mutable OR FALSE)")
    expect(clear).not_to include("takes: (param.takes OR FALSE)")
    expect(clear).not_to include("comptime: (param.comptime OR FALSE)")
  end

  it "keeps an optional extern-effects Struct field on its declared map union" do
    clear = transpile(<<~RUBY)
      module AST
        ExternEffectValue = T.type_alias { T.any(Symbol, TrueClass) }
        ExternEffects = T.type_alias { T::Hash[Symbol, ExternEffectValue] }
        ExternFnDecl = Struct.new(:effects, keyword_init: true) do
          sig { returns(T.nilable(ExternEffects)) }
          def effects
            self[:effects]
          end
        end
      end
      class FunctionSignature
        ExternEffectValue = T.type_alias { AST::ExternEffectValue }
        ExternEffects = T.type_alias { AST::ExternEffects }
      end
      sig { params(node: AST::ExternFnDecl).returns(FunctionSignature::ExternEffects) }
      def extern_effects(node)
        node.effects || {}
      end
    RUBY

    expect(clear).to include("effects: ?{String@symbol}ExternEffectValue")
    expect(clear).to include("RETURNS !{String@symbol}ExternEffectValue")
    expect(clear).not_to include("node.effects OR {}")
  end

  it "snapshots a self field before borrowing self mutably for a call" do
    clear = transpile(<<~RUBY)
      class Counter
        extend T::Sig
        sig { void }
        def initialize
          @depth = T.let(1, Integer)
        end
        sig { returns(Integer) }
        def pop!
          prune!(@depth)
          @depth -= 1
        end
        private
        sig { params(depth: Integer).void }
        def prune!(depth)
          @depth = depth
        end
      end
    RUBY

    expect(clear).to match(/MUTABLE rtoc_mutable_alias_arg_\d+ = COPY rtoc_self_view\.depth;/)
    expect(clear).to match(/counter__prune_mut\(&rtoc_self_view, rtoc_mutable_alias_arg_\d+\)/)
    expect(clear).not_to include("counter__prune_mut(&rtoc_self_view, rtoc_self_view.depth)")
  end

  it "reconstructs a frozen array of owned maps inside its consumer" do
    clear = transpile(<<~RUBY)
      module Buckets
        extend T::Sig
        BUCKETS = T.let([
          { id: :type, title: "Type" },
          { id: :ownership, title: "Ownership" },
        ].freeze, T::Array[T::Hash[Symbol, T.untyped]])

        sig { params(category: Symbol).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
        def self.for_category(category)
          matches = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
          BUCKETS.each do |bucket|
            matches << bucket if T.cast(bucket[:id], Symbol) == category
          end
          matches
        end
      end
    RUBY

    expect(clear).not_to match(/^buckets:/)
    expect(clear).to include("FN buckets__for_category")
    expect(clear).to include("FOR _ IN ([{:id: :type")
  end

  it "keeps nested event comparisons behind typed helper parameters" do
    clear = transpile(<<~RUBY)
      class Event < T::Struct
        const :binding_id, Integer
      end
      class Fact < T::Struct
        const :destination_id, Integer
      end
      class Decisions
        extend T::Sig
        sig { params(fact: Fact, events: T::Array[Event]).returns(T.nilable(Event)) }
        def conflict_for(fact, events)
          events.find { |event| conflicts?(fact, event) }
        end
        sig { params(fact: Fact, event: Event).returns(T::Boolean) }
        def conflicts?(fact, event)
          event.binding_id == fact.destination_id
        end
      end
    RUBY

    expect(clear).to include("decisions__conflicts?")
    expect(clear).not_to include("_.destination_id")
  end

  it "honors explicit storage types on an ordinary reopened class" do
    clear = transpile(<<~RUBY)
      class Cursor
        # ruby-to-clear: field-type pos=Int64
        # ruby-to-clear: field-type values=[]String
        sig { returns(T.nilable(String)) }
        def peek
          @values[@pos + 1]
        end
      end
    RUBY

    cursor = clear[/STRUCT Cursor \{.*?\n\}/m]
    expect(cursor).to include("pos: Int64")
    expect(cursor).to include("values: []String")
  end

  it "reads a shared-union type field before enforcing its full-type invariant" do
    clear = transpile(<<~RUBY)
      class Type < T::Struct
        const :untyped, T::Boolean
      end
      module Node
        extend T::Helpers
        sealed!
        sig { returns(T.nilable(Type)) }
        def type_object
          @type_object = T.let(@type_object, T.nilable(Type))
        end
      end
      class Left < T::Struct
        include Node
      end
      class Right < T::Struct
        include Node
      end
      sig { params(node: Node).returns(Type) }
      def full_type(node)
        type = node.type_object
        raise "unresolved" unless type
        type = T.must(type)
        raise "untyped" if type.untyped
        type
      end
    RUBY

    expect(clear).to include("MATCH node START")
    expect(clear).not_to include("node.full_type")
  end

  it "casts an Any-backed struct field before string operations" do
    clear = transpile(<<~RUBY)
      Call = Struct.new(:name) do
        # ruby-to-clear: field-type name=Any
      end
      sig { params(call: Call).returns(String) }
      def call_name(call)
        name = T.cast(T.unsafe(call)[:name], String)
        name
      end
    RUBY

    expect(clear).to include("CAST(call.name AS String)")
    expect(clear).not_to include("call__name")
  end

  it "casts an Any-backed call name before checking a typed name set" do
    clear = transpile(<<~RUBY)
      require "set"
      Call = Struct.new(:name) do
        # ruby-to-clear: field-type name=Any
      end
      sig { params(call: Call, names: T::Set[String]).returns(T::Boolean) }
      def contains_named_call?(call, names)
        name = T.cast(T.unsafe(call)[:name], String)
        names.include?(name)
      end
    RUBY

    expect(clear).to include("CAST(call.name AS String)")
    expect(clear).to match(/names\.contains\?\(name\)/)
    expect(clear).not_to include("call__name")
  end

  it "compares token text only after narrowing a union payload to String" do
    clear = transpile(<<~RUBY)
      TokenValue = T.type_alias { T.any(String, Integer, Float) }
      class Token < T::Struct
        const :value, TokenValue
        sig { returns(String) }
        def text!
          T.cast(value, String)
        end
      end
      sig { params(token: Token, expected: T.nilable(String)).returns(T::Boolean) }
      def matches_token_value?(token, expected)
        matches = T.let(false, T::Boolean)
        if expected
          expected_value = T.must(expected)
          if token.value.is_a?(String)
            matches = token.text! == expected_value
          end
        end
        matches
      end
    RUBY

    expect(clear).to include("matches: Bool = FALSE")
    expect(clear).to match(/token__text_mut\(token\) == expected_value/)
    expect(clear).not_to match(/token\.value == expected/)
  end

  it "uses typed token text after a character-kind guard" do
    clear = transpile(<<~RUBY)
      TokenValue = T.type_alias { T.any(String, Integer, Float) }
      class Token < T::Struct
        const :type, Symbol
        const :value, T.nilable(TokenValue)
        sig { returns(String) }
        def text!
          T.cast(value, String)
        end
      end
      sig { params(token: Token).returns(T::Boolean) }
      def legacy_bang?(token)
        token.type == :CHAR && token.text! == "!"
      end
      sig { params(token: Token).returns(T::Boolean) }
      def pattern_terminator?(token)
        return true if token.type == :KEYWORD && %w[AS WHEN END].include?(token.text!)
        token.type == :CHAR && token.text! == "{"
      end
    RUBY

    expect(clear).to match(/token__text_mut\(token\) == "!"/)
    expect(clear).to match(/contains\?\(token__text_mut\(token\)\)/)
    expect(clear).to match(/token__text_mut\(token\) == "\{"/)
    expect(clear).not_to match(/token\.value == "!"/)
  end

  it "matches an optional expected token value with early returns" do
    clear = transpile(<<~RUBY)
      TokenValue = T.type_alias { T.any(String, Integer, Float) }
      class Token < T::Struct
        const :type, Symbol
        const :value, TokenValue
        sig { returns(String) }
        def text!
          T.cast(value, String)
        end
      end
      sig { params(token: Token, type: Symbol, expected: T.nilable(String)).returns(T::Boolean) }
      def token_matches?(token, type, expected=nil)
        return false unless token.type == type
        return true if expected.nil?
        expected_value = T.must(expected)
        token.text! == expected_value
      end
      sig do
        params(token: T.nilable(Token), type: Symbol, expected: T.nilable(String))
          .returns(T::Boolean)
      end
      def optional_token_matches?(token, type, expected=nil)
        return false unless token
        return false unless token.type == type
        return true if expected.nil?
        expected_value = T.must(expected)
        token.text! == expected_value
      end
    RUBY

    expect(clear).to match(/token__text_mut\(token\) == expected_value/)
    expect(clear).to include("FN optional_token_matches?")
    expect(clear).not_to include("token.value IS_A")
    expect(clear).not_to match(/expected\?/)
    expect(clear).not_to match(/token\.value == expected/)
  end

  it "projects a token payload to String before a diagnostic keyword map" do
    clear = transpile(<<~RUBY)
      TokenValue = T.type_alias { T.any(String, Integer, Float) }
      DiagnosticValue = T.type_alias do
        T.nilable(T.any(String, Symbol, Integer, T::Boolean))
      end
      class Token < T::Struct
        const :value, TokenValue
        const :line, Integer
        sig { returns(String) }
        def display_value
          payload = value
          return payload if payload.is_a?(String)
          return payload.to_s if payload.is_a?(Integer)
          return payload.to_s if payload.is_a?(Float)
          ""
        end
      end
      sig do
        params(values: T::Hash[Symbol, DiagnosticValue])
          .returns(T::Hash[Symbol, DiagnosticValue])
      end
      def diagnostic_values(values)
        values
      end
      sig { params(token: Token, expected: String).returns(T::Hash[Symbol, DiagnosticValue]) }
      def token_diagnostic(token, expected)
        diagnostic_values(expected: expected, got: token.display_value, line: token.line)
      end
    RUBY

    expect(clear).to include("token__display_value")
    expect(clear).to include("diagnostic_values(values: {String@symbol}?DiagnosticValue)")
    expect(clear).to match(/:got: token__display_value\(token\)/)
    expect(clear).not_to match(/HashMap<String@symbol, Auto>/)
  end

  it "assigns an optional heap token with statement control flow" do
    clear = transpile(<<~RUBY)
      class Token < T::Struct
        const :text, String
      end
      sig do
        params(tokens: T::Array[Token], position: Integer)
          .returns(T.nilable(Token))
      end
      def previous_token(tokens, position)
        previous = T.let(nil, T.nilable(Token))
        if position > 0
          previous = tokens[position - 1]
        end
        previous
      end
    RUBY

    expect(clear).to include("MUTABLE previous: ?Token = NIL")
    expect(clear).to include("IF (position > 0) THEN")
    expect(clear).not_to include("previous = IF")
  end

  it "wraps layers in reverse order with an indexed loop" do
    clear = transpile(<<~RUBY)
      class Layer < T::Struct
        const :marker, String
        sig { params(inner: String).returns(String) }
        def wrap(inner)
          marker + inner
        end
      end
      sig { params(layers: T::Array[Layer], payload: String).returns(String) }
      def wrap_layers(layers, payload)
        inner = payload
        index = layers.length
        while index > 0
          index -= 1
          inner = T.must(layers[index]).wrap(inner)
        end
        inner
      end
    RUBY

    expect(clear).to include("WHILE (index > 0) DO")
    expect(clear).not_to include(".reverse()")
  end

  it "checks later transfer reads through a typed helper boundary" do
    clear = transpile(<<~RUBY)
      class Event < T::Struct
        const :ordinal, Integer
        const :binding_id, Integer
      end
      class Transfer < T::Struct
        const :ordinal, Integer
        const :source_id, Integer
      end
      class TransferFacts
        extend T::Sig
        sig { void }
        def initialize
          @reads = T.let([], T::Array[Event])
          @transfers = T.let([], T::Array[Transfer])
        end
        sig { returns(T::Array[T::Boolean]) }
        def decisions
          @transfers.map { |transfer| later_read?(transfer) }
        end
        sig { params(transfer: Transfer).returns(T::Boolean) }
        def later_read?(transfer)
          @reads.any? { |event| event.ordinal > transfer.ordinal && event.binding_id == transfer.source_id }
        end
      end
    RUBY

    expect(clear).to include("transferFacts__later_read?")
    expect(clear).not_to include("_.source_id")
  end

  it "constructs a concrete Type for a Type-valued parameter field" do
    clear = transpile(<<~RUBY)
      class Type < T::Struct
        const :name, Symbol
      end
      class Spec < T::Struct
        const :type, Symbol
      end
      class Param < T::Struct
        const :type, Type
      end
      sig { params(spec: Spec).returns(Param) }
      def validation_param(spec)
        Param.new(type: Type.new(name: spec.type))
      end
    RUBY

    expect(clear).to match(/Param\{ type: COPY Type\{ name: COPY spec\.type \} \}/)
    expect(clear).not_to include("Param{ type: COPY spec.type")
  end

  it "returns an indexed token before constructing its fallback" do
    clear = transpile(<<~RUBY)
      class Token < T::Struct
        const :text, String
      end
      sig { params(tokens: T::Array[Token], pos: Integer).returns(Token) }
      def peek(tokens, pos)
        token = tokens[pos + 1]
        return token if token
        Token.new(text: "")
      end
    RUBY

    expect(clear).to include("IF token EXISTS")
    expect(clear).not_to match(/RETURN .* OR Token/)
  end

  it "finds a layer index with a typed cursor loop" do
    clear = transpile(<<~RUBY)
      class Layer < T::Struct
        const :future, T::Boolean
      end
      sig { params(layers: T::Array[Layer]).returns(T.nilable(Integer)) }
      def future_index(layers)
        index = T.let(nil, T.nilable(Integer))
        cursor = T.let(0, Integer)
        while cursor < layers.length
          if T.must(layers[cursor]).future
            index = cursor
            break
          end
          cursor += 1
        end
        index
      end
    RUBY

    expect(clear).to include("WHILE (cursor < layers.length()) DO")
    expect(clear).not_to include("indexOf()")
  end

  it "declares an indexed optional local with its concrete payload type" do
    clear = transpile(<<~RUBY)
      class Token < T::Struct
      end
      sig { params(tokens: T::Array[Token], index: Integer).returns(Token) }
      def token_at(tokens, index)
        token = tokens[index]
        return token if token
        Token.new
      end
    RUBY

    expect(clear).to match(/MUTABLE token: \?Token = (?:COPY )?tokens\[index_value\];/)
    expect(clear).not_to include("MUTABLE token:?")
  end

  it "does not unwrap a safe-navigation local after its presence guard" do
    clear = transpile(<<~RUBY)
      class Param < T::Struct
        const :mutable, T::Boolean
      end
      sig { params(params: T::Array[Param], index: Integer).returns(T::Boolean) }
      def mutable_param?(params, index)
        param = params[index]
        param&.mutable == true
      end
    RUBY

    expect(clear).to include("((param != NIL) AND (param.mutable == TRUE))")
    expect(clear).not_to include("param?.mutable")
  end

  it "narrows an array-valued union arm in a case statement" do
    clear = transpile(<<~RUBY)
      class Node < T::Struct
      end
      Value = T.type_alias { T.any(Node, T::Array[Node]) }
      sig { params(value: Value).returns(Integer) }
      def width(value)
        case value
        when Array
          value.length
        else
          1
        end
      end
    RUBY

    expect(clear).to include("Value.ArrayValue AS array")
    expect(clear).to include("array.length()")
    expect(clear).not_to include("value == Array")
  end

  it "lowers Array#take to a LIMIT pipeline stage" do
    clear = transpile(<<~RUBY)
      sig { params(values: T::Array[String], count: Integer).returns(T::Array[String]) }
      def prefix(values, count)
        values.take(count)
      end
    RUBY

    expect(clear).to include("values |> LIMIT count")
    expect(clear).not_to include(".take(")
  end

  it "uses CLEAR flow narrowing for safe navigation on a typed field path" do
    clear = transpile(<<~RUBY)
      class Facts < T::Struct
        prop :effects, T.nilable(T::Set[Symbol])
      end
      class Signature < T::Struct
        prop :facts, Facts
        sig { void }
        def refresh!
          self.facts.effects = self.facts.effects&.dup
        end
      end
    RUBY

    expect(clear).to include("IF self.facts.effects != NIL THEN")
    expect(clear).not_to include("self.facts.effects?")
  end

  it "keeps an explicitly nilable indexed field local concrete" do
    clear = transpile(<<~RUBY)
      class Token < T::Struct
      end
      class Cursor
        # ruby-to-clear: field-type tokens=[]Token
        # ruby-to-clear: field-type pos=Int64
        sig { returns(T.nilable(Token)) }
        def peek
          token = T.let(@tokens[@pos + 1], T.nilable(Token))
          token
        end
      end
    RUBY

    expect(clear).to match(/MUTABLE token: \?Token = (?:COPY )?rtoc_self_view\.tokens/)
    expect(clear).not_to include("MUTABLE token = rtoc_self_view.tokens")
  end

  it "lowers reverse_each over a typed array without an inherent reverse call" do
    clear = transpile(<<~RUBY)
      class Node < T::Struct
      end
      sig { params(nodes: T::Array[Node], out: T::Array[Node]).void }
      def append_reversed(nodes, out)
        nodes.reverse_each { |node| out << node }
      end
    RUBY

    expect(clear).to include("WHILE rtoc_reverse_i_")
    expect(clear).to match(/out\.append\(COPY \(rtoc_reverse_items_\d+\[rtoc_reverse_i_\d+\]\)\?\)/)
    expect(clear).not_to include(".reverse()")
  end

  it "finds a matching layer without lowering a block to indexOf" do
    clear = transpile(<<~RUBY)
      class Layer < T::Struct
        const :kind, Symbol
      end
      sig { params(layers: T::Array[Layer], kind: Symbol).returns(T.nilable(Integer)) }
      def layer_index(layers, kind)
        index = T.let(0, Integer)
        while index < layers.length
          return index if T.must(layers[index]).kind == kind
          index += 1
        end
        nil
      end
    RUBY

    expect(clear).to include("WHILE (index < layers.length()) DO")
    expect(clear).not_to include("indexOf(")
  end

  it "unwraps a dynamic array index inside T.must" do
    clear = transpile(<<~RUBY)
      class Token < T::Struct
      end
      sig { params(tokens: T::Array[Token], index: Integer).returns(Token) }
      def required_token(tokens, index)
        T.must(tokens[index])
      end
    RUBY

    expect(clear).to match(/RETURN (?:COPY )?UNWRAP \(tokens\[index_value\]\);/)
    expect(clear).not_to match(/RETURN (?:COPY )?tokens\[index_value\];/)
  end

  it "unwraps an explicitly bound optional field index" do
    clear = transpile(<<~RUBY)
      class Token < T::Struct
      end
      class Cursor
        # ruby-to-clear: field-type tokens=[]Token
        # ruby-to-clear: field-type pos=Int64
        sig { returns(Token) }
        def current
          token = T.let(@tokens[@pos], T.nilable(Token))
          T.must(token)
        end
      end
    RUBY

    expect(clear).to include("MUTABLE token: ?Token")
    expect(clear).to match(/RETURN (?:COPY )?token\?;/)
  end

  it "does not runtime-test a typed raw-body child against its union name" do
    clear = transpile(<<~RUBY)
      class Node < T::Struct
      end
      RawBody = T.type_alias { T::Array[Node] }
      sig { params(body: RawBody, stack: T::Array[Node]).void }
      def push_body(body, stack)
        body.reverse_each { |child| stack << child }
      end
    RUBY

    expect(clear).to match(/stack\.append\(COPY \(rtoc_reverse_items_\d+\[rtoc_reverse_i_\d+\]\)\?\)/)
    expect(clear).not_to include("IS_A Node")
  end

  it "uses fetch for an invariant non-optional token field lookup" do
    clear = transpile(<<~RUBY)
      class Token < T::Struct
      end
      class Cursor
        # ruby-to-clear: field-type tokens=[]Token
        # ruby-to-clear: field-type pos=Int64
        sig { returns(Token) }
        def current
          @tokens.fetch(@pos)
        end
      end
    RUBY

    expect(clear).to include("RETURN COPY UNWRAP (rtoc_self_view.tokens[rtoc_self_view.pos]);")
  end

  it "uses the typed AST child walker instead of reflecting and retesting the union" do
    clear = transpile(<<~RUBY)
      class Node < T::Struct
      end
      module AST
        extend T::Sig
        sig { params(node: Node, blk: T.proc.params(child: Node).void).void }
        def self.each_child_node(node, &blk)
        end
      end
      sig { params(node: Node, stack: T::Array[Node]).void }
      def push_children(node, stack)
        AST.each_child_node(node) { |child| stack << child }
      end
    RUBY

    expect(clear).to include("aST__each_child_node(node")
    expect(clear).not_to include("IS_A Node")
  end

  it "resolves a mutating helper mixed into a partial class file" do
    Dir.mktmpdir("rtoc-partial-mixin-", TMP_ROOT) do |dir|
      helper = File.join(dir, "helper.rb")
      state = File.join(dir, "state.rb")
      File.write(helper, <<~RUBY)
        module ErrorHelper
          extend T::Sig
          sig { params(code: Symbol).returns(Integer) }
          def error!(code)
            @count += 1
          end
        end
      RUBY
      File.write(state, <<~RUBY)
        require_relative "helper"
        class Parser
          include ErrorHelper
          # ruby-to-clear: field-type count=Int64
          sig { returns(Integer) }
          def fail_parse
            error!(:bad)
          end
        end
      RUBY

      clear = RubyToClear.transpile_file(state)
      expect(clear).to include("parser__error_mut(&rtoc_self_view, :bad)")
      expect(clear).not_to include("RETURN error_mut(")
    end
  end

  it "casts the non-array remainder of a node-or-body union without testing the union name" do
    clear = transpile(<<~RUBY)
      module Locatable
        extend T::Helpers
        sealed!
      end
      class Node < T::Struct
        include Locatable
      end
      Scan = T.type_alias { T.any(Locatable, T::Array[Node]) }
      sig { params(value: Scan, stack: T::Array[Locatable]).void }
      def push(value, stack)
        if value.is_a?(Array)
          value.each { |child| stack << child }
        else
          stack << T.cast(value, Locatable)
        end
      end
    RUBY

    expect(clear).to include("ELSE")
    expect(clear).to include("castScanToLocatable")
    expect(clear).not_to include("IS_A Locatable")
  end

  it "captures an outer collection mutably when a closure appends to it" do
    clear = transpile(<<~RUBY)
      module Walker
        extend T::Sig
        sig { params(block: T.proc.params(value: Integer).void).void }
        def self.walk(&block)
        end
      end
      sig { returns(T::Array[Integer]) }
      def collect
        values = T.let([], T::Array[Integer])
        Walker.walk { |value| values << value }
        values
      end
    RUBY

    expect(clear).to include("USE(MUTABLE values)")
    expect(clear).to include("&values.append(COPY value)")
  end

  it "captures an outer collection mutably when passing it to a mutable parameter" do
    clear = transpile(<<~RUBY)
      class Resolver
        extend T::Sig
        sig { params(block: T.proc.params(value: Integer).void).void }
        def transform(&block)
        end
        sig { params(values: T::Array[Integer]).void }
        def append_one(values)
          values << 1
        end
        sig { returns(T::Array[Integer]) }
        def resolve
          values = T.let([], T::Array[Integer])
          transform { |_value| append_one(values) }
          values
        end
      end
    RUBY

    expect(clear).to include("USE(MUTABLE values")
    expect(clear).to include("resolver__append_one(rtoc_self_view, &values)")
  end

  it "treats mutation through a struct collection reader as mutation of self" do
    clear = transpile(<<~RUBY)
      class Plan < T::Struct
        extend T::Sig
        prop :all, T::Array[Integer], factory: -> { [] }
        sig { params(value: Integer).void }
        def add(value)
          all << value
        end
      end
    RUBY

    expect(clear).to include("FN plan__add(MUTABLE self: Plan")
    expect(clear).to include("&self.all.append(COPY value)")
  end

  it "rebuilds a shared-union variant after writing one of its fields" do
    clear = transpile(<<~RUBY)
      class SourceRange < T::Struct
        const :offset, Integer
      end
      module Locatable
        extend T::Helpers
        sealed!
        sig { params(range: SourceRange).void }
        def source_range=(range)
          @source_range = T.let(range, T.nilable(SourceRange))
        end
      end
      class Identifier < T::Struct
        include Locatable
      end
      class Literal < T::Struct
        include Locatable
      end
      Node = T.type_alias { Locatable }
      sig { params(node: Node, range: SourceRange).returns(Node) }
      def stamp(node, range)
        node.source_range = range
        node
      end
    RUBY

    expect(clear).to match(/Locatable\.Identifier AS item ->.*MUTABLE item_mutable = COPY item;.*item_mutable\.source_range = COPY range;.*node = Locatable\{ Identifier: item_mutable \};/m)
    expect(clear).to match(/Locatable\.Literal AS item ->.*node = Locatable\{ Literal: item_mutable \};/m)
  end

  it "materializes an aliasable call result before invoking a LOCAL instance method" do
    clear = transpile(<<~RUBY)
      class Result
        extend T::Sig
        sig { void }
        def initialize
          @fixed = T.let(true, T::Boolean)
        end
        sig { returns(T::Boolean) }
        def fixed?
          @fixed
        end
      end
      class Signature
        extend T::Sig
        sig { returns(Result) }
        def result
          Result.new
        end
        sig { returns(T::Boolean) }
        def fixed?
          result.fixed?
        end
      end
    RUBY

    expect(clear).to match(/MUTABLE rtoc_local_receiver_\d+ = signature__result\(rtoc_self_view\);.*result__fixed\?\(rtoc_local_receiver_\d+\)/m)
  end

  it "copies scanner-backed Regexp.last_match captures retained by a gsub block" do
    clear = transpile(<<~RUBY)
      sig { params(source: String).returns(String) }
      def expand(source)
        source.gsub(/item-(\d+)/) do
          capture = T.must(Regexp.last_match(1))
          capture
        end
      end
    RUBY

    expect(clear).to match(/MUTABLE capture = COPY scannerCapture\(rtoc_gsub_scanner_\d+, 1\)/)
  end

  it "materializes an immutable iteration value before passing it mutably" do
    clear = transpile(<<~RUBY)
      class Item < T::Struct
        prop :value, Integer
      end
      class Rewriter
        extend T::Sig
        sig { params(item: Item).returns(Item) }
        def rewrite_one(item)
          item.value = item.value + 1
          item
        end
        sig { params(items: T::Array[Item]).void }
        def rewrite_all(items)
          items.each { |item| rewrite_one(item) }
        end
        sig { params(items: T::Array[Item]).returns(T::Array[Item]) }
        def rebuild_all(items)
          items.map { |item| rewrite_one(item) }
        end
      end
    RUBY

    expect(clear).to match(/FOR _ IN items DO\s+MUTABLE rtoc_mutable_block_param_\d+ = COPY _;\s+rewriter__rewrite_one\(rtoc_self_view, &rtoc_mutable_block_param_\d+\)/m)
    expect(clear).to match(/SELECT \{ MUTABLE rtoc_mutable_block_param_\d+ = COPY _;\s+rewriter__rewrite_one\(rtoc_self_view, &rtoc_mutable_block_param_\d+\) \}/m)
  end

  it "qualifies a private singleton helper declared inside class << self" do
    clear = transpile(<<~RUBY)
      class Facts
        extend T::Sig

        sig { params(value: Integer).returns(Integer) }
        def self.build(value)
          increment(value)
        end

        class << self
          extend T::Sig
          private

          sig { params(value: Integer).returns(Integer) }
          def increment(value)
            value + 1
          end
        end
      end
    RUBY

    expect(clear).to include("RETURN facts__increment(value);")
    expect(clear).to include("PRIVATE FN facts__increment(value: Int64)")
    expect(clear).not_to include("PRIVATE FN increment(value: Int64)")
  end

  it "lowers Array#delete_at to the indexed CLEAR list removal method" do
    clear = transpile(<<~RUBY)
      sig { params(values: T::Array[String], index: Integer).returns(String) }
      def remove_at(values, index)
        values.delete_at(index)
      end
    RUBY

    expect(clear).to match(/RETURN &values\.remove\(index(?:_value)?\);/)
    expect(clear).not_to include(".delete_at(")
  end

  it "does not unwrap a source range whose reader is non-optional" do
    clear = transpile(<<~RUBY)
      class Range < T::Struct
        const :end_offset, Integer
      end
      class Node < T::Struct
        const :source_range, Range
      end
      sig { params(node: Node).returns(Integer) }
      def end_offset(node)
        range = T.cast(node.source_range, Range)
        range.end_offset
      end
    RUBY

    expect(clear).to match(/MUTABLE range: Range = (?:COPY )?(?:CAST\(node.source_range AS Range\)|range__cast\(node.source_range\))/)
    expect(clear).not_to include("UNWRAP (node.source_range)")
    expect(clear).to include("RETURN range.end_offset;")
  end

  it "uses a typed struct reader when choosing a capability fallback" do
    clear = transpile(<<~RUBY)
      class Capability < T::Struct
        const :capability, T.nilable(Symbol)
      end
      class Request < T::Struct
        const :source, Capability
        const :capability, Symbol
      end
      sig { params(request: Request).returns(Symbol) }
      def selected(request)
        request.source.capability || request.capability
      end
    RUBY

    expect(clear).to include("request.source.capability")
    expect(clear).to include("RETURN request.capability")
    expect(clear).not_to include(" OR request.capability")
  end

  it "injects a concrete program into the Locatable union for a structural walk" do
    clear = transpile(<<~RUBY)
      module AST
        module Locatable
          extend T::Helpers
          sealed!
        end
        Program = Struct.new(:statements) { include Locatable }
        sig { params(root: BasicObject, visitor: T.proc.params(node: Locatable).void).void }
        def self.each_locatable(root, &visitor)
        end
      end
      sig { params(program: AST::Program).void }
      def walk(program)
        AST.each_locatable(T.cast(program, AST::Locatable)) { |_node| nil }
      end
    RUBY

    expect(clear).to include("aST__each_locatable(CAST(program AS Locatable)")
  end

  it "exports the direct AST child walker from a data-only AST unit" do
    clear = transpile(<<~RUBY)
      # ruby-to-clear: data-only
      module AST
        module Locatable
          extend T::Helpers
          sealed!
        end
        Node = Struct.new(:child) { include Locatable }
        sig { params(node: Locatable, blk: T.proc.params(child: Locatable).void).void }
        def self.each_child_node(node, &blk)
        end
      end
    RUBY

    expect(clear).to include("PUB FN aST__each_child_node(node: Locatable")
    expect(clear).to include("FOR rtoc_walk_child IN rtocChildrenLocatable(node) DO")
    expect(clear).to include("visitor(rtoc_walk_child);")
  end

  it "unwraps a narrowed optional protocol before symbol conversion" do
    clear = transpile(<<~RUBY)
      sig { params(protocol: T.nilable(String)).returns(T.nilable(Symbol)) }
      def protocol_symbol(protocol)
        return nil unless protocol
        T.must(protocol).to_sym
      end
    RUBY

    expect(clear).to match(/symbol\((?:COPY )?(?:UNWRAP \(protocol\)|protocol_value)\)/)
    expect(clear).not_to include("symbol(protocol)")
  end

  it "preserves filter_map optionality explicitly in SELECT" do
    clear = transpile(<<~RUBY)
      sig { params(values: T::Array[String]).returns(T::Array[String]) }
      def present(values)
        values.filter_map { |value| value.empty? ? nil : value }
      end
    RUBY

    expect(clear).to include("|> SELECT:?")
    expect(clear).to include("|> WHERE _ != NIL")
  end

  it "uses a value block rather than directly invoking a generated lambda for indexed filter_map" do
    clear = transpile(<<~RUBY)
      sig { params(values: T::Array[String], skipped: Integer).returns(T::Array[String]) }
      def present(values, skipped)
        values.each_with_index.filter_map { |value, index| value unless index == skipped }
      end
    RUBY

    expect(clear).to match(/\{.*MUTABLE rtoc_indexed_items_\d+: \[\]String = values;/m)
    expect(clear).not_to match(/\}\)\(values\)/)
  end

  it "exports the AST moved predicate from a data-only AST unit" do
    clear = transpile(<<~RUBY)
      # ruby-to-clear: data-only
      module AST
        module Locatable
          extend T::Helpers
          sealed!
        end
        Node = Struct.new(:was_moved) { include Locatable }
        # ruby-to-clear: data-api
        sig { params(node: T.nilable(Locatable)).returns(T::Boolean) }
        def self.moved?(node)
          !!(node && node.was_moved == true)
        end
      end
    RUBY

    expect(clear).to include("FN aST__moved?(node: ?Locatable) RETURNS Bool")
    expect(clear).to include("was_moved == TRUE")
  end

  it "keeps a regex scanner binding immutable while copying retained captures" do
    clear = transpile(<<~RUBY)
      sig { params(source: String).returns(String) }
      def expand(source)
        source.gsub(/item-(\d+)/) do
          T.must(Regexp.last_match(1))
        end
      end
    RUBY

    expect(clear).to match(/rtoc_gsub_scanner_\d+ = scannerNew\(source\)/)
    expect(clear).not_to match(/MUTABLE rtoc_gsub_scanner_\d+/)
    expect(clear).to match(/COPY scannerCapture\(rtoc_gsub_scanner_\d+, 1\)/)
  end

  it "uses the Locatable union for Program statement storage" do
    path = File.expand_path("../../../compiler/ruby/ast/ast.rb", __dir__)
    clear = RubyToClear.transpile_file(path)

    expect(clear).to include("STRUCT Program")
    expect(clear).to include("statements: []Locatable")
    expect(clear).to match(/STRUCT FunctionDef \{\n(?:.*\n){0,8}  body: \[\]Locatable,/)
    expect(clear).to match(/STRUCT GetField \{\n(?:.*\n){0,3}  target: Locatable,/)
    expect(clear).not_to include("statements: []Node")
  end

  it "inlines frozen collection constants instead of creating module-owned heap bindings" do
    path = File.expand_path("../../../compiler/ruby/backends/zig_type_mapper.rb", __dir__)
    clear = RubyToClear.transpile_file(path)

    expect(clear).not_to match(/^MUTABLE zig_ops:/)
    expect(clear).not_to match(/^MUTABLE zig_primitives:/)
    expect(clear).not_to match(/^zig_ops:/)
  end

  it "finds a non-primitive array element structurally before indexed removal" do
    clear = transpile(<<~RUBY)
      class Edge < T::Struct
        const :from, String
        const :to, String
        const :kind, Symbol
      end
      sig { params(edges: T::Array[Edge], edge: Edge).returns(T.nilable(Edge)) }
      def remove_edge(edges, edge)
        index = T.let(0, Integer)
        while index < edges.length
          candidate = edges.fetch(index)
          return edges.delete_at(index) if candidate.from == edge.from &&
            candidate.to == edge.to && candidate.kind == edge.kind
          index += 1
        end
        nil
      end
    RUBY

    expect(clear).to match(/WHILE \(?index(?:_value)? < edges\.length\(\)\)? DO/)
    expect(clear).to match(/&edges\.remove\(index(?:_value)?\)/)
    expect(clear).not_to include(".indexOf(edge)")
  end

  it "keeps optional heap removal statement-shaped" do
    clear = transpile(<<~RUBY)
      class Edge < T::Struct
        const :name, String
      end
      sig { params(edges: T::Array[Edge], index: T.nilable(Integer)).returns(T.nilable(Edge)) }
      def remove_edge(edges, index)
        return nil unless index
        removed = edges.delete_at(index)
        removed
      end
    RUBY

    expect(clear).to include("RETURN NIL")
    expect(clear).to match(/MUTABLE removed = &edges\.remove\(index/)
    expect(clear).not_to include("MUTABLE removed = IF")
  end

  it "returns a narrowed optional payload in a concrete array" do
    clear = transpile(<<~RUBY)
      class Item < T::Struct
      end
      sig { params(item: T.nilable(Item)).returns([T::Boolean, T::Array[Item]]) }
      def collect(item)
        return [false, []] unless item
        [false, [item]]
      end
    RUBY

    expect(clear).to include("RETURNS Tuple<Bool, []Item>")
    expect(clear).not_to include("[]?Item")
  end

  it "passes a presence-narrowed optional object to its concrete method" do
    clear = transpile(<<~RUBY)
      class Plan < T::Struct
        extend T::Sig
        sig { returns(Plan) }
        def refresh
          self
        end
      end
      sig { params(plan: T.nilable(Plan)).returns(T.nilable(Plan)) }
      def refresh(plan)
        return nil unless plan
        concrete = T.cast(plan, Plan)
        concrete.refresh
      end
    RUBY

    expect(clear).to match(/CAST\(plan(?:_value)? AS Plan\)/)
    expect(clear).not_to match(%r{plan__refresh\([^)]*\?})
  end

  it "does not mark an anonymous literal as a mutable argument" do
    transpiler = RubyToClear::Transpiler.allocate

    expect(transpiler.mutable_argument_code("TRUE")).to eq("TRUE")
    expect(transpiler.mutable_argument_code("NIL")).to eq("NIL")
    expect(transpiler.mutable_argument_code("storage")).to eq("&storage")
  end

  it "uses in-place flow narrowing for a truthy local in a returning AND branch" do
    clear = transpile(<<~RUBY)
      class Call < T::Struct
        const :args, T::Array[String]
      end
      sig { params(call: T.nilable(Call), allowed: T::Boolean).returns(T::Array[String]) }
      def args_if_allowed(call, allowed)
        if call && allowed
          call.args
        else
          []
        end
      end
    RUBY

    expect(clear).to include("call.args")
    expect(clear).not_to include("(call?).args")
  end

  it "injects a concrete projection into its declared kind union" do
    clear = transpile(<<~RUBY)
      module Kind
        extend T::Helpers
        sealed!
      end
      class Projection < T::Struct
        include Kind
      end
      class Expression < T::Struct
        const :kind, Kind
      end
      sig { returns(Expression) }
      def expression
        projection = Projection.new
        Expression.new(kind: T.cast(projection, Kind))
      end
    RUBY

    expect(clear).to match(/kind: (?:COPY )?CAST\(projection AS Kind\)/)
  end

  it "collects selected union keys without an optional filter-map result" do
    clear = transpile(<<~RUBY)
      sig { params(values: T::Hash[String, Integer]).returns(T::Array[String]) }
      def positive_keys(values)
        matches = T.let([], T::Array[String])
        values.keys.each do |key|
          value = values[key]
          matches << key if value && value > 0
        end
        matches
      end
    RUBY

    expect(clear).to include("MUTABLE matches: []String")
    expect(clear).not_to include("MUTABLE matches =")
    expect(clear).not_to include("|> SELECT:?")
  end

  it "removes a heap layer with an explicit indexed loop" do
    clear = transpile(<<~RUBY)
      class Layer < T::Struct
      end
      sig { params(layers: T::Array[Layer], skipped: Integer).returns(T::Array[Layer]) }
      def without_layer(layers, skipped)
        retained = T.let([], T::Array[Layer])
        index = T.let(0, Integer)
        layers.each do |layer|
          retained << layer unless index == skipped
          index += 1
        end
        retained
      end
    RUBY

    expect(clear).to include("MUTABLE retained: []Layer")
    expect(clear).not_to include("rtoc_indexed_value")
    expect(clear).not_to include("|> SELECT:?")
  end

  it "selects an ancestor fallback without an optional heap IF expression" do
    clear = transpile(<<~RUBY)
      class Node < T::Struct
      end
      sig { params(nodes: T::Array[Node], fallback: Node, index: Integer).returns(Node) }
      def child(nodes, fallback, index)
        child = T.let(fallback, Node)
        child_index = index + 1
        child = nodes.fetch(child_index) if child_index < nodes.length
        child
      end
    RUBY

    expect(clear).to include("MUTABLE child: Node")
    expect(clear).not_to include("MUTABLE child = IF")
  end

  it "returns the rewritten statement array after an each side effect" do
    clear = transpile(<<~RUBY)
      sig { params(values: T::Array[String]).returns(T::Array[String]) }
      def rewrite(values)
        values.each { |_value| nil }
        values
      end
    RUBY

    expect(clear).to include("RETURN COPY values;")
  end

  it "maps the Ruby-only Zig subprocess adapter to the native compiler helper" do
    helper_config = File.expand_path("../config/compiler_regex_helpers.json", __dir__)
    clear = RubyToClear.transpile(<<~RUBY, helper_config: helper_config)
      class Importer
        # ruby-to-clear: skip
        sig { params(zig: String, source_dir: String, header_path: String).returns(String) }
        def self.compiler_zig_translate_c(zig, source_dir, header_path)
          raise "Ruby-only subprocess implementation"
        end

        sig { params(zig: String, source_dir: String, header_path: String).returns(String) }
        def self.translate(zig, source_dir, header_path)
          compiler_zig_translate_c(zig, source_dir, header_path)
        end
      end
    RUBY

    expect(clear).to include("EXTERN FN compilerZigTranslateC(")
    expect(clear).to include("TRY (compilerZigTranslateC(zig, source_dir, header_path))")
    expect(clear).not_to include("compiler_zig_translate_c(")
  end

  it "casts a union field target before a nested runtime type test" do
    clear = transpile(<<~RUBY)
      module Node
        extend T::Helpers
        sealed!
      end
      class Identifier < T::Struct
        include Node
        const :name, String
      end
      class GetField < T::Struct
        include Node
        const :target, Node
      end
      sig { params(node: T.nilable(Node)).returns(T::Boolean) }
      def placeholder?(node)
        return false unless node.is_a?(GetField)
        target = T.cast(node.target, Node)
        !!(target.is_a?(Identifier) && target.name == "_")
      end
    RUBY

    expect(clear).to match(/MUTABLE target: Node = (?:COPY )?(?:CAST\(|castNodeToNode\()/)
    expect(clear).to include("target IS_A Identifier")
    expect(clear).not_to include("MUTABLE target: Any")
  end

  it "narrows each assignment variant before reading its target" do
    clear = transpile(<<~RUBY)
      module Node
        extend T::Helpers
        sealed!
      end
      class Bind < T::Struct
        include Node
        const :name, String
      end
      class Assignment < T::Struct
        include Node
        const :name, String
      end
      sig { params(node: T.nilable(Node)).returns(T::Boolean) }
      def named?(node)
        if node.is_a?(Bind)
          bind = T.cast(node, Bind)
          return bind.name == "_"
        end
        if node.is_a?(Assignment)
          assignment = T.cast(node, Assignment)
          return assignment.name == "_"
        end
        false
      end
    RUBY

    expect(clear).to include("bind.name")
    expect(clear).to include("assignment.name")
    expect(clear).not_to match(/\(node\??\)\.name/)
  end

  it "gives same-named instance and singleton-class methods distinct emitted names" do
    clear = transpile(<<~RUBY)
      class Registry
        extend T::Sig
        sig { params(value: Integer).returns(Integer) }
        def key(value)
          value
        end
        class << self
          extend T::Sig
          sig { params(value: Integer).returns(Integer) }
          def key(value)
            value + 1
          end
          sig { params(value: Integer).returns(Integer) }
          def build(value)
            key(value)
          end
        end
      end
    RUBY

    expect(clear).to include("FN registry__key(self: Registry")
    expect(clear).to include("FN registry__class_key(value: Int64)")
    expect(clear).to include("RETURN registry__class_key(value);")
  end

  it "renders generated AST visitor callbacks as Void lambdas" do
    Dir.mktmpdir("rtoc-void-ast-visitor-", TMP_ROOT) do |dir|
      ast = File.join(dir, "ast.rb")
      consumer = File.join(dir, "consumer.rb")
      File.write(ast, <<~RUBY)
        # ruby-to-clear: data-only
        module AST
          module Locatable
            extend T::Helpers
            sealed!
          end
          Node = Struct.new(:kind) { include Locatable }
          sig { params(root: Locatable, visitor: T.proc.params(node: Locatable).void).void }
          def self.each_locatable(root, &visitor)
          end
        end
      RUBY
      File.write(consumer, <<~RUBY)
        require_relative "ast"
        sig { params(root: AST::Locatable, values: T::Array[String]).void }
        def collect(root, values)
          AST.each_locatable(root) do |node|
            case node
            when AST::Node
              values << node.kind.to_s
            end
          end
        end
      RUBY

      clear = RubyToClear.transpile_file(consumer)
      expect(clear).to include("rubyToClearVoid()")
      expect(clear).not_to match(/%\([^)]*\).*-> NIL/)
      expect(clear).not_to match(/%\([^)]*\).*RETURN NIL;.*rubyToClearVoid\(\)/m)
    end
  end

  it "propagates fallibility from a class-qualified helper call" do
    clear = transpile(<<~RUBY)
      class Wrapper
        extend T::Sig
        sig { params(value: String).returns(String) }
        def self.wrap(value)
          raise "empty" if value.empty?
          value
        end
      end
      sig { params(value: String).returns(String) }
      def use_wrapper(value)
        wrapped = Wrapper.wrap(value)
        wrapped
      end
    RUBY

    expect(clear).to include("MUTABLE wrapped = TRY (wrapper__wrap(value));")
  end

  it "lowers Array#one? without an unsupported inherent method" do
    clear = transpile(<<~RUBY)
      sig { params(values: T::Array[String]).returns(T::Boolean) }
      def exactly_one?(values)
        values.one?
      end
    RUBY

    expect(clear).to match(/values\.length\(\) == 1/)
    expect(clear).not_to include(".one?()")
  end

  it "narrows a union node before constructing a variant-specific replacement" do
    clear = transpile(<<~RUBY)
      module Node
        extend T::Helpers
        sealed!
      end
      class Binary < T::Struct
        include Node
        const :token, String
      end
      class Literal < T::Struct
        include Node
      end
      class Concat < T::Struct
        const :token, String
      end
      sig { params(node: Node, parts: T::Array[String]).returns(Node) }
      def rewrite(node, parts)
        if parts.length > 2
          return node unless node.is_a?(Binary)
          binary = T.cast(node, Binary)
          return T.cast(Concat.new(token: binary.token), Node)
        end
        node
      end
    RUBY

    expect(clear).to include("binary.token")
    expect(clear).not_to match(/\(node\??\)\.token/)
  end

  it "reads a recursive call name through its data field" do
    clear = transpile(<<~RUBY)
      module Node
        extend T::Helpers
        sealed!
      end
      class Call < T::Struct
        include Node
        const :name, T.untyped
        sig { returns(String) }
        def name
          self[:name].to_s
        end
      end
      sig { params(node: Node, expected: String).returns(T::Boolean) }
      def direct_call?(node, expected)
        return false unless node.is_a?(Call)
        name = T.cast(T.unsafe(node)[:name], String)
        name == expected
      end
    RUBY

    expect(clear).to match(/CAST\(KEEP call.name AS String\)/)
    expect(clear).not_to include("call__name(node)")
  end

  it "iterates narrowed conditional ancestors without an optional union element" do
    clear = transpile(<<~RUBY)
      module Node
        extend T::Helpers
        sealed!
      end
      class Conditional < T::Struct
        include Node
        const :side, Symbol
      end
      class Literal < T::Struct
        include Node
      end
      sig { params(nodes: T::Array[Node]).returns(T::Boolean) }
      def has_then?(nodes)
        nodes.each do |node|
          next unless node.is_a?(Conditional)
          conditional = T.cast(node, Conditional)
          return true if conditional.side == :then
        end
        false
      end
    RUBY

    expect(clear).to include("conditional.side")
    expect(clear).not_to include("got ?Locatable")
  end

  it "maps the Ruby-only Zig executable lookup to native compiler support" do
    helper_config = File.expand_path("../config/compiler_regex_helpers.json", __dir__)
    clear = RubyToClear.transpile(<<~RUBY, helper_config: helper_config)
      class Importer
        # ruby-to-clear: skip
        sig { returns(String) }
        def self.zig_executable
          ENV["CLEAR_ZIG"] || "zig"
        end

        sig { returns(String) }
        def self.selected
          zig_executable
        end
      end
    RUBY

    expect(clear).to include("EXTERN FN compilerZigExecutable()")
    expect(clear).to include("RETURN compilerZigExecutable();")
    expect(clear).not_to include("ENV")
  end

  it "moves a narrowed retained plan into a plain return slot" do
    clear = transpile(<<~RUBY)
      class Plan < T::Struct
        prop :items, T::Array[String], factory: -> { [] }
      end
      class Holder < T::Struct
        prop :plan, T.nilable(Plan), default: nil
      end
      sig { params(holder: Holder).returns(Plan) }
      def require_plan(holder)
        plan = holder.plan
        raise "missing" unless plan
        plan
      end
    RUBY

    expect(clear).to match(/RETURN (?!COPY )plan_value;/)
  end

  it "initializes a projected optional union field before narrowing it" do
    clear = transpile(<<~RUBY)
      class Range < T::Struct
        const :finish, Integer
      end
      module Node
        extend T::Helpers
        sealed!
        sig { returns(T.nilable(Range)) }
        def range
          T.cast(@range, T.nilable(Range))
        end
      end
      class Item < T::Struct
        include Node
      end
      sig { params(node: Node).returns(Integer) }
      def finish(node)
        source_range = node.range
        raise "missing" unless source_range
        range = T.cast(source_range, Range)
        range.finish
      end
    RUBY

    expect(clear).to match(/MUTABLE source_range: (?:Any|\?Range) = NIL/)
    expect(clear).not_to include("MUTABLE range: Range = NIL")
  end

  it "propagates an explicitly fallible instance reader" do
    clear = transpile(<<~RUBY)
      class Value
        extend T::Sig
        sig { returns(T.nilable(String)) }
        # ruby-to-clear: fallible
        def name
          raise "missing"
        end
      end
      sig { params(value: Value).returns(T.nilable(String)) }
      def read_name(value)
        value.name
      end
    RUBY

    expect(clear).to include("FN value__name(self: Value) RETURNS !?String")
    expect(clear).to include("RETURN TRY (value__name(value));")
  end

  it "upcasts a concrete expression kind at a TypeExpression factory boundary" do
    clear = transpile(<<~RUBY)
      module Kind
        extend T::Helpers
        sealed!
      end
      class Stream < T::Struct
        include Kind
      end
      class Expression < T::Struct
        extend T::Sig
        sig { params(kind: Kind).returns(Expression) }
        def self.of(kind)
          new
        end
      end
      sig { returns(Expression) }
      def stream_expression
        stream = Stream.new
        Expression.of(T.cast(stream, Kind))
      end
    RUBY

    expect(clear).to match(/expression__of\(CAST\(stream AS Kind\)\)/)
  end

  it "narrows a union payload with a case arm instead of a synthetic cast helper" do
    clear = transpile(<<~RUBY)
      class Type < T::Struct
      end
      Payload = T.type_alias { T.nilable(T.any(String, Symbol, Type)) }
      sig { params(payload: Payload).returns(T::Boolean) }
      def type_payload?(payload)
        case payload
        when Type
          payload == payload
        else
          false
        end
      end
    RUBY

    expect(clear).to include("Payload.Type AS type")
    expect(clear).not_to include("castOptionalPayloadToType")
  end

  it "upcasts a concrete union member before looking it up in a union array" do
    clear = transpile(<<~RUBY)
      module Node
        extend T::Helpers
        sealed!
      end
      class Conditional < T::Struct
        include Node
      end
      sig { params(nodes: T::Array[Node], conditional: Conditional).returns(T.nilable(Integer)) }
      def conditional_index(nodes, conditional)
        nodes.index(T.cast(conditional, Node))
      end
    RUBY

    expect(clear).to match(/nodes\.indexOf\(CAST\(conditional AS Node\)\)/)
  end

  it "uses the narrowed variant for inherited AST metadata readers" do
    clear = transpile(<<~RUBY)
      class Binary < T::Struct
        extend T::Sig
        const :type, String
        sig { returns(String) }
        def full_type!
          type
        end
      end
      sig { params(node: T.nilable(Binary)).returns(T.nilable(String)) }
      def full_type(node)
        return nil unless node.is_a?(Binary)
        binary = T.cast(node, Binary)
        binary.full_type!
      end
    RUBY

    expect(clear).to include("binary__full_type_mut")
    expect(clear).not_to include(".full_type_mut()")
  end

  it "scans a String with a regex block through a dedicated scanner" do
    helper_config = File.expand_path("../config/compiler_regex_helpers.json", __dir__)
    clear = RubyToClear.transpile(<<~RUBY, helper_config: helper_config)
      sig { params(source: String).returns(T::Set[String]) }
      def names(source)
        names = T.let(Set.new, T::Set[String])
        source.scan(/name=(\\w+)/) { |match| names.add(T.must(match[0])) }
        names
      end
    RUBY

    expect(clear).to include("compilerRegexScanner(source)")
    expect(clear).to include("compilerRegexCapture(")
    expect(clear).not_to match(/compilerRegexScan\(source,/)
  end

  it "types heterogeneous rest arguments as the declared union array" do
    clear = transpile(<<~RUBY)
      Value = T.type_alias { T.nilable(T.any(String, Symbol, Integer)) }
      sig { params(values: T::Array[Value]).void }
      def consume(values); end
      sig { params(values: Value).void }
      def forward(*values)
        consume(values)
      end
    RUBY
    expect(clear).to include("values: []?Value")
  end

  it "checks a typed prefix with an indexed loop" do
    clear = transpile(<<~RUBY)
      class Layer < T::Struct
        const :future, T::Boolean
      end
      sig { params(layers: T::Array[Layer], limit: Integer).returns(T::Boolean) }
      def future_before?(layers, limit)
        index = T.let(0, Integer)
        while index < limit
          return true if T.must(layers[index]).future
          index += 1
        end
        false
      end
    RUBY
    expect(clear).to include("layers[index")
    expect(clear).not_to include("|> LIMIT")
  end

  it "unwraps an optional union payload before runtime narrowing" do
    clear = transpile(<<~RUBY)
      class Item < T::Struct; end
      Payload = T.type_alias { T.nilable(T.any(Item, String)) }
      sig { params(payload: Payload).returns(T::Boolean) }
      def item?(payload)
        return false unless payload
        case payload
        when Item then true
        else false
        end
      end
    RUBY
    expect(clear).to match(/payload EXISTS AS payload_value/)
  end

  it "finds a concrete variant in a union array with a typed cursor" do
    clear = transpile(<<~RUBY)
      module Node; extend T::Helpers; sealed!; end
      class Item < T::Struct; include Node; const :id, Integer; end
      sig { params(nodes: T::Array[Node], wanted: Item).returns(T.nilable(Integer)) }
      def find_item(nodes, wanted)
        index = T.let(0, Integer)
        while index < nodes.length
          candidate = nodes.fetch(index)
          return index if candidate.is_a?(Item) && T.cast(candidate, Item) == wanted
          index += 1
        end
        nil
      end
    RUBY
    expect(clear).not_to include(".indexOf(")
  end

  it "uses a typed metadata field instead of an unavailable inherited mutator" do
    clear = transpile(<<~RUBY)
      class Type < T::Struct; end
      class Node < T::Struct
        const :type_object, T.nilable(Type)
      end
      sig { params(node: Node).returns(Type) }
      def node_type(node)
        value = node.type_object
        raise "missing" unless value
        T.cast(value, Type)
      end
    RUBY
    expect(clear).not_to include(".full_type_mut()")
  end

  it "calls a static helper with a concretely narrowed optional node" do
    clear = transpile(<<~RUBY)
      class Node < T::Struct; end
      class Type
        sig { params(node: Node).returns(Type) }
        def self.from_node!(node); new; end
      end
      sig { params(node: T.nilable(Node)).returns(T.nilable(Type)) }
      def type_for(node)
        return nil unless node
        concrete = T.cast(node, Node)
        Type.from_node!(concrete)
      end
    RUBY
    expect(clear).to include("type__from_node_mut")
    expect(clear).not_to include("&concrete")
  end

  it "tests an array result by length despite unrelated empty predicates" do
    clear = transpile(<<~RUBY)
      class Plan
        sig { returns(T::Boolean) }
        def empty?; true; end
      end
      sig { params(values: T::Array[String]).returns(T::Boolean) }
      def no_values?(values)
        values.length == 0
      end
    RUBY
    expect(clear).to include("values.length() == 0")
    expect(clear).not_to include("plan__empty?(values)")
  end

  it "uses early returns for optional heap-backed activity flags" do
    clear = transpile(<<~RUBY)
      sig { params(first: T.nilable(String), second: T.nilable(String), enabled: T::Boolean).returns(T::Boolean) }
      def active?(first, second, enabled)
        return true unless first.nil?
        return true unless second.nil?
        return true if enabled
        false
      end
    RUBY
    expect(clear).not_to include("RETURN !(!(")
  end

  it "selects a diagnostic class through a typed host predicate" do
    clear = transpile(<<~RUBY)
      sig { params(parser_host: T::Boolean).returns(String) }
      def error_class(parser_host)
        parser_host ? "ParserError" : "CompilerError"
      end
    RUBY
    expect(clear).not_to include(".name()")
  end

  it "computes filtered navigation markers through a helper" do
    clear = transpile(<<~RUBY)
      sig { params(values: T::Array[String], marker: String).returns(T::Boolean) }
      def valid_marker?(values, marker)
        values.reject(&:empty?).include?(marker)
      end
    RUBY
    expect(clear).not_to include("valid_tense_orders")
  end

  it "does not export a data-only static API whose body mutates a union field" do
    ast_clear = RubyToClear.transpile(<<~RUBY)
      # ruby-to-clear: data-only
      module AST
        sig { params(value: Integer).returns(Integer) }
        def self.stamp!(value)
          value
        end
      end
    RUBY
    expect(ast_clear).not_to include("aST__stamp_mut")
  end

  it "types an optional regex match local explicitly" do
    helper_config = File.expand_path("../config/compiler_regex_helpers.json", __dir__)
    clear = RubyToClear.transpile(<<~RUBY, helper_config: helper_config)
      sig { params(line: String).returns(T.nilable(String)) }
      def capture(line)
        match = T.let(line.match(/(\\w+)/), T.nilable(MatchData))
        return nil unless match
        T.must(match[1])
      end
    RUBY
    expect(clear).to include("MUTABLE match: ?CompilerRegexScanner")
  end

  it "looks up an optional map with statement control flow" do
    clear = transpile(<<~RUBY)
      sig { params(values: T.nilable(T::Hash[String, String]), name: String).returns(T.nilable(String)) }
      def lookup(values, name)
        map = values
        if map
          found = map[name]
          return found if found
        end
        nil
      end
    RUBY
    expect(clear).not_to include("MUTABLE found: ?String = (IF")
  end

  it "raises a parser-specific diagnostic without selecting a heap type in an IF expression" do
    clear = transpile_compiler("ast/parser/state.rb")

    expect(clear).to include("IF clearParser__parser_error_host?")
    expect(clear).not_to include("MUTABLE err_class = IF")
  end

  it "materializes navigation markers locally instead of referencing an unexported constant" do
    clear = transpile_compiler("semantic/tense_operation_plan.rb")

    expect(clear).to include('["!", "?", "!?", "~", "~!", "~?", "~!?", "!~", "!~!", "!~?", "!~!?"]')
    expect(clear).not_to include("valid_tense_orders")
    expect(clear).not_to include(".take_while")
    expect(clear).not_to include("UNNEST _.layers")
    expect(clear).not_to include("RETURN ([fallible, optional])")
  end

  it "does not redeclare the imported TypeShape class as a local union" do
    clear = transpile_compiler("annotator/helpers/generic_analysis.rb")

    expect(clear).to include("UNION AnnotationTypeShape")
    expect(clear).not_to include("UNION TypeShape {")
  end

  it "uses the concrete Type surface-name helper without synthesizing a union cast" do
    clear = transpile_compiler("annotator/helpers/union.rb")

    expect(clear).to include("type__coercion_surface_name_type(payload_type)")
    expect(clear).not_to include("castTypeToTypeTypeInput")
  end

  it "writes StringConcat's physical metadata fields" do
    clear = transpile_compiler("mir/rewriters/string_concat_rewriter.rb")

    expect(clear).to include("concat.type_object = concrete_type")
    expect(clear).to include("concat.storage_override =")
    expect(clear).not_to include("concat.full_type =")
    expect(clear).not_to include("SELECT TRY (stringConcatRewriter__rewrite_in_node")
    expect(clear).not_to include("function_def.body =")
    expect(clear).to include("matchCase__body")
    expect(clear).not_to include("&match_statement_mutable.default_case")
    expect(clear).not_to include("b IS_A []Any")
    expect(clear).not_to include("struct_lit.fields.keys()")
    expect(clear).not_to include("MUTABLE key = keys[index]")
    expect(clear).not_to include("RETURN binary_op.string_concat")
    expect(clear).not_to include("RETURN string_concat.parts")
    expect(clear).not_to include("node.left()")
    expect(clear).not_to include("node.right()")
  end

  it "narrows a Locatable before reading a GetField target" do
    clear = transpile_compiler("mir/lower/pipeline/pipeline_context.rb")

    expect(clear).to include("PARTIAL MATCH node START")
    expect(clear).not_to include("node.target()")
    expect(clear).not_to include("get_field.target.name()")
    expect(clear).not_to include("SELECT from non-list type Any")
    expect(clear).not_to include("TRUE AND node.string_concat")
    expect(clear).not_to include("binaryOp__string_concat?")
    expect(clear).not_to include("aST__stamp_synthetic_type")
    expect(clear).not_to include("node.value()")
    expect(clear).not_to include("_.body()")
    expect(clear).not_to include("arm.body()")
    expect(clear).not_to include("arm.family()")
    expect(clear).not_to include("arm.lock_error_clauses()")
    expect(clear).not_to include("arm.token()")
    expect(clear).not_to include(".transform_values")
    expect(clear).to match(/substitute_assignment_target.*AssignmentName.*RETURNS !?AssignmentName/)
    expect(clear).not_to include("rtoc_ternary_value_2: ?Locatable")
    expect(clear).to match(
      /FN pipelinePlaceholderRewriter__copy_type_info\([^)]*src: PipelineRewriteNode, MUTABLE dst: PipelineRewriteNode/,
    )
  end

  it "splits imported Zig text into lines without an unsupported String each_line call" do
    clear = transpile_compiler("ffi/c_header_importer.rb")

    expect(clear).to include('zig_source.split("\\n")')
    expect(clear).not_to include(".each_line")
    expect(clear).not_to include('.split("\\n") |> SELECT:?')
    expect(clear).not_to include("aliases.keys() |> EACH")
  end

  it "reads a NEXT suspend type from typed node metadata without an unexported Type helper" do
    clear = transpile_compiler("mir/fsm_transform/segments.rb")

    expect(clear).to include("nextSuspend__result_type")
    expect(clear).not_to include("type__from_node_mut")
    expect(clear).not_to include("with_node: Any@multiowned")
    expect(clear).not_to include("body: []Node")
    expect(clear).not_to include("flush.call")
    expect(clear).not_to include("body.substr")
    expect(clear).not_to include("loop_node: Any")
    expect(clear).not_to include("raw_body_branch_value")
    expect(clear).not_to include("IF NIL EXISTS AS sus_idx_value")
    expect(clear).not_to include("classify_suspend(loop_body_value[")
    expect(clear).not_to include("suspend_tail?(UNWRAP")
    expect(clear).not_to include("stmts_value IS_A []Any")
    expect(clear).not_to include("items[rtoc_idx] IS_A")
    expect(clear).not_to include("stmt.do_branch()")
    expect(clear).not_to include("stmt.body()")
    expect(clear).not_to include("stmt.then_branch()")
    expect(clear).not_to include("if_stmt.else_branch OR")
    expect(clear).not_to include("IF v IS_A FuncCall")
  end

  it "preserves concrete call target and argument element types in data-only AST fields" do
    clear = transpile_compiler("ast/ast.rb")

    expect(clear).to match(/STRUCT FuncCall \{[^}]*args: \[\]Locatable/m)
    expect(clear).to match(/STRUCT MethodCall \{[^}]*object: Locatable[^}]*args: \[\]Locatable/m)
    expect(clear).to match(/STRUCT StructLit \{[^}]*fields: \{String\}Locatable/m)
    expect(clear).to match(/STRUCT MatchStatement \{[^}]*cases: \[\]MatchCase[^}]*default_case: \?\[\]Locatable/m)
    expect(clear).to match(/STRUCT WhileLoop \{[^}]*condition: Locatable[^}]*do_branch: \[\]Locatable/m)
    expect(clear).to match(/STRUCT WhileBindLoop \{[^}]*condition: Locatable[^}]*do_branch: \[\]Locatable/m)
    expect(clear).to match(/STRUCT CopyNode \{[^}]*value: Locatable/m)
    expect(clear).to match(/STRUCT MoveNode \{[^}]*value: Locatable/m)
    expect(clear).to match(/STRUCT KeepNode \{[^}]*value: Locatable/m)
    expect(clear).to match(/STRUCT ShareNode \{[^}]*value: Locatable/m)
    expect(clear).to match(/STRUCT BlockExpr \{[^}]*body: \[\]Locatable[^}]*result: \?Locatable/m)
    expect(clear).to match(/STRUCT StringConcat \{[^}]*parts: \[\]Locatable/m)
    expect(clear).to match(/STRUCT WithBlock \{[^}]*body: \[\]Locatable/m)
    expect(clear).to match(/STRUCT Assignment \{[^}]*name: AssignmentName[^}]*value: Locatable/m)
    expect(clear).to match(/STRUCT ListLit \{[^}]*items: \[\]Locatable/m)
    expect(clear).to match(/STRUCT HashLit \{[^}]*pairs: \{Locatable\}Locatable/m)
    expect(clear).to match(/STRUCT IfStatement \{[^}]*condition: Locatable[^}]*then_branch: \[\]Locatable[^}]*else_branch: \?\[\]Locatable/m)
    expect(clear).to include("PUB FN matchCase__body")
    expect(clear).to include("PUB FN withMatchArm__body_nodes")
    expect(clear).to include("PUB FN withMatchArm__family_value")
    expect(clear).to include("PUB FN withMatchArm__lock_error_clauses_value")
    expect(clear).to include("PUB FN withMatchArm__token_value")
    expect(clear).to match(
      /PUB FN aST__copy_pipeline_rewrite_metadata_mut\(MUTABLE dst: PipelineRewriteNode, src: PipelineRewriteNode,[^)]*\) RETURNS PipelineRewriteNode/,
    )
    expect(clear).to include("UNION PipelineRewriteNode")
    expect(clear).not_to include("item_mutable.type_object = UNWRAP")
    expect(clear).not_to include("item_mutable.tense_plan = UNWRAP")
    expect(clear).not_to include("dst.coerced_type =")
    expect(clear).not_to include("dst.storage =")
    expect(clear).not_to include('respondsTo?(src, "retain_error_channel")')
    expect(clear).to include("FN binaryOp__retain_error_channel")
    expect(clear).to include("FN funcCall__retain_error_channel")
    expect(clear).to include("FN methodCall__retain_error_channel")
    expect(clear).to match(/FN binaryOp__retain_error_channel\(self: BinaryOp\)/)
    expect(clear).to match(/FN funcCall__retain_error_channel\(self: FuncCall\)/)
    expect(clear).to match(/FN methodCall__retain_error_channel\(self: MethodCall\)/)
    expect(clear).not_to include("PUB FN funcCall__explicit_mutable_argument_tokens")
    expect(clear).not_to include("PUB FN methodCall__explicit_mutable_argument_tokens")
    expect(clear).not_to include("PUB FN methodCall__explicit_mutable_receiver_token(")
    expect(clear).to include("PUB FN methodCall__explicit_mutable_receiver_token_value")
  end

  it "emits the function-call union used by signature sites under an unambiguous name" do
    clear = transpile_compiler("annotator/helpers/function_analysis.rb")

    expect(clear).to include("UNION FunctionCallNode")
    expect(clear).not_to include("node: CallNode")
    expect(clear).to match(/callSignatureSite__assign_signature_mut\(MUTABLE self:/)
    expect(clear).not_to include(".first().equal?")
    expect(clear).to include("methodCall__explicit_mutable_receiver?")
    expect(clear).to include("methodCall__explicit_mutable_receiver_token_value")
    expect(clear).to include("methodCall__explicit_mutable_argument?")
    expect(clear).not_to include("self.node.explicit_mutable_argument")
    expect(clear).not_to include("self.params.substr")
  end

  it "propagates the selector leaf-type invariant failure through its wrapper" do
    clear = transpile_compiler("annotator/helpers/pipe_analysis.rb")

    expect(clear).to match(/selectorEffectFact__leaf_type.*RETURNS !Type/)
  end

  it "copies a retained optional string before returning it from a collection" do
    clear = transpile_compiler("annotator/protocol_projection_resolver.rb")

    expect(clear).to include("RETURN COPY result_value")
    expect(clear).not_to include("RETURN matching.first()")
    expect(clear).not_to include(".transform_values")
  end

  it "copies extern type-parameter arrays returned from AST fields" do
    clear = transpile_compiler("annotator/phases/signature_registry.rb")

    expect(clear).to include("COPY node.fn_type_params")
    expect(clear).to include("COPY node.owner_type_params")
    expect(clear).not_to include("signatureRegistry__fn_type_params")
    expect(clear).not_to include("signatureRegistry__owner_type_params")
  end

  it "reads an optional SymbolEntry binding id without copying the heap value" do
    clear = transpile_compiler("semantic/ownership_transport.rb")

    expect(clear).to include("RETURN ((node.symbol)?).ownership_binding_id")
    expect(clear).not_to include("MUTABLE symbol: ?SymbolEntry = COPY node.symbol")
  end

  it "recognizes canonical prefix-array field metadata as array-shaped" do
    clear = transpile(<<~RUBY)
      module CanonicalArrayField
        Items = Struct.new(:values) do
          # ruby-to-clear: field-type values=[]String
        end

        sig { params(items: Items).returns(T::Array[String]) }
        def self.values(items)
          items.values.each_with_index.map { |value, _index| value }
        end
      end
    RUBY

    expect(clear).to include("values: []String")
    expect(clear).not_to include("each_with_index requires an array-shaped collection")
  end
end
