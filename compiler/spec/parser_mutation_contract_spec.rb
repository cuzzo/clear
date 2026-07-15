require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

RSpec.describe ClearParser do
  def parser_for(source)
    ClearParser.new(Lexer.new(source).tokenize, source)
  end

  describe "#parse_extern_effects" do
    it "parses absence, allocation qualifiers, safety, and comma composition directly" do
      cases = {
        "" => {},
        "EFFECTS :alloc" => { alloc: :frame },
        "EFFECTS :alloc:frame" => { alloc: :frame },
        "EFFECTS :alloc:heap" => { alloc: :heap },
        "EFFECTS :safe" => { safe: true },
        "EFFECTS :safe, :alloc:frame" => { safe: true, alloc: :frame },
      }

      cases.each do |source, expected|
        effects = parser_for(source).send(:parse_extern_effects)
        expect(effects).to be_a(ClearParser::ParsedExternEffects)
        expect(effects.to_h).to eq(expected)
      end
    end

    it "requires effect punctuation and a known effect name" do
      expect { parser_for("EFFECTS safe").send(:parse_extern_effects) }
        .to raise_error(ParserError, /Expected.*:/)
      expect { parser_for("EFFECTS :unknown").send(:parse_extern_effects) }
        .to raise_error(ParserError, /Unknown effect/)
      expect { parser_for("EFFECTS :alloc:unknown").send(:parse_extern_effects) }
        .to raise_error(ParserError, /Unknown alloc qualifier/)
    end
  end

  describe "#synthesize_default_for_type" do
    it "synthesizes one compact stack literal for every supported primitive family" do
      source = "MUTABLE values: [2]Int64;"
      token = Lexer.new(source).tokenize.first

      %i[Int64 Int32 Int16 Int8 Float64 Float32 String Bool Boolean].each do |element|
        type = Type.array_of(element, capacity: 2)
        value = parser_for(source).send(:synthesize_default_for_type, token, type)
        expect(value).to be_a(AST::DefaultArrayLit)
        expect(value.full_type).to eq(type)
        expect(value.storage).to eq(:stack)
      end
    end

    it "rejects dynamic arrays and fixed arrays of non-primitive elements" do
      source = "MUTABLE values: [2]Int64;"
      token = Lexer.new(source).tokenize.first
      parser = parser_for(source)

      expect { parser.send(:synthesize_default_for_type, token, Type.array_of(:Int64)) }
        .to raise_error(ParserError, /fixed/i)
      expect { parser.send(:synthesize_default_for_type, token, Type.array_of(:Box, capacity: 2)) }
        .to raise_error(ParserError, /cannot default-init|bare declaration/i)
    end
  end

  describe "#parse_mutable_var_decl" do
    it "distinguishes initialized, compact-defaulted, and untyped bare declarations" do
      initialized = parser_for("MUTABLE value: Int64 = 3;").send(:parse_mutable_var_decl)
      defaulted = parser_for("MUTABLE values: [2]String;").send(:parse_mutable_var_decl)

      expect([initialized.name, initialized.mutable, initialized.value.value])
        .to eq(["value", true, 3])
      expect([defaulted.name, defaulted.type.resolved, defaulted.value.class])
        .to eq(["values", :"String[2]", AST::DefaultArrayLit])
      expect { parser_for("MUTABLE value;").send(:parse_mutable_var_decl) }
        .to raise_error(ParserError, /type/i)
    end
  end

  describe "#type_annotation_source" do
    it "round-trips parsed scalar, optional, and compound capability annotations" do
      sources = [
        "Int64",
        "?String",
        "?(Counter[]@list)",
        "~String[]@set:observable",
        "String[]@list:soa:sharded(3):shared:writeLocked:observable",
      ]

      sources.each do |source|
        parser = parser_for(source)
        type = parser.send(:parse_type_annotation)
        expect(parser.send(:type_annotation_source, type)).to eq(source)
      end
    end

    it "renders every ownership and synchronization capability canonically" do
      renderer = parser_for("")
      {
        shared: "shared",
        shared_node: "shared:node",
        multiowned: "multiowned",
        link: "link",
        split: "split",
        frozen: "frozen",
      }.each do |capability, source|
        type = Type.new(:Int64, ownership: capability)
        expect(renderer.send(:type_annotation_source, type)).to eq("Int64@#{source}")
      end
      {
        locked: "locked",
        write_locked: "writeLocked",
        versioned: "versioned",
        atomic: "atomic",
        local: "local",
        always_mutable: "alwaysMutable",
      }.each do |capability, source|
        type = Type.new(:Int64, sync: capability)
        expect(renderer.send(:type_annotation_source, type)).to eq("Int64@#{source}")
      end
    end

    it "does not invent a capability delimiter for an unqualified type" do
      expect(parser_for("").send(:type_annotation_source, Type.new(:Counter))).to eq("Counter")
      pool = Type.new(:"Int64[4]", collection: :pool)
      expect(parser_for("").send(:type_annotation_source, pool)).to eq("Int64[4]@pool")
    end
  end

  describe "#mark_polymorphic_shared_type" do
    it "copies the input and marks only the copy as polymorphically shared" do
      original = Type.new(:Counter)
      marked = parser_for("").send(:mark_polymorphic_shared_type, original)

      expect(marked).not_to equal(original)
      expect([marked.ownership, marked.polymorphic_shared?]).to eq([:shared, true])
      expect([original.ownership, original.polymorphic_shared?]).to eq([:affine, false])
      expect(parser_for("").send(:type_annotation_source, marked)).to eq("SHARED Counter")
    end
  end

  describe "#parse_inline_capabilities" do
    it "preserves ownership, sync, layout, topology, sharding, soa, and observability" do
      parser = parser_for("@shared:locked:indirect:sharded(4):soa:observable")
      caps = parser.send(:parse_inline_capabilities, collection: :list)

      expect([
        caps.ownership, caps.sync, caps.layout, caps.collection,
        caps.shard_count, caps.soa, caps.observable,
      ]).to eq([:shared, :locked, :indirect, :list, 4, true, true])
    end

    it "defaults ownership and rejects a topology duplicated outside its sigil" do
      caps = parser_for("").send(:parse_inline_capabilities)
      expect([caps.ownership, caps.sync, caps.collection]).to eq([:affine, nil, nil])
      expect { parser_for("@list").send(:parse_inline_capabilities, collection: :list) }
        .to raise_error(ParserError, /collection topology/)
    end
  end

  describe "#parse_extern_fn" do
    it "preserves function, generic method, return, module, and effect metadata" do
      declarations = parser_for(<<~CLEAR).parse.statements
        EXTERN FN plain() FROM "core";
        EXTERN FN parse<T>(value: T) RETURNS T EFFECTS :safe FROM "generic";
        EXTERN FN Box<T>.read(index: Int64) RETURNS T EFFECTS :alloc:heap FROM "box";
      CLEAR

      plain, generic, method = declarations
      expect([plain.name, plain.return_type, plain.from_module, plain.effects])
        .to eq(["plain", nil, "core", {}])
      expect([generic.name, generic.fn_type_params, generic.return_type.resolved, generic.effects])
        .to eq(["parse", [:T], :T, { safe: true }])
      expect([
        method.name, method.owner_type, method.owner_type_params,
        method.params.first.name, method.effects,
      ]).to eq(["read", "Box", [:T], "index", { alloc: :heap }])
    end
  end

  describe "#parse_sync_policy_block" do
    it "preserves handler order, selector kinds, retry counts, and actions" do
      policy = parser_for(<<~CLEAR).send(:parse_sync_policy_block)
        SYNC POLICY START
          ON LockTimeout, CustomFailure RETRY(3) THEN RAISE
          RETRY(2) THEN PASS
        END
      CLEAR

      expect(policy).to be_a(AST::SyncPolicyDecl)
      expect(policy.handlers.length).to eq(2)
      expect(policy.handlers.first.selectors.map { |selector| [selector.form, selector.name] })
        .to eq([[:type, :LockTimeout], [:type, :CustomFailure]])
      expect([policy.handlers.first.retries, policy.handlers.first.action])
        .to eq([3, AST::ErrorActionKind::Raise])
      expect([policy.handlers.last.selectors.first.name, policy.handlers.last.retries,
              policy.handlers.last.action])
        .to eq([:Transient, 2, AST::ErrorActionKind::Pass])
    end

    it "rejects an empty policy and a missing terminator" do
      expect { parser_for("SYNC POLICY START END").send(:parse_sync_policy_block) }
        .to raise_error(ParserError, /handler/i)
      expect { parser_for("SYNC POLICY START ON LockTimeout RAISE").send(:parse_sync_policy_block) }
        .to raise_error(ParserError, /END/)
    end
  end

  describe "#parse_lock_error_clause" do
    it "returns nil when no clause starts and parses both clause forms" do
      expect(parser_for("").send(:parse_lock_error_clause)).to be_nil

      explicit = parser_for("ON LockTimeout, CustomFailure RETRY(4) THEN RETURN 7")
        .send(:parse_lock_error_clause)
      sugar = parser_for("RETRY(2) THEN EXIT \"failed\"").send(:parse_lock_error_clause)

      expect(explicit.selectors.map(&:name)).to eq([:LockTimeout, :CustomFailure])
      expect([explicit.retries, explicit.action, explicit.value.value])
        .to eq([4, AST::ErrorActionKind::Return, 7])
      expect([sugar.selectors.first.name, sugar.retries, sugar.action, sugar.message.value])
        .to eq([:Transient, 2, AST::ErrorActionKind::Exit, "failed"])
    end
  end

  describe "#parse_lock_action" do
    it "parses both explicit and sugar retry handlers" do
      explicit = <<~CLEAR
        FN main() RETURNS Void ->
          WITH SNAPSHOT cell AS MUTABLE value { value.x = 1; }
            ON MvccConflict RETRY(2) THEN PASS
        END
      CLEAR
      sugar = explicit.sub("ON MvccConflict RETRY(2)", "RETRY(3)")

      explicit_clause = parser_for(explicit).parse.statements.first.body.first.lock_error_clause
      sugar_clause = parser_for(sugar).parse.statements.first.body.first.lock_error_clause
      expect([explicit_clause.retries, explicit_clause.action]).to eq([2, AST::ErrorActionKind::Pass])
      expect([sugar_clause.retries, sugar_clause.selectors.first.name]).to eq([3, :Transient])
    end
  end

  describe "#parse_power" do
    it "keeps exponentiation right-associative" do
      node = parser_for("base ** exponent ** tail").send(:parse_expression)

      expect(node.op).to eq(:POW)
      expect(node.right.op).to eq(:POW)
      expect([node.left.name, node.right.left.name, node.right.right.name])
        .to eq(%w[base exponent tail])
    end
  end
end

RSpec.describe ClearParser::ParsedExternEffects do
  describe "#to_h" do
    it "emits the four fixed compatibility shapes" do
      expect(described_class.new.to_h).to eq({})
      expect(described_class.new(alloc: :heap).to_h).to eq({ alloc: :heap })
      expect(described_class.new(safe: true).to_h).to eq({ safe: true })
      expect(described_class.new(alloc: :frame, safe: true).to_h)
        .to eq({ alloc: :frame, safe: true })
    end
  end
end
