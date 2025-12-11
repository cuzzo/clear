#! /usr/bin/env ruby

require_relative "./lexer"
require_relative "./parser"
require_relative "./ast"
require_relative "./annotator"

class ZigTranspiler
  def compile(cheat_code)
    # 1. Parse
    tokens = Lexer.new(cheat_code).tokenize
    ast = Parser.new(tokens, cheat_code).parse
    annotator = SemanticAnnotator.new()
    annotator.annotate!(ast)

    # 2. Generate Zig
    # We output the Runtime preamble + Transpiled Code + Main
    <<~ZIG
      // [RUNTIME BEGIN] ---------------------------------------------------------
      #{File.read("./zig/runtime.zig").split("// 2. User Types").first}
      // [RUNTIME END] -----------------------------------------------------------

      // -------------------------------------------------------------------------
      // 2. User Types & Functions (Transpiled)
      // -------------------------------------------------------------------------
      #{visit(ast)}

      // -------------------------------------------------------------------------
      // 3. Main Entry (Test Harness)
      // -------------------------------------------------------------------------
      pub fn main() !void {
          var gpa = std.heap.GeneralPurposeAllocator(.{}){};
          const allocator = gpa.allocator();
          var rt = try Runtime.init(allocator, 1024 * 1024);
          defer rt.deinit(allocator);

          // Call the function defined in CHEAT
          const result = try cheatMain(&rt);
          std.debug.print("Result ID: {d}\\n", .{result.id});
      }
    ZIG
  end

  private

  def visit(node)
    case node
    when AST::Program
      node.statements.map { |stmt| visit(stmt) }.join("\n\n")

    when AST::StructDef
      # CHEAT: STRUCT User { id: Number }
      # ZIG:   const User = struct { id: i64, };
      fields = node.fields.map do |name, field_def|
        type_sym = field_def[:type]

        zig_type = transpile_type(type_sym)
        "    #{name}: #{zig_type},"
      end.join("\n")

      <<~ZIG
        const #{node.name} = struct {
        #{fields}
        };
      ZIG

    when AST::FunctionDef
      # CHEAT: FN test() RETURNS User ->
      # ZIG:   pub fn test(rt: *Runtime) !User {
      return_type = transpile_type(node.return_type || :Void)

      # We inject 'rt' into every function signature
      signature = "pub fn #{node.name}(rt: *Runtime) !#{return_type}"

      body = node.body.map { |stmt| visit(stmt) }.join("\n    ")

      <<~ZIG
        #{signature} {
            const frame_mark = rt.saveStackMark();
            defer rt.restoreStackMark(frame_mark);

            #{body}
        }
      ZIG

    when AST::VarDecl
      # CHEAT: VAR u = ...
      # ZIG:   var u = ...
      # Note: We rely on Zig's type inference here for simplicity
      is_mutable = node.respond_to?(:mutable) && node.mutable
      keyword = is_mutable ? "var" : "const"

      # 2. Generate Declaration
      #    var u = ...;
      decl = "#{keyword} #{node.name} = #{visit(node.value)};"

      # 3. Generate Suppression
      #    _ = &u;  <-- If mutable, we take address to silence "never mutated" check
      #
      # TODO: Have the annotator suppress unused variables.
      suppression = is_mutable ? "_ = &#{node.name};" : "_ = &#{node.name};"

      "#{decl} #{suppression}"

    when AST::StructLit
      # CHEAT: User{ id: 1 }
      # ZIG:   User{ .id = 1 }
      field_inits = node.fields.map do |name, val|
        ".#{name} = #{visit(val)}"
      end.join(", ")

      "#{node.name}{ #{field_inits} }"

    when AST::FuncCall
      # Special case for 'print'
      if node.name == "print"
        # Naive: assume we are printing an integer for this demo
        arg = visit(node.args.first)
        return "std.debug.print(\"{d}\\n\", .{#{arg}});"
      end
      # Standard call (pass rt)
      args = ["&rt"] + node.args.map { |a| visit(a) }
      "try #{node.name}(#{args.join(', ')});"

    when AST::ReturnNode
      "return #{visit(node.value)};"

    when AST::GetField
      "#{visit(node.target)}.#{node.field}"

    when AST::Identifier
      node.name

    when AST::Literal
      node.value.to_s

    else
      raise "Unknown Node: #{node.class}"
    end
  end

  def transpile_type(type)
    case type.to_s
    when "Number" then "f64" # Mapping Number -> f64 for simplicity
    when "Void"   then "void"
    else type.to_s
    end
  end
end

# --- RUN IT ---

code = <<~CHEAT
  STRUCT User { id: Number }

  FN cheatMain() RETURNS User ->
    VAR u = User{ id: 1 };
    print(u.id);
    RETURN u;
  END
CHEAT

# Assuming you have runtime.zig in zig/runtime.zig
if !File.exist?("zig/runtime.zig")
  puts "Please ensure zig/runtime.zig exists (from your prompt)!"
  exit
end

puts ZigTranspiler.new.compile(code)
