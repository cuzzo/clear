# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/espalier"

class AstExtractorTest < Minitest::Test
  def parse_ruby(code)
    f = Tempfile.new(["espalier", ".rb"])
    f.write(code)
    f.close
    extractor = Espalier::AstExtractor.new(f.path)
    extractor.extract
  ensure
    f&.unlink
  end

  def parse_zig(code)
    f = Tempfile.new(["espalier", ".zig"])
    f.write(code)
    f.close
    extractor = Espalier::AstExtractor.new(f.path)
    extractor.extract
  ensure
    f&.unlink
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
    grammar = ENV["DECOMPLEX_TS_ZIG_PATH"]
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig Tree-sitter extractor test" unless grammar && File.file?(grammar)

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
end
