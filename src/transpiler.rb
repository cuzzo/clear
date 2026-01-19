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
      const std = @import("std");
      const CheatHeader = @import("runtime-header.zig");
      const CheatLib = CheatHeader.CheatLib;
      const Runtime = CheatHeader.Runtime;
      const EbrContext = CheatHeader.EbrContext;

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
      final_type = transpile_type(node.return_type || :Void)

      params_zig = node.params.map do |param|
        p_name = param[:name]
        p_type = transpile_type(param[:type])
        "#{p_name}: #{p_type}"
      end

      # We inject 'rt' into every function signature
      all_params = ["rt: *Runtime"] + params_zig
      signature = "pub fn #{node.name}(#{all_params.join(', ')}) !#{final_type}"

      prologue = "const frame_mark = rt.saveFrameMark();\ndefer rt.restoreFrameMark(frame_mark);\n"
      prologue = node.uses_frame ? prologue : "_ = &rt;"
      body = transpile_block(node.body)

      <<~ZIG
        #{signature} {
            #{prologue}
            #{body}
        }
      ZIG

    # TODO: Need to call destroy, have objects recursively destroy pointers / resources
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
      # TODO: Have the annotator determine whether a var is used, and whether a mutable is mutated.
      suppression = "_ = &#{node.name};"

      is_heap = node.storage == :heap

      affine_logic = ""
      # TODO: If definitively returned, eliminate this deferral
      if is_heap
        # 1. Create the moved flag
        # 2. Create the defer guard
        # 3. TODO: use destroy, not free
        affine_logic = <<~ZIG
          var #{node.name}_moved = false;
          _ = &#{node.name}_moved;
          defer if (!#{node.name}_moved) CheatLib.free(rt, #{node.name});
        ZIG
      end

      move_source_logic = ""
      if node.value.is_a?(AST::Identifier)
        # Check if the RHS variable requires a move (Heap types, etc.)
        # The Annotator populates 'type_info' on identifiers.
        if node.value.type_info && node.value.type_info.requires_move? && node.value.storage == :heap
           move_source_logic = "#{node.value.name}_moved = true;"
        end
      end

      "#{decl} #{suppression}\n#{affine_logic}\n#{move_source_logic}"

    when AST::Assignment
      # 1. Resolve the Target string
      #    The target might be a simple String ("i") or a complex Node (GetField/GetIndex)
      target_str =
        if node.name.is_a?(String)
          node.name
        elsif node.name.is_a?(AST::Identifier)
          node.name.name
        elsif node.name.is_a?(AST::GetField)
          target = visit(node.name.target)
          field  = node.name.field
          value  = visit(node.value)
          return "#{target}.#{field} = #{value};"
        elsif node.name.is_a?(AST::GetIndex)
          # Check if target is a Map
          target_node = node.name.target
          if target_node.metatype == :hashmap
             # Generate mapPut

             # TODO: Helper
             inner_type = target_node.full_type.to_s.match(/HashMap<(.+)>/)[1]
             zig_type = transpile_type(inner_type)

             map_ref = visit(target_node)
             key_ref = visit(node.name.index)
             val_ref = visit(node.value)

             # Pass &map_ref because Put modifies the map struct
             return "try CheatLib.mapPut(#{zig_type}, rt.heapAlloc(), &#{map_ref}, #{key_ref}, #{val_ref});"
          end
          arr_ref = visit(target_node)
          idx_ref = visit(node.name.index)
          val_ref = visit(node.value)

          return "CheatLib.setAt(#{arr_ref}, #{idx_ref}, #{val_ref});"
        else
          # Recursive visit for things like 'user.id' or 'list[0]'
          visit(node.name)
        end

      # 2. Resolve the Value
      value_str = visit(node.value)

      move_logic = ""
      if node.value.is_a?(AST::Identifier)
        if node.value.type_info && node.value.type_info.requires_move? && node.value.storage == :heap
          move_logic = "\n#{node.value.name}_moved = true;"
        end
      end

      # 3. Output Zig Code
      "#{target_str} = #{value_str}; #{move_logic}"

    when AST::StructLit
      # CHEAT: User{ id: 1 }
      # ZIG:   User{ .id = 1 }

      # ... field init logic ...
      field_inits = node.fields.map { |k,v| ".#{k} = #{visit(v)}" }.join(", ")
      struct_init = "#{node.name}{ #{field_inits} }"

      if node.storage == :heap # You set this in the Annotator!
       <<~ZIG
          blk: {
             const ptr = try rt.heapAlloc().create(#{node.name});
             ptr.* = #{struct_init};
             break :blk ptr;
          }
        ZIG
      else
        struct_init
      end

    # TODO: Need overflow logic for frame to overflow to heap / malloc
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
      allocator = node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

      # 3. Generate Items Slice
      #    Zig syntax for an array literal slice is: &.{ item1, item2 }
      if node.items.empty?
        items_slice = "&.{}"
      else
        items_list = node.items.map { |item| visit(item) }.join(", ")
        items_slice = "&.{ #{items_list} }"
      end

      # 4. Generate the Call
      #    Result: try rt.makeList(i64, rt.frameAlloc(), &.{ 1, 2, 3 })
      "try CheatLib.makeList(#{zig_type}, #{allocator}, #{items_slice})"


    # TODO: Try on frame.
    when AST::HashLit
      # 1. Extract Value Type (V)
      #    "HashMap<Int64>" -> "i64"
      type_str = node.full_type.to_s
      inner_type = type_str.match(/HashMap<(.+)>/)[1]
      zig_type = transpile_type(inner_type)

      # 2. Generate Creation
      #    var map = try CheatLib.makeHashMap(i64);
      creation = "try CheatLib.makeHashMap(#{zig_type})"

      # 3. Generate Initializers (Block Expression)
      #    Zig doesn't have a simple Map Literal syntax, so we stick to creation-only
      #    for the expression, or use a block if we want to populate immediately.
      #    For v0.1, let's just return the empty map creation and let users use 'set'.
      creation

    when AST::GetIndex
      # 1. Resolve Target and Index
      target = visit(node.target)
      index = visit(node.index)

      if node.target.metatype == :hashmap
        inner_type = node.target.full_type.match(/HashMap<(.+)>/)[1]
        zig_type = transpile_type(inner_type)

        "CheatLib.mapGet(#{zig_type}, #{target}, #{index})"
      else
        "CheatLib.getAt(#{target}, #{index})"
      end

    # TODO: See where drops live
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
      val_code = node.value.nil? ? "" : visit(node.value)

      # If we are returning a variable, we are moving it out.
      # We must disable the local free.
      if node.value.is_a?(AST::Identifier)
        # Check if it's a heap variable (simple heuristic for now)
        var_name = node.value.name
        # Ideally look up scope, but for now assuming pattern:
        prefix = "#{var_name}_moved = true;\n"
      else
        prefix = ""
      end

      "#{prefix}return #{val_code};"

    when AST::GetField
      "#{visit(node.target)}.#{node.field}"

    when AST::Copy
      # Zig copies structs by value on assignment, so just return the inner expression
      visit(node.value)

    when AST::Identifier
      # [FIX] Handle '_' Identifier acting as a Placeholder
      if node.name == "_" && @placeholder_name
        return @placeholder_name
      end

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

    # TODO: Use Frame unless marked escaping
    when AST::BinaryOp
      return transpile_Smooth(node) if node.op == :SMOOTH

      left = visit(node.left)
      right = visit(node.right)

      if node.op == :ADD || node.op == "+"
        # Check if we are operating on Strings
        # Annotator ensures full_type is set (e.g. "String[]" or "%String[]")
        t_left = node.left.full_type.to_s
        t_right = node.right.full_type.to_s

        alloc = node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

        if Type.new(t_left).string? || Type.new(t_right).string?
          # Generate call to runtime helper
          # We use heapAlloc to ensure the result survives (safe default)
          return "try CheatLib.concat(#{alloc}, #{left}, #{right})"
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

    when AST::Assert
      cond = visit(node.condition)
      "CheatLib.assert(#{cond}, \"#{node.message}\")"

    else
      raise "Unknown Node: #{node.class}"
    end
  end

  def transpile_Smooth(node)
    lhs = node.left
    rhs = node.right

    # Check Higher-Order functions
    if node.right.is_a?(AST::SelectOp)
      return transpile_select_projection(node.left, node.right.expression)

    elsif node.right.is_a?(AST::WhereOp)
      return transpile_where_filter(node.left, node.right.expression)
    end

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

    # TODO: Clone rhs??
    if rhs.respond_to?(:zig_pattern)
      synthetic_call.zig_pattern = rhs.zig_pattern
    end
    if rhs.respond_to?(:full_type)
      synthetic_call.full_type = rhs.full_type
    end
    if rhs.respond_to?(:coerced_type)
      synthetic_call.coerced_type = rhs.coerced_type
    end

    # Visit the fake node as if it were in the original source
    visit(synthetic_call)
  end

  # --- HIGHER ORDER FUNCTIONS ---
  def transpile_select_projection(list_node, expression_node)
    # 1. Setup Types
    #    We need the Result Type to create the new List
    result_flux_type = expression_node.full_type
    result_zig_type  = transpile_type(result_flux_type)

    # 2. Transpile Inputs
    list_code = visit(list_node)

    # 3. Handle the '_' placeholder
    #    We tell the Transpiler: "When you see _, print 'it'"
    #    We can use a temporary instance variable or a context stack.
    @placeholder_name = "it"
    expr_code = visit(expression_node)
    @placeholder_name = nil

    alloc = expression_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

    # 4. Generate Inline Loop
    #    We use a Zig block: { ... break :blk list; }
    <<~ZIG
      blk: {
          const src_list = #{list_code};
          var res_list = try CheatLib.makeList(#{result_zig_type}, #{alloc}, &.{});

          // Handle both ArrayList and Slice
          const items = if (@hasField(@TypeOf(src_list), "items")) src_list.items else src_list;

          for (items) |it| {
              const val = #{expr_code};
              try res_list.append(#{alloc}, val);
          }
          break :blk res_list;
      }
    ZIG
  end

  def transpile_where_filter(list_node, expression_node)
    # 1. Setup Types
    #    WHERE preserves the input type - if we filter Number[], we get Number[]
    #    We can read the list's type directly
    list_flux_type = list_node.full_type

    # Extract the element type (e.g. "Number[]" -> "Number")
    element_type_str = list_flux_type.to_s.gsub(/[\[\]%]/, '')
    element_zig_type = transpile_type(element_type_str)

    # 2. Transpile Inputs
    list_code = visit(list_node)

    # 3. Handle the '_' placeholder
    #    Same pattern as SELECT - the expression can reference 'it'
    @placeholder_name = "it"
    expr_code = visit(expression_node)
    @placeholder_name = nil

    alloc = expression_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

    # 4. Generate Inline Loop with Conditional Append
    #    Only append items where the expression evaluates to true
    <<~ZIG
      blk: {
          const src_list = #{list_code};
          var res_list = try CheatLib.makeList(#{element_zig_type}, #{alloc}, &.{});

          // Handle both ArrayList and Slice
          const items = if (@hasField(@TypeOf(src_list), "items")) src_list.items else src_list;

          for (items) |it| {
              const matches = #{expr_code};
              if (matches) {
                  try res_list.append(#{alloc}, it);
              }
          }
          break :blk res_list;
      }
    ZIG
  end

  def visit_Placeholder(node)
    # Return the name of the loop variable
    @placeholder_name || (raise "Use of '_' outside of SELECT context")
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
    #    For method calls, use the object's storage (not the result's storage)
    if pattern.include?("{alloc}")
      target_storage = if node.is_a?(AST::MethodCall) && node.object.respond_to?(:storage)
        node.object.storage
      else
        node.storage
      end
      alloc = target_storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"
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
      code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
      code
    end.join("\n")
  end

  def transpile_type(type)
    is_pointer = type.to_s.start_with?("%")

    t = type.to_s.gsub("%", "") # Strip explicit heap marker if present

    # 1. SPECIAL CASE: "String[]" is the atomic "Text" type
    #    We map this directly to Zig's string slice.
    #    This prevents "String[][]" from becoming a 3D array.
    if t == "String[]"
      return "[]const u8"
    end

    # 2. Handle Generic Array Recursion
    #    e.g. "String[][]" -> "[]" + transpile("String[]") -> "[][]const u8"
    #    e.g. "Int64[]"    -> "[]" + transpile("Int64")    -> "[]i64"
    if t.end_with?("[]")
      base = t[0...-2]
      zig_base = transpile_type(base)
      return "[]#{zig_base}"
    end

    # 3. Handle HashMaps
    #    HashMap<Int64> -> std.StringHashMapUnmanaged(i64)
    if t.start_with?("HashMap")
      if match = t.match(/HashMap<(.+)>/)
        inner_flux = match[1]
        inner_zig = transpile_type(inner_flux)
        return "std.StringHashMapUnmanaged(#{inner_zig})"
      end
    end

    zig_type =
    case t
    when "Number"          then "f64"
    when "Int64"           then "i64"
    when "String"          then "[]const u8"  # TODO: String isn't used
    when "String[]"        then "[]const u8"
    when "Void"            then "void"
    else t # Fallback for Struct names (e.g. "User")
    end

    return is_pointer && zig_type != "void" ? "*#{zig_type}" : zig_type
  end

  # TODO: from_type/to_type may need to be simplified
  def transpile_cast(code, from_type, to_type)
    from = from_type.respond_to?(:resolved) ? from_type.resolved : from_type
    to = to_type.respond_to?(:resolved) ? to_type.resolved : to_type

    return code if from == to

    # A. Int -> Float (e.g. i64 -> f64)
    if [:Int64, :Byte].include?(from) && to == :Number
      return "@floatFromInt(#{code})"
    end

    # B. Float -> Int (e.g. f64 -> i64)
    #    But skip if both are actually integer types (annotator may over-coerce)
    if from == :Number && to == :Int64
      return "@intFromFloat(#{code})"
    end

    # C. Int Widening (e.g. u8 -> i64)
    if from == :Byte && to == :Int64
      return "@intCast(#{code})"
    end

    # D. Array coercion (e.g. Any[] -> Int64[])
    #    ArrayList types are already correctly typed by makeList, no cast needed
    from_str = from.to_s
    to_str = to.to_s
    if from_str.end_with?("[]") && to_str.end_with?("[]")
      return code
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

  def indent_text(text, amount = 4)
    padding = " " * amount
    text.split("\n").map do |line|
      line.strip.empty? ? line : "#{padding}#{line}"
    end.join("\n")
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

