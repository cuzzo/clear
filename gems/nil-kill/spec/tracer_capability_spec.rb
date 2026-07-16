# frozen_string_literal: true
#
# Tracer-capability matrix -- a self-contained MINI-COLLECT per case,
# faithful to production B1: TracePlan.write -> instrument every target
# file IN PLACE (one wrapped copy at the real path, .nk-linemap.json)
# -> a driver that loads the real src -> run under the tracer. There
# is no parallel tree and no require-redirect: every load mechanism
# loads the wrapped code. A red case is a genuine tracer gap. The
# shared harness lives in spec/support/mini_collect.rb.

require_relative "spec_helper"

RSpec.describe "nil-kill tracer capability matrix" do
  # mini_collect / in_tmp / lib come from MiniCollect (spec/support).

  # ---- METHOD SHAPES ---------------------------------------------------

  it "plain + endless def" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def calc(v) = v.to_s
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.calc(7)\n))
      expect(r[:status]).to be_success, r[:err]
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "calc",
        "params_by_name" => a_hash_including("v" => include("Integer")),
        "returns" => include("String")
      ))
    end
  end

  it "one-line classic def" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def calc(v); v.to_s; end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.calc(9)\n))
      expect(r[:methods]).to include(a_hash_including("class" => "W", "method" => "calc", "returns" => include("String")))
    end
  end

  it "method with ensure is source wrapped" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def calc(v)
            v.to_s
          ensure
            nil
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.calc(11)\n))
      expect(r[:status]).to be_success, r[:err]
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "calc",
        "params_by_name" => a_hash_including("v" => include("Integer")),
        "returns" => include("String")
      ))
    end
  end

  it "records runtime method edges for source-wrapped calls" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def outer(v)
            inner(v)
          end

          sig { params(v: T.untyped).returns(T.untyped) }
          def inner(v)
            v.to_s
          end
        end
      RUBY

      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.outer(11)\n))

      expect(r[:status]).to be_success, r[:err]
      expect(r[:method_edges]).to include(a_hash_including(
        "caller" => a_hash_including("class" => "W", "method" => "outer", "kind" => "instance"),
        "callee" => a_hash_including("class" => "W", "method" => "inner", "kind" => "instance"),
        "calls" => 1,
        "ok_calls" => 1,
        "raised_calls" => 0
      ))
    end
  end

  it "prunes a typed caller without losing evidence from an unresolved callee" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: String).returns(String) }
          def outer(v)
            inner(v)
          end

          sig { params(v: T.untyped).returns(T.untyped) }
          def inner(v)
            v.upcase
          end
        end
      RUBY

      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.outer("ok")\n))

      expect(r[:status]).to be_success, r[:err]
      expect(r[:instr_lib]).not_to include('record_source_method_call("W", "outer"')
      expect(r[:instr_lib]).to include('record_source_method_call("W", "inner"')
      expect(r[:methods]).not_to include(a_hash_including("class" => "W", "method" => "outer"))
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "inner", "calls" => 1,
        "params_by_name" => a_hash_including("v" => ["String"]),
        "returns" => ["String"]
      ))
      expect(r[:method_edges]).to be_empty
    end
  end

  it "elides resolved ivars while retaining unresolved ivar evidence" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig

          sig { void }
          def initialize
            @resolved = T.let("known", String)
            @unresolved = T.let("observed", T.untyped)
          end
        end
      RUBY

      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new\n))

      expect(r[:status]).to be_success, r[:err]
      expect(r[:ivars]).to include(a_hash_including(
        "class" => "W", "name" => "@unresolved", "classes" => ["String"]
      ))
      expect(r[:ivars]).not_to include(a_hash_including("class" => "W", "name" => "@resolved"))
    end
  end

  it "return inside an iterator block: SOURCE-WRAPPED (not punted), records the returned value" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(xs: T.untyped).returns(T.untyped) }
          def first(xs)
            xs.each { |x| return x.to_s if x }
            ""
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.first([41])\n))
      expect(r[:status]).to be_success, r[:err]
      expect(r[:instr_lib]).to include('record_source_method_call("W", "first"')                 # NOT punted
      expect(r[:instr_lib]).to include("return NilKillRuntimeTrace.record_source_method_return") # block return rewritten
      expect(r[:instr_lib]).not_to include("catch(")
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "first", "returns" => include("String")
      ))
    end
  end

  it "nested-block return (each{ map{ return } }): records the returned value" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(xs: T.untyped).returns(T.untyped) }
          def deep(xs)
            xs.each { |row| row.map { |c| return c.to_s if c } }
            :none
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.deep([[7]])\n))
      expect(r[:status]).to be_success, r[:err]
      expect(r[:methods]).to include(a_hash_including("class" => "W", "method" => "deep", "returns" => include("String")))
    end
  end

  it "proc{ return } (non-local): records the returned value" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def go(v)
            p = proc { return v.to_s }
            p.call
            "unreached"
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.go(9)\n))
      expect(r[:status]).to be_success, r[:err]
      expect(r[:methods]).to include(a_hash_including("class" => "W", "method" => "go", "returns" => include("String")))
    end
  end

  it "lambda{ return } (LOCAL): wrapped (not punted), records call+params+method return" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def run(v)
            f = lambda { return v }
            f.call.to_s
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.run(5)\n))
      expect(r[:status]).to be_success, r[:err]
      # lambda-local return -> still SOURCE-WRAPPED (it does not escape
      # the wrapper) and NOT rewritten to a throw.
      expect(r[:instr_lib]).to include('record_source_method_call("W", "run"')
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "run",
        "params_by_name" => a_hash_including("v" => include("Integer")),
        "returns" => include("String")
      ))
    end
  end

  it "loader gap: a file reached via plain `require` ($LOAD_PATH) is still wrapped" do
    in_tmp do |dir|
      libd = File.join(dir, "libd")
      FileUtils.mkdir_p(libd)
      File.write(File.join(libd, "widget.rb"), <<~RUBY)
        require "sorbet-runtime"
        class Widget
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def calc(v) = v.to_s
        end
      RUBY
      # Driver uses a PLAIN require (bare name via $LOAD_PATH), the gap.
      r = mini_collect(dir, File.join("libd", "widget.rb"),
                        %($LOAD_PATH.unshift #{libd.inspect}\nrequire "widget"\nWidget.new.calc(7)\n))
      expect(r[:status]).to be_success, r[:err]
      expect(r[:methods]).to include(a_hash_including(
        "class" => "Widget", "method" => "calc",
        "params_by_name" => a_hash_including("v" => include("Integer")),
        "returns" => include("String")
      ))
    end
  end

  it "class method def self.f" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def self.calc(v) = v.to_s
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.calc(3)\n))
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "calc", "kind" => "class",
        "params_by_name" => a_hash_including("v" => include("Integer"))
      ))
    end
  end

  it "private method" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          def go(v) = helper(v)
          private
          sig { params(v: T.untyped).returns(T.untyped) }
          def helper(v) = v.to_s
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.go(8)\n))
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "helper", "returns" => include("String")
      ))
    end
  end

  it "method that raises: records call params" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def boom(v)
            raise ArgumentError, "x" if v
            v
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nbegin; W.new.boom(1); rescue ArgumentError; end\n))
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "boom",
        "params_by_name" => a_hash_including("v" => include("Integer"))
      ))
    end
  end

  it "**kwargs/*splat/&block params: method still records (params arg_untraced by design)" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(a: T.untyped, rest: T.untyped, kw: T.untyped, blk: T.untyped).returns(T.untyped) }
          def mix(a, *rest, **kw, &blk)
            a.to_s
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.mix(1, 2, x: 3) { }\n))
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "mix",
        "params_by_name" => a_hash_including("a" => include("Integer")),
        "returns" => include("String")
      ))
    end
  end

  it "multi-line signature def" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(a: T.untyped, b: T.untyped).returns(T.untyped) }
          def add(
            a,
            b
          )
            (a + b).to_s
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.add(2, 3)\n))
      expect(r[:methods]).to include(a_hash_including("class" => "W", "method" => "add", "returns" => include("String")))
    end
  end

  it "recursive method" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(n: T.untyped).returns(T.untyped) }
          def fib(n) = n < 2 ? n : fib(n - 1) + fib(n - 2)
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.fib(6)\n))
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "fib", "params_by_name" => a_hash_including("n" => include("Integer"))
      ))
    end
  end

  it "recursive method invoked from inside a host .each do..end block (collect_bg_blocks shape)" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(node: T.untyped, acc: T.untyped).returns(T.untyped) }
          def walk(node, acc)
            case node
            when Array then node.each { |n| walk(n, acc) }
            when Hash  then node.each_pair { |_, v| walk(v, acc) }
            else acc << node
            end
          end
          sig { params(tree: T.untyped).returns(T.untyped) }
          def run(tree)
            out = []
            [tree].each { |t| walk(t, out) }   # caller invokes walk from inside .each
            out
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.run([{a: [1]}, 2])\n))
      expect(r[:status]).to be_success, r[:err]
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "walk",
        "params_by_name" => a_hash_including("node" => include("Array"))
      ))
    end
  end

  it "method called ONLY from a forked child (multi-process)" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def calc(v) = v.to_s
        end
      RUBY
      r = mini_collect(dir, "lib.rb", <<~RUBY)
        require_relative "lib"
        pid = fork { W.new.calc(123) }
        Process.wait(pid)
      RUBY
      expect(r[:status]).to be_success, r[:err]
      expect(r[:methods]).to include(a_hash_including(
        "class" => "W", "method" => "calc", "params_by_name" => a_hash_including("v" => include("Integer"))
      ))
    end
  end

  # ---- __FILE__-RELATIVE RESOURCE READ (the transpiler ENOENT class) --

  it "instrumented file's __FILE__/__dir__-relative resource read still works" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class Reader
          extend T::Sig
          ASSET = File.join(File.dirname(__FILE__), "asset.txt")
          sig { returns(T.untyped) }
          def load = File.read(ASSET)
        end
      RUBY
      File.write(File.join(dir, "asset.txt"), "PAYLOAD-OK")
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nReader.new.load\n))
      expect(r[:status]).to be_success, "ENOENT from instrumented __FILE__: #{r[:err]}"
      expect(r[:methods]).to include(a_hash_including(
        "class" => "Reader", "method" => "load", "returns" => include("String")
      ))
    end
  end

  # ---- STRUCT / IVAR / COLLECTION / T.let ----------------------------

  it "Struct field with NO strong static type: runtime-records field classes" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        Pair = Struct.new(:a, :b)
        class W
          extend T::Sig
          sig { params(x: T.untyped, y: T.untyped).returns(T.untyped) }
          def make(x, y) = Pair.new(x, y)
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.make("abc", 7)\n))
      expect(r[:status]).to be_success, r[:err]
      expect(r[:structs]).to include(a_hash_including("class" => "Pair", "field" => "a", "classes" => include("String")))
      expect(r[:structs]).to include(a_hash_including("class" => "Pair", "field" => "b", "classes" => include("Integer")))
    end
  end

  it "ivar collection element: records" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(xs: T.untyped).returns(T.untyped) }
          def go(xs)
            @bag = []
            @bag << :sym
            xs << "str"
            @bag
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.go([])\n))
      expect(r[:collections]).to include(a_hash_including("owner_kind" => "ivar", "name" => "@bag", "elem_classes" => include("Symbol")))
    end
  end

  it "derives reached loop sites from line coverage without per-iteration hooks" do
    in_tmp do |dir|
      path = lib(dir, <<~RUBY)
        class W
          def go
            i = 0
            while i < 10_000
              i += 1
            end
          end
        end
      RUBY
      loop_line = File.readlines(path).index { |line| line.include?("while") } + 1

      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.go\n))

      expect(r[:status]).to be_success, r[:err]
      expect(r[:instr_lib]).not_to include("record_loop_iteration")
      expect(r[:loops]).to include(a_hash_including(
        "path" => path, "line" => loop_line, "count" => 1
      ))
    end
  end

  it "T.let with untyped type: records the runtime class (line-shift safe)" do
    in_tmp do |dir|
      lib(dir, <<~RUBY)
        require "sorbet-runtime"
        class W
          extend T::Sig
          sig { params(v: T.untyped).returns(T.untyped) }
          def go(v)
            x = T.let(v, T.untyped)
            x
          end
        end
      RUBY
      r = mini_collect(dir, "lib.rb", %(require_relative "lib"\nW.new.go("hi")\n))
      expect(r[:status]).to be_success, r[:err]
      expect(r[:tlets]).to include(a_hash_including("classes" => include("String")))
    end
  end
end
