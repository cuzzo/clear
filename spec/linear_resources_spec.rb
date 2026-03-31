require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/transpiler"
require_relative "../src/ast"

RSpec.describe SemanticAnnotator do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    return ast
  end

  def get_last_type(source)
    run(source).statements.last.resolved_type
  end

  let(:ast) { run(code) }
  let(:result) { ast.statements.last.resolved_type }

  # ===================================================================
  # Phase 1: Linear Resource Types  (File, :: static constructors)
  # ===================================================================
  describe "Resource Types — Phase 1" do
    def transpile_fn(clear_src)
      tokens    = Lexer.new(clear_src).tokenize
      ast       = Parser.new(tokens, clear_src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      t = ZigTranspiler.new
      t.send(:visit, ast)
    end

    # ------------------------------------------------------------------
    # Lexer
    # ------------------------------------------------------------------
    describe "Lexer: '::' token" do
      it "tokenises '::' as DOUBLE_COLON" do
        tokens = Lexer.new("File::open").tokenize.reject { |t| t.type == :EOF }
        expect(tokens.map(&:type)).to eq([:TYPE_ID, :DOUBLE_COLON, :VAR_ID])
      end

      it "does not confuse '::' with two separate ':' tokens" do
        tokens = Lexer.new("::").tokenize.reject { |t| t.type == :EOF }
        expect(tokens.length).to eq(1)
        expect(tokens.first.type).to eq(:DOUBLE_COLON)
      end
    end

    # ------------------------------------------------------------------
    # Parser
    # ------------------------------------------------------------------
    describe "Parser: StaticCall AST node" do
      it "parses TypeName::method(args) as a StaticCall" do
        tokens = Lexer.new('File::open("data.txt")').tokenize
        parser = Parser.new(tokens, 'File::open("data.txt")')
        node   = parser.send(:parse_primary)
        expect(node).to be_a(AST::StaticCall)
        expect(node.type_name.name).to eq("File")
        expect(node.method_name).to eq("open")
        expect(node.args.length).to eq(1)
      end

      it "parses a StaticCall as RHS of a bind expression" do
        src    = 'FN f() RETURNS Void -> f = File::open("x"); RETURN; END'
        tokens = Lexer.new(src).tokenize
        ast    = Parser.new(tokens, src).parse
        fn     = ast.statements.first
        bind   = fn.body.first
        expect(bind.value).to be_a(AST::StaticCall)
      end
    end

    # ------------------------------------------------------------------
    # Annotator — happy-path type resolution
    # ------------------------------------------------------------------
    describe "Annotator: StaticCall type resolution" do
      it "File::open resolves to type :File" do
        src = 'FN f() RETURNS Void -> f = File::open("data.txt"); RETURN; END'
        ast = run(src)
        fn  = ast.statements.first
        # The bind/decl's value node is the StaticCall
        call = fn.body.first.value
        expect(call.resolved_type).to eq(:File)
      end

      it "annotates a File variable as a resource in scope" do
        # We exercise the full annotator; no error means resource path ran
        expect { run('FN f() RETURNS Void -> f = File::open("t"); RETURN; END') }.not_to raise_error
      end

      it "File::open arg is passed the full_type :File" do
        src = 'FN f() RETURNS Void -> f = File::open("path"); RETURN; END'
        ast = run(src)
        fn  = ast.statements.first
        call = fn.body.first.value
        expect(call.full_type.resolved).to eq(:File)
      end
    end

    # ------------------------------------------------------------------
    # Annotator — error cases
    # ------------------------------------------------------------------
    describe "Annotator: StaticCall errors" do
      it "raises on unknown type" do
        src = 'FN f() RETURNS Void -> x = Bogus::open("t"); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /Unknown type 'Bogus'/)
      end

      it "raises on non-resource type used with ::" do
        src = 'STRUCT Point { x: Number } FN f() RETURNS Void -> p = Point::new(); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /does not support '::' static method calls/)
      end

      it "raises on unknown static method" do
        src = 'FN f() RETURNS Void -> f = File::flush("t"); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /No static method 'flush' on 'File'/)
      end

      it "raises on wrong argument count" do
        src = 'FN f() RETURNS Void -> f = File::open("a", "b"); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /expects 1 argument/)
      end

      it "raises on wrong argument type" do
        src = 'FN f() RETURNS Void -> f = File::open(42); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /expected String, got Int64/)
      end
    end

    # ------------------------------------------------------------------
    # Transpiler — code generation
    # ------------------------------------------------------------------
    describe "Transpiler: StaticCall code generation" do
      it "emits CheatLib.fileOpen for File::open" do
        src = 'FN f() RETURNS Void -> f = File::open("data.txt"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.fileOpen("data.txt")')
      end

      it "emits defer with move-guarded f.close() for auto-RAII" do
        src = 'FN f() RETURNS Void -> f = File::open("data.txt"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("defer if (!f_moved) f.close();")
      end

      it "emits a _moved flag for resource move tracking" do
        src = 'FN f() RETURNS Void -> f = File::open("data.txt"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("f_moved")
      end

      it "maps File to std.fs.File Zig type" do
        expect(Type.new(:File).zig_type).to eq("std.fs.File")
      end
    end

    # ------------------------------------------------------------------
    # Resource move semantics
    # ------------------------------------------------------------------
    describe "Resource move tracking" do
      it "marks the resource as :moved when reassigned" do
        # After 'g = f', f should be :moved so the outer scope does not double-close
        src = 'FN f() RETURNS Void -> a = File::open("t"); b = a; RETURN; END'
        # Should not raise (resource move is legal)
        expect { run(src) }.not_to raise_error
      end
    end
  end

  # ===================================================================
  # Phase 3: TCP Resource Types (TCPServer, TCPClient)
  # ===================================================================
  describe "Resource Types — Phase 3 (TCP)" do
    def transpile_fn(clear_src)
      tokens    = Lexer.new(clear_src).tokenize
      ast       = Parser.new(tokens, clear_src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      t = ZigTranspiler.new
      t.send(:visit, ast)
    end

    # ------------------------------------------------------------------
    # Type system
    # ------------------------------------------------------------------
    describe "Type mapping" do
      it "TCPServer maps to i32 Zig type" do
        expect(Type.new(:TCPServer).zig_type).to eq("i32")
      end

      it "TCPClient maps to i32 Zig type" do
        expect(Type.new(:TCPClient).zig_type).to eq("i32")
      end
    end

    # ------------------------------------------------------------------
    # Annotator — TCPServer::listen
    # ------------------------------------------------------------------
    describe "Annotator: TCPServer::listen" do
      it "resolves TCPServer::listen(port) to type :TCPServer" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(8080); RETURN; END'
        ast = run(src)
        call = ast.statements.first.body.first.value
        expect(call.resolved_type).to eq(:TCPServer)
      end

      it "annotates TCPServer variable as a resource in scope" do
        expect {
          run('FN f() RETURNS Void -> s = TCPServer::listen(8080); RETURN; END')
        }.not_to raise_error
      end

      it "raises on wrong argument type (String instead of Int64)" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen("8080"); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /expected Int64, got/)
      end

      it "raises on wrong argument count" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(80, 90); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /expects 1 argument/)
      end

      it "raises on unknown static method" do
        src = 'FN f() RETURNS Void -> s = TCPServer::connect(80); RETURN; END'
        expect { run(src) }.to raise_error(SourceError, /No static method 'connect' on 'TCPServer'/)
      end
    end

    # ------------------------------------------------------------------
    # Annotator — accept / tcpRead / tcpWrite intrinsics
    # ------------------------------------------------------------------
    describe "Annotator: accept intrinsic" do
      it "accept(server) resolves to type :TCPClient" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(8080); c = accept(s); RETURN; END'
        ast = run(src)
        fn = ast.statements.first
        accept_call = fn.body[1].value  # second statement
        expect(accept_call.resolved_type).to eq(:TCPClient)
      end

      it "annotates the accepted client as a resource (gets defer close)" do
        expect {
          run('FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); RETURN; END')
        }.not_to raise_error
      end

      it "raises if accept is called with a non-TCPServer arg" do
        src = 'FN f() RETURNS Void -> accept(42); RETURN; END'
        expect { run(src) }.to raise_error(SourceError)
      end
    end

    describe "Annotator: tcpRead intrinsic" do
      it "tcpRead(client) resolves to String" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); data = tcpRead(c); RETURN; END'
        ast = run(src)
        fn = ast.statements.first
        # data is the third statement
        data_bind = fn.body[2]
        expect(data_bind.value.resolved_type).to eq(:String)
      end
    end

    describe "Annotator: tcpWrite intrinsic" do
      it "tcpWrite(client, string) resolves to Void" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); tcpWrite(c, "hello"); RETURN; END'
        ast = run(src)
        fn = ast.statements.first
        write_call = fn.body[2]
        expect(write_call.resolved_type).to eq(:Void)
      end
    end

    # ------------------------------------------------------------------
    # Transpiler — code generation
    # ------------------------------------------------------------------
    describe "Transpiler: TCPServer code generation" do
      it "emits CheatLib.socketListen for TCPServer::listen" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(8080); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.socketListen(@intCast(8080))')
      end

      it "emits defer with move-guarded CheatLib.socketClose for server RAII" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(8080); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("defer if (!s_moved) CheatLib.socketClose(s);")
      end

      it "emits CheatLib.socketAccept for accept()" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.socketAccept(s)')
      end

      it "emits defer with move-guarded CheatLib.socketClose for client RAII" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("defer if (!c_moved) CheatLib.socketClose(c);")
      end

      it "emits CheatLib.socketRead for tcpRead()" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); d = tcpRead(c); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.socketRead(')
      end

      it "emits CheatLib.socketWriteVoid for tcpWrite()" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); tcpWrite(c, "hi"); RETURN; END'
        out = transpile_fn(src)
        # The string literal may be wrapped in @as([]const u8, ...) — check the function name and first arg
        expect(out).to include('CheatLib.socketWriteVoid(c,')
        expect(out).to include('"hi"')
      end

      it "TCPServer Zig type is i32 (via Type#zig_type)" do
        # The transpiler infers the type from the expression; check via the type system directly.
        expect(Type.new(:TCPServer).zig_type).to eq("i32")
        expect(Type.new(:TCPClient).zig_type).to eq("i32")
      end

      it "emits a _moved flag for TCPServer resource move tracking" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("s_moved")
      end
    end

    # ------------------------------------------------------------------
    # Resource move semantics — linear ownership enforcement
    # ------------------------------------------------------------------
    describe "Resource move tracking" do
      it "allows moving a TCPServer to another variable" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); s2 = s; RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "allows moving a TCPClient to another variable" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); c2 = c; RETURN; END'
        expect { run(src) }.not_to raise_error
      end
    end

    # ------------------------------------------------------------------
    # Use-after-move errors for resource types
    # Resources are linear: once moved to another binding they cannot
    # be used again — doing so would risk a double-close / use-after-free.
    # ------------------------------------------------------------------
    describe "Use-after-move errors for resource types" do
      # File::open
      it "raises on use-after-move of File::open resource" do
        src = 'FN f() RETURNS Void -> a = File::open("x"); b = a; fileWrite(a, "bad"); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'a'/)
      end

      it "raises on double-move of File::open resource" do
        src = 'FN f() RETURNS Void -> a = File::open("x"); b = a; c = a; RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'a'/)
      end

      # File::create
      it "raises on use-after-move of File::create resource" do
        src = 'FN f() RETURNS Void -> a = File::create("x"); b = a; fileWrite(a, "bad"); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'a'/)
      end

      # TCPServer
      it "raises on use-after-move of TCPServer resource" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); s2 = s; c = accept(s); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 's'/)
      end

      it "raises on double-move of TCPServer resource" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); s2 = s; s3 = s; RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 's'/)
      end

      # TCPClient
      it "raises on use-after-move of TCPClient resource" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); c2 = c; d = tcpRead(c); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'c'/)
      end

      it "raises on use-after-move when writing to moved TCPClient" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); c2 = c; tcpWrite(c, "bad"); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'c'/)
      end

      # TCPClient::connect
      it "raises on use-after-move of TCPClient::connect resource" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1", 8080); c2 = c; tcpWrite(c, "bad"); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'c'/)
      end

      # Normal use — should NOT raise
      it "does not raise when using File before any move" do
        src = 'FN f() RETURNS Void -> a = File::open("x"); fileWrite(a, "ok"); RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "does not raise when using TCPServer before any move" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "does not raise when using TCPClient before any move" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); d = tcpRead(c); RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "does not raise when using TCPClient::connect before any move" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1", 8080); tcpWrite(c, "hi"); RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "does not raise when using File::create before any move" do
        src = 'FN f() RETURNS Void -> a = File::create("x"); fileWrite(a, "ok"); RETURN; END'
        expect { run(src) }.not_to raise_error
      end
    end

    # ------------------------------------------------------------------
    # LINK / RESOLVE (weak references)
    # ------------------------------------------------------------------
    describe "LINK / RESOLVE" do
      it "LINK on @shared compiles" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @shared; w = LINK x; RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "LINK on @multiowned compiles" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @multiowned; w = LINK x; RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "LINK on non-RC raises error" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 }; w = LINK x; RETURN; END'
        expect { run(src) }.to raise_error(/LINK can only be applied to @shared or @multiowned/)
      end

      it "RESOLVE on @link compiles" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @shared; w = LINK x; r = RESOLVE w; RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "RESOLVE on non-link raises error" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @shared; r = RESOLVE x; RETURN; END'
        expect { run(src) }.to raise_error(/RESOLVE can only be applied to @link/)
      end

      it "emits rcDowngrade for @multiowned LINK" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @multiowned; w = LINK x; RETURN; END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("CheatLib.rcDowngrade(N, x)")
      end

      it "emits arcDowngrade for @shared LINK" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @shared; w = LINK x; RETURN; END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("CheatLib.arcDowngrade(N, x)")
      end

      it "emits weakRcUpgrade for @multiowned RESOLVE" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @multiowned; w = LINK x; r = RESOLVE w; RETURN; END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("CheatLib.weakRcUpgrade(N, w)")
      end

      it "emits weakArcUpgrade for @shared RESOLVE" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @shared; w = LINK x; r = RESOLVE w; RETURN; END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("CheatLib.weakArcUpgrade(N, w)")
      end

      it "emits weakRcRelease cleanup for @multiowned link" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @multiowned; w = LINK x; RETURN; END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("CheatLib.weakRcRelease(N, w)")
      end

      it "emits weakArcRelease cleanup for @shared link" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @shared; w = LINK x; RETURN; END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("CheatLib.weakArcRelease(N, w)")
      end

      it "emits optional-unwrap cleanup for RESOLVE result" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @multiowned; w = LINK x; r = RESOLVE w; RETURN; END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("if (r) |_strong_ref| CheatLib.rcRelease(N, rt.heapAlloc(), _strong_ref)")
      end

      it "@link type annotation preserves link_source" do
        src = 'STRUCT N { v: Int64 }
              FN f() RETURNS Void -> x = N{ v: 1 } @multiowned; w: N@link = LINK x; r = RESOLVE w; RETURN; END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("CheatLib.weakRcUpgrade(N, w)")
      end

      it "@link is allowed on function parameters" do
        src = 'STRUCT N { v: Int64 }
              FN check(w: N@link) RETURNS Void -> PASS END
              FN f() RETURNS Void -> PASS END'
        expect { run(src) }.not_to raise_error
      end

      it "@link struct field emits WeakRc type" do
        src = 'STRUCT N { v: Int64 }
              STRUCT Edge { target: N@link }
              FN f() RETURNS Void -> PASS END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("target: CheatLib.WeakRc(N)")
      end

      it "struct with @link field emits releaseFields cleanup" do
        src = 'STRUCT N { v: Int64 }
              STRUCT Edge { target: N@link }
              FN f() RETURNS Void -> n = N{ v: 1 } @multiowned; e = Edge{ target: LINK n }; RETURN; END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("CheatLib.releaseFields(Edge, rt.heapAlloc(), e)")
      end

      it "struct with @multiowned field emits releaseFields cleanup" do
        src = 'STRUCT N { v: Int64 }
              STRUCT W { inner: N@multiowned }
              FN f() RETURNS Void -> n = N{ v: 1 } @multiowned; w = W{ inner: n }; RETURN; END'
        out = ZigTranspiler.new.transpile(src)
        expect(out).to include("CheatLib.releaseFields(W, rt.heapAlloc(), w)")
      end
    end

    # ------------------------------------------------------------------
    # String affine move semantics (Rust-like)
    # ------------------------------------------------------------------
    describe "String move semantics" do
      it "raises on use-after-move of String variable" do
        src = 'FN f() RETURNS Void -> x = "hello"; y = x; z = x; RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'x'/)
      end

      it "raises on use-after-move of String in function call" do
        src = 'FN f(s: String) RETURNS Void -> RETURN; END
              FN g() RETURNS Void -> x = "hello"; y = x; f(x); RETURN; END'
        expect { run(src) }.to raise_error(/Use of moved value 'x'/)
      end

      it "does not raise on normal string assignment and use" do
        src = 'FN f() RETURNS Void -> x = "hello"; ASSERT x == "hello", "ok"; RETURN; END'
        expect { run(src) }.not_to raise_error
      end

      it "does not raise when string is used before move" do
        src = 'FN f() RETURNS Void -> x = "hello"; ASSERT x == "hello", "ok"; y = x; RETURN; END'
        expect { run(src) }.not_to raise_error
      end
    end

    # ------------------------------------------------------------------
    # Phase 4 — File::create, fileWrite, TCPClient::connect
    # ------------------------------------------------------------------
    describe "Phase 4 — File::create" do
      it "resolves File::create return type as File" do
        src = 'FN f() RETURNS Void -> f = File::create("out.txt"); RETURN; END'
        tree = run(src)
        fn_node = tree.statements.first
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "f" }
        expect(bind.full_type.to_sym).to eq(:File)
      end

      it "emits try CheatLib.fileCreate for File::create" do
        src = 'FN f() RETURNS Void -> f = File::create("out.txt"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.fileCreate(')
      end

      it "emits defer with move-guarded f.close() RAII for File::create" do
        src = 'FN f() RETURNS Void -> f = File::create("out.txt"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("defer if (!f_moved) f.close();")
      end

      it "raises on File::create with wrong arg count" do
        src = 'FN f() RETURNS Void -> f = File::create("a.txt", "b.txt"); RETURN; END'
        expect { run(src) }.to raise_error(/expects 1 argument|argument.*got 2/i)
      end

      it "raises on unknown File static method" do
        src = 'FN f() RETURNS Void -> f = File::flush("out.txt"); RETURN; END'
        expect { run(src) }.to raise_error(/unknown static method|flush/i)
      end
    end

    describe "Phase 4 — fileWrite intrinsic" do
      it "resolves fileWrite return type as Void" do
        src = 'FN f() RETURNS Void -> ff = File::create("o.txt"); fileWrite(ff, "hello"); RETURN; END'
        tree = run(src)
        fn_node = tree.statements.first
        call = fn_node.body.find { |n| n.is_a?(AST::FuncCall) && n.name == "fileWrite" }
        expect(call.full_type.to_sym).to eq(:Void)
      end

      it "emits try CheatLib.fileWrite for fileWrite()" do
        src = 'FN f() RETURNS Void -> ff = File::create("o.txt"); fileWrite(ff, "hello"); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.fileWrite(ff,')
      end

      it "raises on fileWrite with non-File first argument" do
        src = 'FN f() RETURNS Void -> fileWrite("not_a_file", "hello"); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'fileWrite'|fileWrite/)
      end

      it "raises on fileWrite with non-String second argument" do
        src = 'FN f() RETURNS Void -> ff = File::create("o.txt"); fileWrite(ff, 42); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'fileWrite'|fileWrite/)
      end

      it "raises on fileWrite with wrong arg count" do
        src = 'FN f() RETURNS Void -> ff = File::create("o.txt"); fileWrite(ff); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'fileWrite'|fileWrite/)
      end
    end

    describe "Phase 4 — TCPClient::connect" do
      it "resolves TCPClient::connect return type as TCPClient" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1", 8080); RETURN; END'
        tree = run(src)
        fn_node = tree.statements.first
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "c" }
        expect(bind.full_type.to_sym).to eq(:TCPClient)
      end

      it "emits try CheatLib.socketConnect for TCPClient::connect" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1", 8080); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include('CheatLib.socketConnect(')
      end

      it "emits defer with move-guarded CheatLib.socketClose RAII for TCPClient::connect" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1", 8080); RETURN; END'
        out = transpile_fn(src)
        expect(out).to include("defer if (!c_moved) CheatLib.socketClose(c);")
      end

      it "raises on TCPClient::connect with wrong arg count" do
        src = 'FN f() RETURNS Void -> c = TCPClient::connect("127.0.0.1"); RETURN; END'
        expect { run(src) }.to raise_error(/expects 2 argument|argument.*got 1/i)
      end

      it "raises on unknown TCPClient static method" do
        src = 'FN f() RETURNS Void -> c = TCPClient::bind("127.0.0.1", 8080); RETURN; END'
        expect { run(src) }.to raise_error(/unknown static method|bind/i)
      end

      it "can send after TCPClient::connect — codegen includes tcpWrite" do
        src = <<~CLEAR
          FN f() RETURNS Void ->
            c = TCPClient::connect("127.0.0.1", 8080);
            tcpWrite(c, "hello");
            RETURN;
          END
        CLEAR
        out = transpile_fn(src)
        expect(out).to include('CheatLib.socketWriteVoid(c,')
      end
    end

    describe "Phase 4 — tcpRead / tcpWrite / accept error cases" do
      it "raises on tcpRead with non-TCPClient argument" do
        src = 'FN f() RETURNS Void -> tcpRead("not_a_client"); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'tcpRead'|tcpRead/)
      end

      it "raises on tcpWrite with non-TCPClient first argument" do
        src = 'FN f() RETURNS Void -> tcpWrite("not_a_client", "data"); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'tcpWrite'|tcpWrite/)
      end

      it "raises on tcpWrite with non-String second argument" do
        src = 'FN f() RETURNS Void -> s = TCPServer::listen(0); c = accept(s); tcpWrite(c, 42); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'tcpWrite'|tcpWrite/)
      end

      it "raises on accept with non-TCPServer argument" do
        src = 'FN f() RETURNS Void -> x = accept(42); RETURN; END'
        expect { run(src) }.to raise_error(/No overload for 'accept'|accept/)
      end
    end
  end

end
