# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/espalier"

class AstExtractorTest < Minitest::Test
  GRAMMAR_ENVS = {
    ruby: "DECOMPLEX_TS_RUBY_PATH",
    python: "DECOMPLEX_TS_PYTHON_PATH",
    javascript: "DECOMPLEX_TS_JAVASCRIPT_PATH",
    typescript: "DECOMPLEX_TS_TYPESCRIPT_PATH",
    go: "DECOMPLEX_TS_GO_PATH",
    rust: "DECOMPLEX_TS_RUST_PATH",
    zig: "DECOMPLEX_TS_ZIG_PATH"
  }.freeze

  def parse_ruby(code)
    skip_unless_grammar(:ruby)
    parse_source(code, ".rb")
  end

  def parse_zig(code)
    skip_unless_grammar(:zig)
    parse_source(code, ".zig")
  end

  def parse_source(code, ext)
    f = Tempfile.new(["espalier", ext])
    f.write(code)
    f.close
    extractor = Espalier::AstExtractor.new(f.path)
    extractor.extract
  ensure
    f&.unlink
  end

  def skip_unless_grammar(language)
    env = GRAMMAR_ENVS.fetch(language)
    grammar = ENV[env]
    skip "set #{env} to run #{language} Tree-sitter extractor test" unless grammar && File.file?(grammar)
  end

  def test_extracts_static_ivar_t_let_types
    r = parse_ruby(<<~RB)
      class TypeChecker
        def initialize
          @flag = T.let(true, T::Boolean)
          @schema = T.let(Schema.new, Schema)
        end
      end
    RB

    assert_equal 1, r.size
    mod = r.first
    assert_equal "T::Boolean", mod[:ivar_types]["@flag"]
    assert_equal "Schema", mod[:ivar_types]["@schema"]
  end

  def test_extracts_class_and_state_writes
    r = parse_ruby(<<~RB)
      class ConnectionManager
        def initialize
          @active_connections = {}
          @max_limit = 100
        end

        def connect(id)
          @active_connections = id
        end
      end
    RB

    assert_equal 1, r.size
    mod = r.first
    assert_equal "ConnectionManager", mod[:name]
    assert_equal :class, mod[:type]
    assert_equal %w[@active_connections @max_limit].to_set, mod[:states]

    # Initialize Method
    init_m = mod[:methods].find { |m| m[:name] == "initialize" }
    assert_equal %w[@active_connections @max_limit].to_set, init_m[:effects][:writes]
    assert_empty init_m[:effects][:reads]

    # Connect Method
    conn_m = mod[:methods].find { |m| m[:name] == "connect" }
    assert_equal %w[@active_connections].to_set, conn_m[:effects][:writes]
  end

  def test_extracts_delegations_conditionally_or_iterated
    r = parse_ruby(<<~RB)
      class Dispatcher
        def dispatch(item)
          if item.valid?
            Socket.send(item)
          else
            item.each do |sub|
              log_error(sub)
            end
          end
        end
      end
    RB

    mod = r.first
    m = mod[:methods].first
    
    # We filtered "each" so only valid?, Socket.send, log_error
    assert_equal 3, m[:delegations].size

    # item.valid? is conditionally called (or always depending on side)
    valid_call = m[:delegations].find { |d| d[:message] == "valid?" }
    assert_equal "item", valid_call[:receiver]

    # Socket.send is inside conditional
    send_call = m[:delegations].find { |d| d[:message] == "send" }
    assert_equal "Socket", send_call[:receiver]
    assert_equal :conditional, send_call[:type]

    # log_error is inside block context inside else
    log_call = m[:delegations].find { |d| d[:message] == "log_error" }
    assert_equal "self", log_call[:receiver]
    assert_equal :iterates, log_call[:type]
  end

  def test_extracts_method_visibility_from_access_modifiers
    r = parse_ruby(<<~RB)
      class Worker
        def run; helper; end

        private
        def helper; end

        public :helper

        protected
        def guarded; end

        private def inline_helper; end
      end
    RB

    mod = r.first
    vis = mod[:methods].to_h { |method| [method[:name], method[:visibility]] }
    assert_equal :public, vis["run"]
    assert_equal :public, vis["helper"]
    assert_equal :protected, vis["guarded"]
    assert_equal :private, vis["inline_helper"]
  end

  def test_extracts_zig_tree_sitter_owners_state_and_delegations
    mods = parse_zig(<<~ZIG)
      pub fn Box(comptime T: type) type {
          return struct {
              value: T,
              count: usize = 0,
              const Self = @This();
              pub fn init(value: T) Self {
                  return .{ .value = value, .count = 1 };
              }
              pub fn get(self: *Self) T {
                  self.count = self.count + 1;
                  self.bump();
                  return self.value;
              }
              fn bump(self: *Self) void {
                  self.count = self.count + 1;
              }
          };
      }
    ZIG

    box = mods.find { |mod| mod[:name] == "Box" }
    refute_nil box
    assert_equal :struct, box[:type]
    assert_equal :zig, box[:language]
    assert_equal %w[count value].to_set, box[:states]

    get = box[:methods].find { |method| method[:name] == "get" }
    assert_includes get[:effects][:reads], "value"
    assert_includes get[:effects][:writes], "count"
    assert_includes get[:delegations], { receiver: "self", message: "bump", type: :always }
    assert get[:line].positive?
  end

  def test_extracts_receiver_state_and_internal_delegations_across_tree_sitter_languages
    profiles = {
      python: [
        ".py",
        <<~PY,
          class Unit:
              def __init__(self, value):
                  self.value = value
              def run(self):
                  self.value = self.value + 1
                  self.bump()
              def bump(self):
                  pass
        PY
        "Unit",
        "value",
        "run",
        "bump"
      ],
      javascript: [
        ".js",
        <<~JS,
          class Unit {
            constructor(value) { this.value = value; }
            run() { this.value = this.value + 1; this.bump(); }
            bump() {}
          }
        JS
        "Unit",
        "value",
        "run",
        "bump"
      ],
      typescript: [
        ".ts",
        <<~TS,
          class Unit {
            value: number;
            constructor(value: number) { this.value = value; }
            run(): void { this.value = this.value + 1; this.bump(); }
            private bump(): void {}
          }
        TS
        "Unit",
        "value",
        "run",
        "bump"
      ],
      go: [
        ".go",
        <<~GO,
          package p
          type Unit struct { value int }
          func (u *Unit) Run() { u.value = u.value + 1; u.Bump() }
          func (u *Unit) Bump() {}
        GO
        "Unit",
        "value",
        "Run",
        "Bump"
      ],
      rust: [
        ".rs",
        <<~RS,
          struct Unit { value: i32 }
          impl Unit {
            fn run(&mut self) { self.value = self.value + 1; self.bump(); }
            fn bump(&self) {}
          }
        RS
        "Unit",
        "value",
        "run",
        "bump"
      ],
      zig: [
        ".zig",
        <<~ZIG,
          pub fn Unit() type {
            return struct {
              value: usize = 0,
              const Self = @This();
              pub fn run(self: *Self) void { self.value = self.value + 1; self.bump(); }
              fn bump(self: *Self) void {}
            };
          }
        ZIG
        "Unit",
        "value",
        "run",
        "bump"
      ]
    }

    available = profiles.select do |language, _profile|
      grammar = ENV[GRAMMAR_ENVS.fetch(language)]
      grammar && File.file?(grammar)
    end
    skip "set Tree-sitter grammar paths to run cross-language extractor test" if available.empty?

    available.each do |language, (ext, source, owner_name, state_name, run_name, bump_name)|
      mods = parse_source(source, ext)
      mod = mods.find { |candidate| candidate[:name] == owner_name }
      refute_nil mod, language
      assert_equal language, mod[:language], language
      assert_includes mod[:states], state_name, language

      run = mod[:methods].find { |method| method[:name] == run_name }
      refute_nil run, language
      assert_includes run[:effects][:writes], state_name, language
      assert_includes run[:delegations], { receiver: "self", message: bump_name, type: :always }, language
      assert run[:line].positive?, language
      refute_nil run[:span], language
    end
  end
end
