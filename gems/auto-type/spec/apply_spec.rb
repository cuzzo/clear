# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AutoType::Apply do
  def applier
    described_class.new(["--all"])
  end

  it "refuses raw --all because review actions require verification" do
    NilKill::Store.new.write

    expect {
      described_class.new(["--all"]).run
    }.to raise_error(SystemExit).and output(/apply --all.*without verification/).to_stderr
  end

  it "adds sigs with sorbet runtime and T::Sig extension" do
    _path, rel = repo_tmp_file("apply_add_sig.rb", <<~RUBY)
      class Example
        def name(value)
          value.to_s
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "add_sig", "confidence" => "high", "path" => rel, "line" => 2,
        "data" => { "sig" => "sig { params(value: String).returns(String) }", "scope" => ["Example"] } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("require \"sorbet-runtime\"")
    expect(source).to include("extend T::Sig")
    expect(source).to include("sig { params(value: String).returns(String) }\n  def name(value)")
  end

  # Regression for the c34cc62f corruption: an add_sig whose `line` is
  # STALE (the source shifted under it, e.g. a rebase) must NEVER be
  # blindly inserted at that raw index -- that drops the sig as dead
  # code mid-body / before module_function and poisons sorbet-runtime.
  # It must relocate to the real def (matched by method name) or skip.
  it "relocates a stale-line add_sig to the correct def; never corrupts mid-body" do
    _path, rel = repo_tmp_file("apply_stale_sig.rb", <<~RUBY)
      class PR
        def scan(source)
          i = 0
          while i < source.length
            if terminator?(source, i)
              return i
            end
          end
          i
        end

        def expression_terminator_op?(source, j)
          source[j, 2] == "=="
        end
      end
    RUBY

    # line 6 = `return i`, deep inside scan's body -- NOT the def at 12.
    applier.apply_actions([
      { "kind" => "add_sig", "confidence" => "high", "path" => rel, "line" => 6,
        "data" => { "sig" => "sig { params(source: String, j: Integer).returns(T::Boolean) }",
                    "scope" => ["PR"], "method" => "expression_terminator_op?" } },
    ])

    src = File.read(File.join(NilKill::ROOT, rel))
    expect(src).to include(
      "sig { params(source: String, j: Integer).returns(T::Boolean) }\n  def expression_terminator_op?(source, j)"
    )
    expect(src).not_to match(/return i\n\s*sig \{/) # not dead code after return
    expect(src.scan(/sig \{ params\(source: String/).size).to eq(1)
  end

  it "applies signature and T.let rewrites without touching unrelated lines" do
    _path, rel = repo_tmp_file("apply_rewrites.rb", <<~RUBY)
      class Example
        sig { params(raw: T.untyped, items: T::Array[T.untyped], opts: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }
        def convert(raw, items, opts)
          @memo = []
          local = value
          items
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "fix_sig_param", "confidence" => "high", "path" => rel, "line" => 3,
        "data" => { "name" => "raw", "type" => "String" } },
      { "kind" => "narrow_generic_param", "confidence" => "high", "path" => rel, "line" => 3,
        "data" => { "name" => "opts", "from" => "T::Hash[T.untyped, T.untyped]", "type" => "T::Hash[Symbol, String]" } },
      { "kind" => "narrow_generic_return", "confidence" => "high", "path" => rel, "line" => 3,
        "data" => { "from" => "T::Array[T.untyped]", "type" => "T::Array[String]" } },
      { "kind" => "add_tlet", "confidence" => "high", "path" => rel, "line" => 5,
        "data" => { "name" => "local", "type" => "String" } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("raw: String")
    expect(source).to include("opts: T::Hash[Symbol, String]")
    expect(source).to include("returns(T::Array[String])")
    expect(source).to include("local = T.let(value, String)")
    expect(source).to include("@memo = []")
  end

  it "rewrites T.untyped returns to void when requested" do
    _path, rel = repo_tmp_file("apply_void_return.rb", <<~RUBY)
      class Example
        sig { returns(T.untyped) }
        def emit
          puts "event"
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "fix_sig_return", "confidence" => "high", "path" => rel, "line" => 3,
        "data" => { "type" => "void" } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("sig { void }")
    expect(source).not_to include("returns(T.untyped)")
  end

  it "rewrites a T.untyped return to a concrete sorbet type" do
    _path, rel = repo_tmp_file("apply_concrete_return.rb", <<~RUBY)
      class Example
        sig { returns(T.untyped) }
        def label
          "hello"
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "fix_sig_return", "confidence" => "review", "path" => rel, "line" => 3,
        "data" => { "type" => "String", "source" => "forwarded_return_chain", "chain" => ["a"] } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("sig { returns(String) }")
    expect(source).not_to include("returns(T.untyped)")
  end

  it "applies nilable generic narrowing without dropping the nilable wrapper" do
    _path, rel = repo_tmp_file("apply_nilable_generic_rewrites.rb", <<~RUBY)
      class Example
        sig { params(items: T.nilable(T::Array[T.untyped])).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
        def convert(items)
          {}
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "narrow_generic_param", "confidence" => "high", "path" => rel, "line" => 3,
        "data" => { "name" => "items", "from" => "T.nilable(T::Array[T.untyped])", "type" => "T.nilable(T::Array[String])" } },
      { "kind" => "narrow_generic_return", "confidence" => "high", "path" => rel, "line" => 3,
        "data" => { "from" => "T.nilable(T::Hash[T.untyped, T.untyped])", "type" => "T.nilable(T::Hash[Symbol, String])" } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("items: T.nilable(T::Array[String])")
    expect(source).to include("returns(T.nilable(T::Hash[Symbol, String]))")
  end

  it "applies nil-check and nil-default rewrites narrowly" do
    _path, rel = repo_tmp_file("apply_nil_rewrites.rb", <<~RUBY)
      def run(reason, resolved)
        puts(reason.nil?)
        resolved&.dig(:name)
        consume(nil)
      end
    RUBY

    applier.apply_actions([
      { "kind" => "replace_dead_nil_check", "confidence" => "high", "path" => rel, "line" => 2,
        "data" => { "code" => "reason.nil?" } },
      { "kind" => "remove_dead_safe_nav", "confidence" => "high", "path" => rel, "line" => 3,
        "data" => { "code" => "resolved&.dig(:name)" } },
      { "kind" => "replace_nil_with_default", "confidence" => "high", "path" => rel, "line" => 4,
        "data" => { "default" => "[]" } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("puts(false)")
    expect(source).to include("resolved.dig(:name)")
    expect(source).to include("consume([])")
  end

  it "does not rewrite nil defaults when a line has multiple nil literals" do
    _path, rel = repo_tmp_file("apply_nil_guard.rb", "consume(nil, nil)\n")

    changed = applier.apply_actions([
      { "kind" => "replace_nil_with_default", "confidence" => "high", "path" => rel, "line" => 1,
        "data" => { "default" => "[]" } },
    ])

    expect(changed).to eq(0)
    expect(File.read(File.join(NilKill::ROOT, rel))).to eq("consume(nil, nil)\n")
  end

  it "applies struct-field RBI signatures with update, insert, append, and idempotent paths" do
    apply = described_class.allocate
    lines = [
      "# typed: true\n",
      "\n",
      "class AST::Foo\n",
      "  sig { returns(T.untyped) }\n",
      "  def token; end\n",
      "end\n",
      "\n",
    ]
    action = ->(class_name, field, type) do
      {
        "kind" => "add_struct_field_sig",
        "line" => 1,
        "data" => { "class" => class_name, "field" => field, "type" => type },
      }
    end

    expect(apply.send(:apply_add_struct_field_sig, lines, action.call("AST::Foo", "token", "Token"))).to be(true)
    expect(apply.send(:apply_add_struct_field_sig, lines, action.call("AST::Foo", "name", "String"))).to be(true)
    expect(apply.send(:apply_add_struct_field_sig, lines, action.call("AST::Bar", "id", "Integer"))).to be(true)
    expect(apply.send(:apply_add_struct_field_sig, lines, action.call("AST::Foo", "token", "Token"))).to be(false)

    output = lines.join
    expect(output).to include("class AST::Foo\n  sig { returns(Token) }\n  def token; end")
    expect(output).to include("  sig { returns(String) }\n  def name; end")
    expect(output).to include("class AST::Bar\n  sig { returns(Integer) }\n  def id; end\nend")
  end

  it "rewrites source T::Struct const and prop field types" do
    _path, rel = repo_tmp_file("apply_source_struct_fields.rb", <<~RUBY)
      class Example < T::Struct
        const :name, T.untyped
        prop :items, T::Array[T.untyped]
      end
    RUBY

    applier.apply_actions([
      { "kind" => "add_struct_field_sig", "confidence" => "review", "path" => rel, "line" => 2,
        "data" => { "target" => "source_field", "class" => "Example", "field" => "name",
                    "raw_field" => "name", "current_type" => "T.untyped", "type" => "String" } },
      { "kind" => "add_struct_field_sig", "confidence" => "review", "path" => rel, "line" => 3,
        "data" => { "target" => "source_field", "class" => "Example", "field" => "items",
                    "raw_field" => "items", "current_type" => "T::Array[T.untyped]", "type" => "T::Array[String]" } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("const :name, String")
    expect(source).to include("prop :items, T::Array[String]")
    expect(source).not_to include("T.untyped")
  end

  it "rewrites source ivar T.let field types" do
    _path, rel = repo_tmp_file("apply_source_ivar_field.rb", <<~RUBY)
      class Example
        def initialize
          @shape = T.let(shape, T.untyped)
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "add_struct_field_sig", "confidence" => "review", "path" => rel, "line" => 3,
        "data" => { "target" => "source_field", "class" => "Example", "field" => "shape",
                    "raw_field" => "@shape", "current_type" => "T.untyped", "type" => "TypeShape" } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("@shape = T.let(shape, TypeShape)")
    expect(source).not_to include("T.untyped")
  end

  it "inserts promoted hash-record structs after same-file constant forward references" do
    _path, rel = repo_tmp_file("apply_hash_record_forward_ref.rb", <<~RUBY)
      module MIR
        # Inserted struct references MIR::StructInit, which is defined below
        # as a constant assignment instead of a class.

        StructInit = Struct.new(:zig_type, :fields)
      end
    RUBY
    path = File.join(NilKill::ROOT, rel)
    lines = File.readlines(path)
    data = {
      "struct_name" => "NameRecord",
      "type_name" => "MIR::NameRecord",
      "scope" => ["MIR"],
      "struct_path" => path,
      "fields" => [
        { "name" => "name", "type" => "String" },
        { "name" => "value", "type" => "MIR::StructInit" },
      ],
      "nested_structs" => [],
    }

    changed = described_class.allocate.send(:insert_hash_record_struct, lines, data)

    expect(changed).to be(true)
    struct_init_line = lines.find_index { |line| line.include?("StructInit = Struct.new") }
    name_record_line = lines.find_index { |line| line.include?("class NameRecord") }
    expect(struct_init_line).not_to be_nil
    expect(name_record_line).not_to be_nil
    expect(name_record_line).to be > struct_init_line
  end

  it "promotes a local hash record to a T::Struct and rewrites literal field reads" do
    _path, rel = repo_tmp_file("apply_hash_record_struct.rb", <<~RUBY)
      class Example
        extend T::Sig

        def label
          entry = {name: "Ada", id: 1}
          "\#{entry[:name]}:\#{entry.fetch(:id)}:\#{entry[:name]}"
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "promote_hash_record_to_struct", "confidence" => "review", "path" => rel, "line" => 5,
        "data" => {
          "name" => "entry",
          "struct_name" => "EntryRecord",
          "scope" => ["Example"],
          "literal" => { "line" => 5, "code" => "{name: \"Ada\", id: 1}" },
          "fields" => [
            { "name" => "name", "type" => "String" },
            { "name" => "id", "type" => "Integer" },
          ],
          "read_rewrites" => [
            { "line" => 6, "code" => "entry[:name]", "replacement" => "entry.name" },
            { "line" => 6, "code" => "entry.fetch(:id)", "replacement" => "entry.id" },
          ],
        } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("require \"sorbet-runtime\"")
    expect(source).to include("class EntryRecord < T::Struct")
    expect(source).to include("const :name, String")
    expect(source).to include("const :id, Integer")
    expect(source).to include("entry = EntryRecord.new(name: \"Ada\", id: 1)")
    expect(source).to include('"#{entry.name}:#{entry.id}:#{entry.name}"')
  end

  it "promotes a returned hash record to a T::Struct and rewrites forwarded field reads" do
    _path, rel = repo_tmp_file("apply_return_hash_record_struct.rb", <<~RUBY)
      class Example
        extend T::Sig

        def build_user
          {name: "Ada", id: 1}
        end

        def label
          user = build_user
          "\#{user[:name]}:\#{user.fetch(:id)}"
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "promote_hash_record_to_struct", "confidence" => "review", "path" => rel, "line" => 5,
        "data" => {
          "name" => "user",
          "struct_name" => "UserRecord",
          "scope" => ["Example"],
          "literal" => { "line" => 5, "code" => "{name: \"Ada\", id: 1}" },
          "fields" => [
            { "name" => "name", "type" => "String" },
            { "name" => "id", "type" => "Integer" },
          ],
          "read_rewrites" => [
            { "line" => 10, "code" => "user[:name]", "replacement" => "user.name" },
            { "line" => 10, "code" => "user.fetch(:id)", "replacement" => "user.id" },
          ],
        } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("class UserRecord < T::Struct")
    expect(source).to include("const :name, String")
    expect(source).to include("const :id, Integer")
    expect(source).to include("UserRecord.new(name: \"Ada\", id: 1)")
    expect(source).to include('"#{user.name}:#{user.id}"')
  end

  it "promotes cluster producer hash literals including returned records and array elements" do
    _path, rel = repo_tmp_file("apply_hash_record_cluster_producers.rb", <<~RUBY)
      class Example
        extend T::Sig

        def build_user
          {name: "Ada", id: 1}
        end

        def users
          [{name: "Grace", id: 2}]
        end

        sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
        def typed_users
          [{name: "Hedy", id: 4}]
        end

        sig { returns(T::Hash[Symbol, T.untyped]) }
        def build_typed_user
          {name: "Katherine", id: 3}
        end

        sig { params(user: T::Hash[Symbol, T.untyped]).returns(String) }
        def typed_label(user)
          "\#{user[\"name\"]}:\#{user.fetch(\"id\")}"
        end

        def label
          user = build_user
          "\#{user[:name]}:\#{user.fetch(:id)}"
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review", "path" => rel, "line" => 5,
        "data" => {
          "struct_name" => "UserRecord",
          "scope" => ["Example"],
          "fields" => [
            { "name" => "name", "type" => "String", "optional" => false },
            { "name" => "id", "type" => "Integer", "optional" => false },
          ],
          "producers" => [
            { "path" => rel, "line" => 5, "code" => "{name: \"Ada\", id: 1}", "keys" => %w[name id] },
            { "path" => rel, "line" => 9, "code" => "{name: \"Grace\", id: 2}", "keys" => %w[name id] },
            { "path" => rel, "line" => 14, "code" => "{name: \"Hedy\", id: 4}", "keys" => %w[name id] },
            { "path" => rel, "line" => 19, "code" => "{name: \"Katherine\", id: 3}", "keys" => %w[name id] },
          ],
          "consumers" => [
            { "path" => rel, "line" => 24, "code" => "user[\"name\"]", "receiver" => "user", "key" => "name" },
            { "path" => rel, "line" => 24, "code" => "user.fetch(\"id\")", "receiver" => "user", "key" => "id" },
            { "path" => rel, "line" => 29, "code" => "user[:name]", "receiver" => "user", "key" => "name" },
            { "path" => rel, "line" => 29, "code" => "user.fetch(:id)", "receiver" => "user", "key" => "id" },
          ],
          "signatures" => [
            { "path" => rel, "line" => 13, "kind" => "return", "from" => "T::Array[T::Hash[Symbol, T.untyped]]", "type" => "T::Array[UserRecord]" },
            { "path" => rel, "line" => 18, "kind" => "return", "from" => "T::Hash[Symbol, T.untyped]", "type" => "UserRecord" },
            { "path" => rel, "line" => 23, "kind" => "param", "name" => "user", "from" => "T::Hash[Symbol, T.untyped]", "type" => "UserRecord" },
          ],
          "blockers" => [],
        } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("class UserRecord < T::Struct")
    expect(source).to include("UserRecord.new(name: \"Ada\", id: 1)")
    expect(source).to include("[UserRecord.new(name: \"Grace\", id: 2)]")
    expect(source).to include("[UserRecord.new(name: \"Hedy\", id: 4)]")
    expect(source).to include("returns(T::Array[UserRecord])")
    expect(source).to include("returns(UserRecord)")
    expect(source).to include("params(user: UserRecord)")
    expect(source).to include("UserRecord.new(name: \"Katherine\", id: 3)")
    expect(source).to include('"#{user.name}:#{user.id}"')
  end

  it "promotes nested hash-record array fields into nested structs" do
    _path, rel = repo_tmp_file("apply_hash_record_cluster_nested_fields.rb", <<~RUBY)
      module Example
        def self.plan
          {name: "compile", steps: [{expr: "load", id: 1}]}
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review", "path" => rel, "line" => 3,
        "data" => {
          "struct_name" => "PlanRecord",
          "type_name" => "Example::PlanRecord",
          "scope" => ["Example"],
          "struct_path" => rel,
          "fields" => [
            { "name" => "name", "type" => "String", "optional" => false },
            { "name" => "steps", "type" => "T::Array[Example::StepsRecord]", "optional" => false,
              "nested" => { "kind" => "array", "struct_name" => "StepsRecord", "type_name" => "Example::StepsRecord",
                "fields" => [
                  { "name" => "expr", "type" => "String", "optional" => false },
                  { "name" => "id", "type" => "Integer", "optional" => false },
                ] } },
          ],
          "nested_structs" => [
            { "kind" => "array", "struct_name" => "StepsRecord", "type_name" => "Example::StepsRecord",
              "fields" => [
                { "name" => "expr", "type" => "String", "optional" => false },
                { "name" => "id", "type" => "Integer", "optional" => false },
              ] },
          ],
          "producers" => [
            { "path" => rel, "line" => 3, "code" => "{name: \"compile\", steps: [{expr: \"load\", id: 1}]}", "keys" => %w[name steps] },
          ],
          "consumers" => [],
          "signatures" => [],
          "blockers" => [],
        } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("class StepsRecord < T::Struct")
    expect(source).to include("const :steps, T::Array[Example::StepsRecord]")
    expect(source).to include("Example::StepsRecord.new(expr: \"load\", id: 1)")
    expect(source).to include("Example::PlanRecord.new(name: \"compile\", steps: [Example::StepsRecord.new(expr: \"load\", id: 1)])")
  end

  it "rewrites cluster consumers across files while inserting the struct once" do
    _producer_path, producer_rel = repo_tmp_file("apply_hash_record_cluster_cross_file_producer.rb", <<~RUBY)
      class Producer
        def build_user
          {name: "Ada", id: 1}
        end
      end
    RUBY
    _consumer_path, consumer_rel = repo_tmp_file("apply_hash_record_cluster_cross_file_consumer.rb", <<~RUBY)
      class Consumer
        def label(user)
          "\#{user[:name]}:\#{user.fetch(:id)}"
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review", "path" => producer_rel, "line" => 3,
        "data" => {
          "struct_name" => "UserRecord",
          "scope" => ["Producer"],
          "fields" => [
            { "name" => "name", "type" => "String", "optional" => false },
            { "name" => "id", "type" => "Integer", "optional" => false },
          ],
          "producers" => [
            { "path" => producer_rel, "line" => 3, "code" => "{name: \"Ada\", id: 1}", "keys" => %w[name id] },
          ],
          "consumers" => [
            { "path" => consumer_rel, "line" => 3, "code" => "user[:name]", "receiver" => "user", "key" => "name" },
            { "path" => consumer_rel, "line" => 3, "code" => "user.fetch(:id)", "receiver" => "user", "key" => "id" },
          ],
          "signatures" => [],
          "blockers" => [],
        } },
    ])

    producer = File.read(File.join(NilKill::ROOT, producer_rel))
    consumer = File.read(File.join(NilKill::ROOT, consumer_rel))
    expect(producer).to include("class UserRecord < T::Struct")
    expect(producer).to include("UserRecord.new(name: \"Ada\", id: 1)")
    expect(consumer).to include('"#{user.name}:#{user.id}"')
    expect(consumer).not_to include("class UserRecord < T::Struct")
  end

  it "casts weak producer values when hash-record fields are narrowed by protocol evidence" do
    _path, rel = repo_tmp_file("apply_hash_record_cluster_cast_fields.rb", <<~RUBY)
      module AST
        module Locatable
        end
      end

      class Example
        def build(expr)
          {expr: expr, binding: nil}
        end
      end
    RUBY

    applier.apply_actions([
      { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review", "path" => rel, "line" => 8,
        "data" => {
          "struct_name" => "BindingRecord",
          "type_name" => "AST::BindingRecord",
          "scope" => ["AST"],
          "struct_path" => rel,
          "fields" => [
            { "name" => "expr", "type" => "AST::Locatable", "optional" => false, "required_members" => %w[full_type token] },
            { "name" => "binding", "type" => "NilClass", "optional" => false },
          ],
          "producers" => [
            { "path" => rel, "line" => 8, "code" => "{expr: expr, binding: nil}", "keys" => %w[expr binding] },
          ],
          "consumers" => [],
          "signatures" => [],
          "blockers" => [],
        } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("AST::BindingRecord.new(expr: T.cast(expr, AST::Locatable), binding: nil)")
    expect(source).to match(/module Locatable\n\s+end\n\s+class BindingRecord < T::Struct/)
  end

  it "rewrites hash-record signatures through parser node ranges for multiline sigs" do
    _path, rel = repo_tmp_file("apply_hash_record_cluster_multiline_sig.rb", <<~RUBY)
      class Example
        extend T::Sig

        sig do
          params(
            user: T::Hash[Symbol, T.untyped],
          )
            .returns(T::Hash[Symbol, T.untyped])
        end
        def transform(user)
          {name: user[:name], id: user.fetch(:id)}
        end
      end
    RUBY

    file = File.join(NilKill::ROOT, rel)
    lines = File.readlines(file)
    def_line = lines.index { |line| line.include?("def transform") } + 1
    body_line = lines.index { |line| line.include?("{name: user[:name]") } + 1

    applier.apply_actions([
      { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review", "path" => rel, "line" => body_line,
        "data" => {
          "struct_name" => "UserRecord",
          "scope" => ["Example"],
          "fields" => [
            { "name" => "name", "type" => "String", "optional" => false },
            { "name" => "id", "type" => "Integer", "optional" => false },
          ],
          "producers" => [
            { "path" => rel, "line" => body_line, "code" => "{name: user[:name], id: user.fetch(:id)}", "keys" => %w[name id] },
          ],
          "consumers" => [
            { "path" => rel, "line" => body_line, "code" => "user[:name]", "receiver" => "user", "key" => "name" },
            { "path" => rel, "line" => body_line, "code" => "user.fetch(:id)", "receiver" => "user", "key" => "id" },
          ],
          "signatures" => [
            { "path" => rel, "line" => def_line, "kind" => "param", "name" => "user", "from" => "T::Hash[Symbol, T.untyped]", "type" => "UserRecord" },
            { "path" => rel, "line" => def_line, "kind" => "return", "from" => "T::Hash[Symbol, T.untyped]", "type" => "UserRecord" },
          ],
          "blockers" => [],
        } },
    ])

    source = File.read(file)
    expect(source).to include("user: UserRecord")
    expect(source).to include(".returns(UserRecord)")
    expect(source).to include("UserRecord.new(name: user.name, id: user.id)")
  end

  it "emits optional hash-record fields as props and blocks untyped field clusters" do
    _path, rel = repo_tmp_file("apply_hash_record_cluster_optional.rb", <<~RUBY)
      class Example
        extend T::Sig

        def build_user
          {name: "Ada", id: 1}
        end
      end
    RUBY

    changed = applier.apply_actions([
      { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review", "path" => rel, "line" => 5,
        "data" => {
          "struct_name" => "UserRecord",
          "scope" => ["Example"],
          "fields" => [
            { "name" => "name", "type" => "String", "optional" => false },
            { "name" => "email", "type" => "T.nilable(String)", "optional" => true },
          ],
          "producers" => [
            { "path" => rel, "line" => 5, "code" => "{name: \"Ada\", id: 1}", "keys" => %w[name id] },
          ],
          "consumers" => [],
          "signatures" => [],
          "blockers" => [],
        } },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(changed).to eq(1)
    expect(source).to include("const :name, String")
    expect(source).to include("prop :email, T.nilable(String)")

    blocked_path, blocked_rel = repo_tmp_file("apply_hash_record_cluster_untyped_blocker.rb", <<~RUBY)
      class Blocked
        def build_user
          {name: "Ada", id: unknown}
        end
      end
    RUBY

    changed = applier.apply_actions([
      { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review", "path" => blocked_rel, "line" => 3,
        "data" => {
          "struct_name" => "BlockedRecord",
          "scope" => ["Blocked"],
          "fields" => [
            { "name" => "name", "type" => "String", "optional" => false },
            { "name" => "id", "type" => "T.untyped", "optional" => false },
          ],
          "producers" => [
            { "path" => blocked_rel, "line" => 3, "code" => "{name: \"Ada\", id: unknown}", "keys" => %w[name id] },
          ],
          "consumers" => [],
          "signatures" => [],
          "blockers" => ["one or more fields are still T.untyped"],
        } },
    ])

    expect(changed).to eq(0)
    expect(File.read(blocked_path)).not_to include("BlockedRecord")
  end

  skip "improves report pressure after a traceable cluster promotion" do
    _path, rel = repo_tmp_file("apply_hash_record_report_improvement.rb", <<~RUBY)
      class Example
        extend T::Sig

        sig { returns(String) }
        def label
          user = {name: "Ada", id: 1}
          "\#{user[:name]}:\#{user.fetch(:id)}"
        end
      end
    RUBY

    evidence_for = lambda do |path|
      static = NilKill::StaticEvidence.build([path], root: NilKill::ROOT, language: :ruby)
      facts = static.fetch("facts")
      {
        "facts" => {
          "hash_shapes" => facts.fetch("hash_shapes"),
          "collection_index_lookups" => facts.fetch("collection_index_lookups", []),
          "hash_record_blockers" => facts.fetch("hash_record_blockers", []),
          "return_origins" => facts.fetch("return_origins", []),
          "param_origins" => facts.fetch("param_origins", []),
          "existing_sigs" => facts.fetch("existing_sigs", []),
        },
        "methods" => [],
      }
    end

    before = evidence_for.call(File.join(NilKill::ROOT, rel))
    report = NilKill::Report.allocate
    report.instance_variable_set(:@evidence, before)
    before_candidates = report.hash_record_struct_candidates(before)

    store = NilKill::Store.new
    store.facts["hash_shapes"] = before.dig("facts", "hash_shapes")
    store.facts["collection_index_lookups"] = before.dig("facts", "collection_index_lookups")
    store.facts["hash_record_blockers"] = before.dig("facts", "hash_record_blockers")
    store.facts["return_origins"] = before.dig("facts", "return_origins")
    store.facts["param_origins"] = before.dig("facts", "param_origins")
    store.facts["existing_sigs"] = before.dig("facts", "existing_sigs")
    infer = NilKill::Infer.allocate
    infer.instance_variable_set(:@store, store)
    infer.send(:propose_hash_record_cluster_actions)
    action = store.actions.find { |candidate| candidate["kind"] == "promote_hash_record_cluster_to_struct" }

    expect(before_candidates.first["total_pressure"]).to eq(2)
    expect(action).not_to be_nil

    applier.apply_actions([action])

    after = evidence_for.call(File.join(NilKill::ROOT, rel))
    after_report = NilKill::Report.allocate
    after_report.instance_variable_set(:@evidence, after)
    after_candidates = after_report.hash_record_struct_candidates(after)

    expect(after_candidates).to be_empty
  end

  it "restores files and skips a hash-record action when verification fails" do
    _path, rel = repo_tmp_file("apply_hash_record_cluster_rollback.rb", <<~RUBY)
      class RollbackHashRecord
        def build
          {name: "Ada"}
        end
      end
    RUBY
    path = File.join(NilKill::ROOT, rel)
    original = File.read(path)
    loop = AutoType::Loop.allocate
    loop.instance_variable_set(:@skipped, Set.new)
    loop.instance_variable_set(:@z3_solver, nil)
    loop.define_singleton_method(:verify) { |actions: nil| [false, "forced verification failure"] }
    NilKill::Store.new.write
    action = { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review",
      "path" => rel, "line" => 3, "message" => "plan UserRecord",
      "data" => {
        "struct_name" => "UserRecord",
        "scope" => ["RollbackHashRecord"],
        "fields" => [{ "name" => "name", "type" => "String", "optional" => false }],
        "producers" => [{ "path" => rel, "line" => 3, "code" => "{name: \"Ada\"}", "keys" => ["name"] }],
        "consumers" => [],
        "signatures" => [],
        "blockers" => [],
      } }

    changed = loop.send(:apply_verified, [action])

    expect(changed).to eq(0)
    expect(File.read(path)).to eq(original)
    expect(loop.instance_variable_get(:@skipped)).to include(loop.send(:fingerprint, action))
  end

  it "retries verified hash-record promotion after removing useless T.cast feedback" do
    _path, rel = repo_tmp_file("apply_hash_record_useless_tcast_retry.rb", <<~RUBY)
      class CastRetryHashRecord
        def build(expr)
          {expr: T.cast(expr, String)}
        end
      end
    RUBY
    path = File.join(NilKill::ROOT, rel)
    NilKill::Store.new.write
    action = { "kind" => "promote_hash_record_cluster_to_struct", "confidence" => "review",
      "path" => rel, "line" => 3, "message" => "plan ExprRecord",
      "data" => {
        "struct_name" => "ExprRecord",
        "scope" => ["CastRetryHashRecord"],
        "fields" => [{ "name" => "expr", "type" => "String", "optional" => false }],
        "producers" => [{ "path" => rel, "line" => 3, "code" => "{expr: T.cast(expr, String)}", "keys" => ["expr"] }],
        "consumers" => [],
        "signatures" => [],
        "blockers" => [],
      } }

    loop = AutoType::Loop.allocate
    loop.instance_variable_set(:@skipped, Set.new)
    loop.instance_variable_set(:@z3_solver, nil)
    verify_calls = 0
    loop.define_singleton_method(:verify) do |actions: nil|
      verify_calls += 1
      if verify_calls == 1
        cast_line = File.readlines(path).index { |line| line.include?("T.cast(expr, String)") } + 1
        [false, <<~OUT]
          #{rel}:#{cast_line}: `T.cast` is useless because `expr` is already a `String` https://srb.help/7015
              #{rel}:#{cast_line}: Replace with `expr`
        OUT
      else
        [true, ""]
      end
    end

    changed = loop.send(:apply_verified, [action])
    source = File.read(path)

    expect(changed).to eq(2)
    expect(verify_calls).to eq(2)
    expect(source).to include("class ExprRecord < T::Struct")
    expect(source).to include("ExprRecord.new(expr: expr)")
    expect(source).not_to include("T.cast(expr, String)")
  end

  it "tools/clear-nil-kill-verify.sh runs the host spec suite (regression: prevents Sorbet-only verifier)" do
    script = File.read(File.join(NilKill::ROOT, "tools", "clear-nil-kill-verify.sh"))
    expect(script).to match(/bundle exec prspec spec\/(?:\s|$)/),
      "verify script must include `bundle exec prspec spec/` so loop changes are gated on host behavioral tests, not just `srb tc`"
  end
end
