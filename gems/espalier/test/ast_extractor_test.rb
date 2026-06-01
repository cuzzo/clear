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
end
