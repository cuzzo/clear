#! /usr/bin/env ruby

require 'bundler/setup' # so `bundle exec` not needed
require "optparse"
require "logger"
require "byebug"

require_relative "./lexer"
require_relative "./parser"
require_relative "./ast"
require_relative "./annotator"

class ZigTranspiler
  ZIG_OPS = {
    :ADD => "+",
    :SUB => "-",
    :MUL => "*",
    :DIV => "/",     # Note: Integer division in Zig
    :MOD => "%",     # Zig uses % for Modulo

    :EQ  => "==",
    :NEQ => "!=",
    :LT  => "<",
    :LTE => "<=",
    :GT  => ">",
    :GTE => ">=",

    # Zig-specific logic keywords
    :AND => "and",
    :OR  => "or",
    :NOT => "!",

    # Bitwise
    :BITWISE_NOT => "~",

    # Special AST nodes you might map to operators
    #:OR_RESCUE   => "orelse"
  }

  ZIG_PRIMITIVES = ["i64", "f64", "bool", "void", "[]const u8"]

  def transpile(cheat_code)
    # 1. Parse
    tokens = Lexer.new(cheat_code).tokenize
    ast = Parser.new(tokens, cheat_code).parse
    annotator = SemanticAnnotator.new()
    annotator.annotate!(ast)

    # 2. Generate Zig
    # We output the Runtime preamble + Transpiled Code + Main
    <<~ZIG
      // [RUNTIME BEGIN] ---------------------------------------------------------
      #{File.read("./zig/runtime-header.zig")}
      // [RUNTIME END] -----------------------------------------------------------

      // -------------------------------------------------------------------------
      // 2. User Types & Functions (Transpiled)
      // -------------------------------------------------------------------------
      #{visit(ast)}

      // -------------------------------------------------------------------------
      // 3. Main Entry (Test Harness)
      // -------------------------------------------------------------------------
      #{File.read("./zig/runtime-footer.zig")}
    ZIG
  end

private

  def visit(node)
    code = visit_node(node)
    if node.respond_to?(:coerced_type) && node.coerced_type && node.coerced_type != node.full_type
      code = transpile_cast(code, node.full_type, node.coerced_type)
    end
    code
  end

  def visit_node(node)
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
      base_type = transpile_type(node.return_type || :Void)

      # 2. Check if it's a Struct (Simple heuristic: not a primitive)
      #    Primitives: i64, f64, bool, void, and slices ([]...)
      is_struct = !["i64", "f64", "bool", "void"].include?(base_type) && !base_type.start_with?("[]")

      # 3. If Struct, return Pointer (*User)
      final_type = is_struct ? "*#{base_type}" : base_type

      params_zig = node.params.map do |param|
        p_name = param[:name]
        p_type = transpile_type(param[:type])
        "#{p_name}: #{p_type}"
      end

      # We inject 'rt' into every function signature
      all_params = ["rt: *Runtime"] + params_zig
      signature = "pub fn #{node.name}(#{all_params.join(', ')}) !#{final_type}"

      body = transpile_block(node.body)

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

      zig_type = transpile_type(node.full_type)
      is_primitive = ZIG_PRIMITIVES.include?(zig_type)

      annotation = is_primitive ? ": #{zig_type}" : ""

      # 2. Generate Declaration
      #    var u = ...;
      decl = "#{keyword} #{node.name}#{annotation} = #{visit(node.value)};"

      # 3. Generate Suppression
      #    _ = &u;  <-- If mutable, we take address to silence "never mutated" check
      #
      # TODO: Have the annotator suppress unused variables.
      suppression = is_mutable ? "_ = &#{node.name};" : "_ = &#{node.name};"

      "#{decl} #{suppression}"

    when AST::Assignment
      # 1. Resolve the Target string
      #    The target might be a simple String ("i") or a complex Node (GetField/GetIndex)
      target_str =
        if node.name.is_a?(String)
          node.name
        elsif node.name.is_a?(AST::Identifier)
          node.name.name
        else
          # Recursive visit for things like 'user.id' or 'list[0]'
          visit(node.name)
        end

      # 2. Resolve the Value
      value_str = visit(node.value)

      # 3. Output Zig Code
      "#{target_str} = #{value_str}"

    when AST::StructLit
      # CHEAT: User{ id: 1 }
      # ZIG:   User{ .id = 1 }

      # ... field init logic ...
      field_inits = node.fields.map { |k,v| ".#{k} = #{visit(v)}" }.join(", ")
      struct_init = "#{node.name}{ #{field_inits} }"

      if node.storage == :heap # You set this in the Annotator!
        # The 2-step Zig dance
        # We use a block expression usually, or a helper function
        # For simplicity, we can use a helper: try rt.newHeap(User, User{...})
        "try rt.allocCopy(#{node.name}, #{struct_init})"
      else
        struct_init
      end

    when AST::ListLit
      # 1. Determine the Zig Type (T)
      #    The Annotator sets 'full_type' (e.g. :Number[] or :%User[])
      #    We strip the brackets and % to get the base type.
      effective_type = node.coerced_type || node.full_type
      type_str = effective_type.to_s

      base_type_sym = type_str.gsub(/[\[\]%]/, '')
      zig_type = transpile_type(base_type_sym)

      # 2. Determine Allocator
      #    The Annotator sets 'storage' (:heap or :stack)
      allocator = node.storage == :heap ? "rt.heapAlloc()" : "rt.stackAlloc()"

      # 3. Generate Items Slice
      #    Zig syntax for an array literal slice is: &.{ item1, item2 }
      if node.items.empty?
        items_slice = "&.{}"
      else
        items_list = node.items.map { |item| visit(item) }.join(", ")
        items_slice = "&.{ #{items_list} }"
      end

      # 4. Generate the Call
      #    Result: try rt.makeList(i64, rt.stackAlloc(), &.{ 1, 2, 3 })
      "try rt.makeList(#{zig_type}, #{allocator}, #{items_slice})"

    when AST::GetIndex
      # 1. Resolve Target and Index
      target = visit(node.target)
      index  = visit(node.index)

      # 2. Generate Universal Accessor
      #    Zig: rt.getAt(list, i)
      "rt.getAt(#{target}, #{index})"

    when AST::IfStatement
      # 1. Transpile Condition
      #    Zig idiomatic: if (cond) { ... }
      cond = visit(node.condition)

      # 2. Transpile THEN Block
      then_body = transpile_block(node.then_branch)

      # 3. Construct Base Statement
      zig_code = "if (#{cond}) {\n    #{then_body}\n    }"

      # 4. Transpile ELSE Block (Optional)
      if node.else_branch && !node.else_branch.empty?
        else_body = transpile_block(node.else_branch)
        zig_code += " else {\n    #{else_body}\n    }"
      end

      zig_code

    when AST::WhileLoop
      cond = visit(node.condition)
      body = transpile_block(node.do_branch)
      "while (#{cond}) {\n #{body} \n}"

    when AST::FuncCall, AST::MethodCall
      return transpile_Intrinsic(node) if !node.zig_pattern.nil?
      # Standard call (pass rt)
      args = ["rt"] + node.args.map { |a| visit(a) }
      "try #{node.name}(#{args.join(', ')})"

    when AST::ReturnNode
      "return #{visit(node.value)};"

    when AST::GetField
      "#{visit(node.target)}.#{node.field}"

    when AST::Identifier
      node.name

    when AST::Literal
      case node.type
      when :STRING
        "\"#{node.value}\""  # Add quotes!
      when :NUMBER, :INT64
        node.value.to_i.to_s # Force Integer for Zig i64 compatibility
      when :BOOLEAN
        node.value.to_s      # "true"/"false" is fine
      else
        node.value.to_s
      end

    when AST::UnaryOp
      right = visit(node.right)
      case node.op
      when :NOT, "!"
        "!#{right}"
      when :SUB, "-"
        "-#{right}"
      when :BITWISE_NOT, "~"
        "~#{right}"
      else
        raise "Transpiler Error: Unknown Unary Operator '#{node.op}'"
      end

    when AST::BinaryOp
      return transpile_Smooth(node) if node.op == :SMOOTH

      left = visit(node.left)
      right = visit(node.right)

      if node.op == :ADD || node.op == "+"
        # Check if we are operating on Strings
        # Annotator ensures full_type is set (e.g. "String[]" or "%String[]")
        t_left = node.left.full_type.to_s
        t_right = node.right.full_type.to_s

        if t_left.include?("String") || t_right.include?("String")
          # Generate call to runtime helper
          # We use heapAlloc to ensure the result survives (safe default)
          return "try rt.concat(rt.heapAlloc(), #{left}, #{right})"
        end
      end

      if node.op == :POW
        # Assuming i64 for now.
        # If types are float, you might need std.math.pow(f64, ...)
        return "std.math.pow(i64, #{left}, #{right})"
      end

      # Standard Operators
      op_str = ZIG_OPS[node.op]

      unless op_str
        raise "Transpiler Error: Unknown or Unsupported Binary Operator '#{node.op}'"
      end

      "(#{left} #{op_str} #{right})"

    else
      raise "Unknown Node: #{node.class}"
    end
  end

  def transpile_Smooth(node)
    lhs = node.left
    rhs = node.right

    # We construct a synthetic node that looks like the resulting function call.
    # This delegates all complexity (rt injection, print formatting, recursion)
    # to the existing visit_FuncCall handler.

    synthetic_call = if rhs.is_a?(AST::Identifier)
       # Pattern: x s> f  -->  f(x)
       AST::FuncCall.new(rhs.token, rhs.name, [lhs])

    elsif rhs.is_a?(AST::FuncCall)
       # Pattern: x s> f(y) --> f(x, y)
       # We inject the LHS as the *first* argument
       new_args = [lhs] + rhs.args
       AST::FuncCall.new(rhs.token, rhs.name, new_args)

    else
       raise "Transpiler Error: Invalid Pipe Destination #{rhs.class}"
    end

    # Visit the fake node as if it were in the original source
    visit(synthetic_call)
  end

  def transpile_Intrinsic(node)
    # Special Builtins that can't be handled 1-1 mapping
    return send(node.zig_pattern, node) if node.zig_pattern.is_a?(Symbol)

    # 1. Gather Arguments
    #    Arg 0 is receiver (for methods), Args 1..N are params
    #    We must transpile them first.

    # TODO: Annotator should do this
    args_zig =
      if node.is_a?(AST::MethodCall)
        [visit(node.object)] + node.args.map { |a| visit(a) }
      else
        node.args.map { |a| visit(a) }
      end

    # 2. Resolve Placeholders
    #    {0} -> args_zig[0], {1} -> args_zig[1]
    pattern = node.zig_pattern

    #    {alloc} -> determine allocator automatically
    if pattern.include?("{alloc}")
      alloc = node.storage == :heap ? "rt.heapAlloc()" : "rt.stackAlloc()"
      pattern = pattern.gsub("{alloc}", alloc)
    end

    args_zig.each_with_index do |val, i|
      pattern = pattern.gsub("{#{i}}", val)
    end

    pattern
  end

  # Semi-colon helper
  def transpile_block(statements)
    statements.map do |stmt|
      code = visit(stmt)
      # Add ; if it's not a block ending (}) and doesn't have one yet
      code += ";" unless code.end_with?(";") || code.end_with?("}")
      code
    end.join("\n    ")
  end

  def transpile_type(type)
    t = type.to_s.gsub("%", "") # Strip explicit heap marker if present

    case t
    when "Number"          then "f64"
    when "Int64"           then "i64"
    when "String"          then "[]const u8"  # TODO: String isn't used
    when "String[]"        then "[]const u8"
    when "Void"            then "void"
    else t # Fallback for Struct names (e.g. "User")
    end
  end

  # TODO: from_type/to_type may need to be simplified
  def transpile_cast(code, from_type, to_type)
    from = from_type
    to = to_type

    # A. Int -> Float (e.g. i64 -> f64)
    if [:Int64, :Byte].include?(from) && to == :Number
      return "@floatFromInt(#{code})"
    end

    # B. Float -> Int (e.g. f64 -> i64)
    if from == :Number && to == :Int64
      return "@intFromFloat(#{code})"
    end

    # C. Int Widening (e.g. u8 -> i64)
    if from == :Byte && to == :Int64
      return "@intCast(#{code})"
    end

    # Fallback: Zig's generic cast (often works for simple types)
    # e.g. @as(f64, 10.5)
    zig_to = transpile_type(to)
    return "@as(#{zig_to}, #{code})"
  end

  def get_zig_format(flux_type)
    # 1. Clean the type string (remove % heap marker)
    t = flux_type.to_s.gsub("%", "")

    # 2. Handle Strings explicitly
    #    Flux might call it "String" or "String[]" depending on where it came from
    return "{s}" if t.include?("String")

    # 3. Handle Primitives
    case t
    when "Number", "Int64", "Byte" then "{d}" # Decimal
    when "Bool"                    then "{}"  # Auto (true/false)
    when "Void"                    then "{}"  # Void
    else
      "{any}" # Fallback for Structs/Objects (Debug print)
    end
  end

  ### ---- STD LIB MACROS ---

  # [MACRO] Generates type-safe Zig print statements
  # Called automatically via :macro_print in STD_LIB
  def macro_print(node)
    # 1. Build Format String (e.g. "{d} {s}")
    formats = node.args.map do |arg|
      get_zig_format(arg.full_type)
    end.join(" ")

    # 2. Build Value List
    values = node.args.map { |a| visit(a) }.join(", ")

    # 3. Output
    "std.debug.print(\"#{formats}\\n\", .{#{values}});"
  end
end

# --- RUN IT ---


$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  "[#{severity}] #{msg}\n"
end

OptionParser.new do |opts|
  opts.on('--log-level LEVEL', 'Set log level (DEBUG, INFO, WARN, ERROR)') do |level|
    $logger.level = Logger.const_get(level.upcase)
  end
end.parse!


if __FILE__ == $0
  # Assuming you have runtime.zig in zig/runtime.zig
  if !File.exist?("zig/runtime.zig")
    puts "Please ensure zig/runtime.zig exists (from your prompt)!"
    exit
  end

  script_file = ARGV.first
  if script_file
    code = File.read(script_file)
    puts ZigTranspiler.new.transpile(code)
  else
    $stderr.puts "Usage: ruby transpiler.rb <script.ct>"
  end
end


