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

      # Cache field schemas so VarDecl can generate field-level Rc cleanup
      @struct_schemas ||= {}
      @struct_schemas[node.name.to_sym] = node.fields

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
      # Don't add ! if the type is already an error union
      return_type_str = final_type.start_with?("!") ? final_type : "!#{final_type}"
      signature = "pub fn #{node.name}(#{all_params.join(', ')}) #{return_type_str}"

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

      # Detect multiowned (Rc), shared (Arc), locked (sync), vs unique-heap storage
      is_multiowned = node.type_info&.multiowned?
      is_shared     = node.type_info&.shared?
      is_rc         = is_multiowned || is_shared
      is_locked       = node.type_info&.locked?
      is_write_locked = node.type_info&.write_locked?
      is_any_sync     = is_locked || is_write_locked
      is_heap       = node.storage == :heap && !is_rc && !is_any_sync

      # Detect MOVE: explicit affine ownership transfer (no retain).
      # VAR b = MOVE a; -> copy the Rc/Arc handle as-is, mark a as done.
      is_move_rhs  = node.value.is_a?(AST::MoveNode)
      rhs_ident    = if is_move_rhs && node.value.value.is_a?(AST::Identifier)
                       node.value.value
                     elsif node.value.is_a?(AST::Identifier)
                       node.value
                     end

      # 2. Generate Declaration — default for Rc/Arc/SharedLocked identifier RHS is retain (clone).
      # MOVE overrides this to a raw handle transfer (no retain).
      # Exception: inside a WITH block the RHS is already the unwrapped plain value, not an Rc/Arc.
      rc_map = @rc_unwrap_map || {}
      rhs_is_unwrapped = rhs_ident && rc_map.key?(rhs_ident.name)
      rhs_ti = rhs_ident&.type_info
      value_code = if is_rc && is_move_rhs && rhs_ident
        # MOVE: transfer handle without incrementing ref count
        rhs_ident.name
      elsif is_rc && rhs_ti && (rhs_ti.multiowned? || rhs_ti.shared?) && !rhs_is_unwrapped
        # Default: clone (retain) so both handles stay alive
        base_type = rhs_ti.resolved.to_s
        func = rhs_ti.shared? ? "arcRetain" : "rcRetain"
        "CheatLib.#{func}(#{transpile_type(base_type)}, #{rhs_ident.name})"
      else
        visit(node.value)
      end

      decl = "#{keyword} #{node.name}#{annotation} = #{value_code};"

      # 3. Generate Suppression
      suppression = "_ = &#{node.name};"

      affine_logic = ""
      if is_rc
        base_type = node.type_info.resolved.to_s
        release_func = is_shared ? "arcRelease" : "rcRelease"
        # Conditional defer so MOVE can suppress cleanup on the source variable.
        # Even if this variable is never MOVEd, the flag overhead is negligible.
        affine_logic  = "var #{node.name}_moved = false; _ = &#{node.name}_moved;\n"
        affine_logic += "defer if (!#{node.name}_moved) CheatLib.#{release_func}(#{transpile_type(base_type)}, rt.heapAlloc(), #{node.name});\n"

        # Release any @multiowned/@shared fields BEFORE the struct itself (Zig LIFO: emit after struct defer)
        schema = (@struct_schemas ||= {})[node.type_info.resolved]
        if schema
          schema.each do |fname, fdef|
            field_type = Type.new(fdef[:type])
            if field_type.multiowned?
              inner = field_type.resolved.to_s
              affine_logic += "defer if (!#{node.name}_moved) CheatLib.rcRelease(#{transpile_type(inner)}, rt.heapAlloc(), #{node.name}.data.#{fname});\n"
            elsif field_type.shared?
              inner = field_type.resolved.to_s
              affine_logic += "defer if (!#{node.name}_moved) CheatLib.arcRelease(#{transpile_type(inner)}, rt.heapAlloc(), #{node.name}.data.#{fname});\n"
            end
          end
        end
      elsif is_locked
        # @locked = *Locked(T): single-ownership heap pointer
        base_type = node.type_info.resolved.to_s
        zig_inner_t = transpile_type(base_type)
        affine_logic  = "var #{node.name}_moved = false; _ = &#{node.name}_moved;\n"
        affine_logic += "defer if (!#{node.name}_moved) CheatLib.lockedDestroy(#{zig_inner_t}, rt.heapAlloc(), #{node.name});\n"
      elsif is_write_locked
        # @writeLocked = *RwLocked(T): single-ownership heap pointer
        base_type = node.type_info.resolved.to_s
        zig_inner_t = transpile_type(base_type)
        affine_logic  = "var #{node.name}_moved = false; _ = &#{node.name}_moved;\n"
        affine_logic += "defer if (!#{node.name}_moved) CheatLib.rwLockedDestroy(#{zig_inner_t}, rt.heapAlloc(), #{node.name});\n"
      elsif is_heap
        # TODO: If definitively returned, eliminate this deferral
        affine_logic = <<~ZIG
          var #{node.name}_moved = false;
          _ = &#{node.name}_moved;
          defer if (!#{node.name}_moved) CheatLib.free(rt, #{node.name});
        ZIG
      end

      move_source_logic = ""
      if is_rc && is_move_rhs && rhs_ident
        # Suppress the source variable's defer — ownership has transferred
        move_source_logic = "#{rhs_ident.name}_moved = true;"
      elsif !is_rc && node.value.is_a?(AST::Identifier)
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

      # Track heap variables that need to be marked as moved
      move_statements = []
      rc_map = @rc_unwrap_map || {}
      field_inits = node.fields.map do |k, v|
        # If field value is a heap identifier, mark it as moved
        if v.is_a?(AST::Identifier) && v.type_info && v.type_info.requires_move? && v.storage == :heap
          move_statements << "#{v.name}_moved = true;"
        end

        # If field value is a multiowned/shared identifier, retain so the struct co-owns the reference.
        # (Expression results like function calls already carry count=1; no extra retain needed.)
        val_code = if v.is_a?(AST::Identifier) && !rc_map.key?(v.name)
          if v.type_info&.multiowned?
            base_type = v.type_info.resolved.to_s
            "CheatLib.rcRetain(#{transpile_type(base_type)}, #{v.name})"
          elsif v.type_info&.shared?
            base_type = v.type_info.resolved.to_s
            "CheatLib.arcRetain(#{transpile_type(base_type)}, #{v.name})"
          else
            visit(v)
          end
        else
          visit(v)
        end
        ".#{k} = #{val_code}"
      end.join(", ")

      struct_init = "#{node.name}{ #{field_inits} }"
      move_logic = move_statements.join("\n")

      if node.storage == :heap # You set this in the Annotator!
       <<~ZIG
          blk: {
             #{move_logic}
             const ptr = try rt.heapAlloc().create(#{node.name});
             ptr.* = #{struct_init};
             break :blk ptr;
          }
        ZIG
      else
        if move_logic.empty?
          struct_init
        else
          # Need a block to execute move logic before struct init
          <<~ZIG
            blk: {
               #{move_logic}
               break :blk #{struct_init};
            }
          ZIG
        end
      end

    # TODO: Need overflow logic for frame to overflow to heap / malloc
    when AST::ListLit
      # 1. Determine the Zig Type (T)
      #    The Annotator sets 'full_type' (e.g. :Number[] or :%User[])
      #    We need the element type, so strip leading % and ONE trailing []
      #    e.g., %Number[][] -> Number[] (element type for nested list)
      effective_type = node.coerced_type || node.full_type
      type_str = effective_type.to_s

      # Strip leading % and one trailing [] to get element type
      base_type_sym = type_str.gsub(/^%/, '').sub(/\[\]$/, '')
      zig_type = transpile_type(base_type_sym)

      # 2. Determine Allocator
      #    The Annotator sets 'storage' (:heap or :stack)
      allocator = node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

      # 3. Generate Items Slice
      #    Zig syntax for an array literal slice is: &.{ item1, item2 }
      if node.items.empty?
        items_slice = "&.{}"
      else
        items_list = node.items.map do |item|
          item_code = visit(item)
          # If item is an array type (ArrayList), convert to slice via .items
          if item.type_info&.array?
            "#{item_code}.items"
          else
            item_code
          end
        end.join(", ")
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
        inner_type = node.target.full_type.to_s.match(/HashMap<(.+)>/)[1]

        # For INDEX results (HashMap<T[]>), the runtime stores ArrayListUnmanaged(T)
        # We need to pass the actual stored type, not the conceptual slice type
        if inner_type.end_with?("[]")
          element_type = inner_type.gsub(/[\[\]%]/, '')
          zig_element = transpile_type(element_type)
          zig_type = "std.ArrayListUnmanaged(#{zig_element})"
        else
          zig_type = transpile_type(inner_type)
        end

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

    when AST::WithBlock
      rc_caps          = node.capabilities.select { |c| [:multiowned, :shared].include?(c[:capability]) }
      mutex_caps       = node.capabilities.select { |c| c[:capability] == :EXCLUSIVE && c[:resolved_type]&.locked? }
      rw_write_caps    = node.capabilities.select { |c| c[:capability] == :EXCLUSIVE && c[:resolved_type]&.write_locked? }
      rw_read_caps     = node.capabilities.select { |c| c[:capability] == :write_locked_read }

      # --- Rc/Arc (multiowned/shared) bindings ---
      rc_bindings = rc_caps.map do |cap|
        name = cap[:var_node].name
        inner = "__#{name}_unwrap"
        "const #{inner} = #{name}.data.*;\n_ = &#{inner};"
      end.join("\n")

      # --- Mutex bindings: acquire(), bind alias as *T ---
      mutex_bindings = mutex_caps.map do |cap|
        var_name   = cap[:var_node].name
        alias_name = cap[:alias] || var_name
        guard_var  = "__#{var_name}_guard"
        <<~ZIG.chomp
          var #{guard_var} = #{var_name}.acquire();
          defer #{guard_var}.release();
          const #{alias_name} = #{guard_var}.get();
          _ = &#{alias_name};
        ZIG
      end.join("\n")

      # --- RwLock write bindings: write(), bind alias as *T (exclusive) ---
      rw_write_bindings = rw_write_caps.map do |cap|
        var_name   = cap[:var_node].name
        alias_name = cap[:alias] || var_name
        guard_var  = "__#{var_name}_guard"
        <<~ZIG.chomp
          var #{guard_var} = #{var_name}.write();
          defer #{guard_var}.release();
          const #{alias_name} = #{guard_var}.get();
          _ = &#{alias_name};
        ZIG
      end.join("\n")

      # --- RwLock read bindings: read(), bind alias as *const T (shared read) ---
      rw_read_bindings = rw_read_caps.map do |cap|
        var_name   = cap[:var_node].name
        alias_name = cap[:alias] || var_name
        guard_var  = "__#{var_name}_guard"
        <<~ZIG.chomp
          var #{guard_var} = #{var_name}.read();
          defer #{guard_var}.release();
          const #{alias_name} = #{guard_var}.get();
          _ = &#{alias_name};
        ZIG
      end.join("\n")

      # Install Rc unwrap map
      prev_rc_map = @rc_unwrap_map || {}
      @rc_unwrap_map = prev_rc_map.merge(
        rc_caps.map { |c| [c[:var_node].name, "__#{c[:var_node].name}_unwrap"] }.to_h
      )

      # Install locked unwrap map so Identifier resolution uses the alias,
      # and function-call arg transpilation knows to deref (*T → T).
      all_sync_caps = mutex_caps + rw_write_caps + rw_read_caps
      prev_locked_map = @locked_unwrap_map || {}
      @locked_unwrap_map = prev_locked_map.merge(
        all_sync_caps.map { |c| [(c[:alias] || c[:var_node].name), true] }.to_h
      )

      body = transpile_block(node.body)

      @rc_unwrap_map     = prev_rc_map
      @locked_unwrap_map = prev_locked_map

      all_bindings = [rc_bindings, mutex_bindings, rw_write_bindings, rw_read_bindings].reject(&:empty?).join("\n")
      "{\n#{all_bindings}\n#{body}\n}"

    when AST::FuncCall, AST::MethodCall
      return transpile_Intrinsic(node) if !node.zig_pattern.nil?
      # Standard call (pass rt)
      # Note: We don't add 'try' here - let the caller decide via OR RAISE or context
      locked_map = @locked_unwrap_map || {}
      args_zig = node.args.map do |a|
        arg_code = visit(a)
        # Locked-unwrap aliases are Zig `*T` pointers; deref to pass as value to functions.
        if a.is_a?(AST::Identifier) && locked_map.key?(a.name)
          "#{arg_code}.*"
        # If argument is an array (ArrayList), convert to slice via .items for function params
        elsif a.type_info&.array?
          "#{arg_code}.items"
        else
          arg_code
        end
      end
      args = ["rt"] + args_zig
      call = "#{node.name}(#{args.join(', ')})"

      # If the call returns an error union and is not being handled by OR,
      # we need to add 'try' to propagate errors implicitly
      return_type = Type.new(node.full_type)
      if return_type.error_union?
        # Error union - caller should use OR to handle, or we propagate with try
        "try #{call}"
      else
        # Non-error return - just call
        "try #{call}"  # All functions can error in CHEAT (runtime allocations)
      end

    when AST::ReturnNode
      rc_map = @rc_unwrap_map || {}

      # MOVE in return: transfer Rc/Arc handle to caller without retain.
      # The source's conditional defer is suppressed by setting _moved = true.
      if node.value.is_a?(AST::MoveNode) && node.value.value.is_a?(AST::Identifier)
        src_name = node.value.value.name
        return "#{src_name}_moved = true;\nreturn #{src_name};"
      end

      # Default: for Rc/Arc identifier returns, retain so caller gets its own reference
      # and the local defer can still release the function's copy.
      # Exception: inside a WITH block the variable is already the plain unwrapped value.
      if node.value.is_a?(AST::Identifier) && !rc_map.key?(node.value.name)
        ti = node.value.type_info
        if ti&.multiowned?
          base_type = ti.resolved.to_s
          return "return CheatLib.rcRetain(#{transpile_type(base_type)}, #{node.value.name});"
        elsif ti&.shared?
          base_type = ti.resolved.to_s
          return "return CheatLib.arcRetain(#{transpile_type(base_type)}, #{node.value.name});"
        end
      end

      val_code = node.value.nil? ? "" : visit(node.value)

      # If we are returning a variable, we are moving it out.
      # We must disable the local free.
      prefix = ""
      if node.value.is_a?(AST::Identifier)
        ti = node.value.type_info
        # Locked/RwLocked vars transfer ownership on return (suppress local defer, no retain needed)
        if ti&.locked? || ti&.write_locked?
          var_name = node.value.name
          prefix = "#{var_name}_moved = true;\n"
        # Only generate move tracking for heap variables that have _moved tracking set up
        elsif ti&.requires_move? && node.value.storage == :heap
          var_name = node.value.name
          prefix = "#{var_name}_moved = true;\n"
        end
      end

      "#{prefix}return #{val_code};"

    when AST::GetField
      target_code = visit(node.target)
      rc_map     = @rc_unwrap_map     || {}
      locked_map = @locked_unwrap_map || {}
      # target_code is already the unwrapped alias when inside a WITH block,
      # so skip the .data. indirection in that case.
      is_rc_unwrapped     = node.target.is_a?(AST::Identifier) && rc_map.key?(node.target.name)
      is_locked_unwrapped = node.target.is_a?(AST::Identifier) && locked_map.key?(node.target.name)
      ti = node.target.type_info
      if (ti&.multiowned? || ti&.shared?) && !is_rc_unwrapped
        # Rc(T)/Arc(T) store the value as .data (*T); Zig auto-derefs through the pointer
        "#{target_code}.data.#{node.field}"
      elsif (ti&.locked? || ti&.write_locked?) && !is_locked_unwrapped
        # *Locked(T) / *RwLocked(T): auto-deref pointer, then access .data field
        "#{target_code}.data.#{node.field}"
      else
        "#{target_code}.#{node.field}"
      end

    when AST::CapabilityWrap
      inner_code = visit(node.value)
      base_type  = node.value.resolved_type.to_s
      zig_base   = transpile_type(base_type)

      if node.sync == :locked && node.ownership == :shared
        # Arc(Locked(T)): lockedCreate then arcCreate
        <<~ZIG.chomp
          blk_sl: {
              const __sl_inner = try CheatLib.lockedCreate(#{zig_base}, rt.heapAlloc(), #{inner_code});
              break :blk_sl try CheatLib.arcCreate(CheatLib.Locked(#{zig_base}), rt.heapAlloc(), __sl_inner);
          }
        ZIG
      elsif node.sync == :locked
        "try CheatLib.lockedCreate(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      elsif node.sync == :write_locked
        "try CheatLib.rwLockedCreate(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      elsif node.ownership == :shared
        "try CheatLib.arcCreate(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      elsif node.ownership == :multiowned
        "try CheatLib.rcCreate(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      else
        inner_code
      end

    when AST::MoveNode
      # MOVE expr — handled by parent VarDecl/ReturnNode; fallback emits raw value
      visit(node.value)

    when AST::Copy
      # Zig copies structs by value on assignment, so just return the inner expression
      visit(node.value)

    when AST::OptionalUnwrap
      # Zig uses .? for optional unwrapping
      "#{visit(node.target)}.?"

    when AST::Identifier
      # [FIX] Handle '_' Identifier acting as a Placeholder
      if node.name == "_" && @placeholder_name
        return @placeholder_name
      end

      # Inside a WITH block, use the unwrapped inner alias instead of the Rc handle
      rc_map = @rc_unwrap_map || {}
      return rc_map[node.name] if rc_map.key?(node.name)

      node.name

    when AST::Literal
      case node.type
      when :STRING
        "\"#{node.value}\""  # Add quotes!
      when :NUMBER, :INT64
        node.value.to_i.to_s # Force Integer for Zig i64 compatibility
      when :BOOLEAN
        node.value.to_s      # "true"/"false" is fine
      when :NIL
        "null"               # Zig's null for optionals
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
      return transpile_OrRescue(node) if node.op == :OR_RESCUE

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

    when AST::Raise
      # RAISE "message" - return an error in Zig
      msg = visit(node.message_expr)
      "return error.CheatError"

    # Marker nodes for OR RAISE / OR PASS - handled in transpile_OrRescue
    when AST::OrRaise
      "error.OrRaise"  # Should not be visited directly
    when AST::OrPass
      "undefined"  # Should not be visited directly

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

    elsif node.right.is_a?(AST::IndexOp)
      return transpile_index_grouping(node.left, node.right.expression, node)

    elsif node.right.is_a?(AST::ReduceOp)
      return transpile_reduce(node.left, node.right)

    elsif node.right.is_a?(AST::OrderByOp)
      return transpile_order_by(node.left, node.right, node)

    elsif node.right.is_a?(AST::LimitOp)
      return transpile_limit(node.left, node.right, node)

    elsif node.right.is_a?(AST::UnnestOp)
      return transpile_unnest(node.left, node.right, node)

    elsif node.right.is_a?(AST::DistinctOp)
      return transpile_distinct(node.left, node.right, node)
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

  # --- ERROR HANDLING (OR RESCUE) ---
  def transpile_OrRescue(node)
    t_left = Type.new(node.left.full_type)

    # For error union handling, we need the raw call without 'try'
    # Visit the left normally first (which may add 'try' for error unions)
    left = visit(node.left)

    # If this is an error union, the visit may have added 'try' - strip it
    # because we'll handle it with catch or explicit try here
    left_raw = left.sub(/^try /, '')

    # Handle OR RAISE: bubble up error (Zig's `try`)
    if node.right.is_a?(AST::OrRaise)
      if t_left.error_union?
        # Use Zig's try to propagate error
        return "try #{left_raw}"
      else
        # Non-error type: just return the value
        return left
      end
    end

    # Handle OR PASS: ignore error, use undefined (Zig's `catch |_| undefined`)
    if node.right.is_a?(AST::OrPass)
      if t_left.error_union?
        # Use Zig's catch to ignore error and return undefined
        return "(#{left_raw} catch undefined)"
      else
        return left
      end
    end

    # Handle error union with default value: !T OR default -> T
    if t_left.error_union?
      right = visit(node.right)
      # Use Zig's catch to provide fallback value
      return "(#{left_raw} catch #{right})"
    end

    # Standard OR behavior (non-error types)
    right = visit(node.right)
    return "(#{left}) orelse #{right}"
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

  def transpile_index_grouping(list_node, expression_node, smooth_node)
    # INDEX groups elements by a key, returning HashMap<KeyType, ElementType[]>
    # e.g., users s> INDEX _.age  returns HashMap<Int64, User[]>

    # 1. Setup Types
    #    Get the element type from the input list
    list_flux_type = list_node.full_type
    element_type_str = list_flux_type.to_s.gsub(/[\[\]%]/, '')
    element_zig_type = transpile_type(element_type_str)

    # The result type is an array of the element type (for HashMap values)
    value_zig_type = "[]#{element_zig_type}"

    # 2. Transpile Inputs
    list_code = visit(list_node)

    # 3. Handle the '_' placeholder
    @placeholder_name = "it"
    expr_code = visit(expression_node)
    @placeholder_name = nil

    alloc = smooth_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

    # 4. Generate Zig code for grouping
    #    We create a StringHashMap where values are ArrayLists of elements
    <<~ZIG
      blk: {
          const idx_src_list = #{list_code};
          var idx_result: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(#{element_zig_type})) = .{};

          // Handle both ArrayList and Slice
          const idx_items = if (@hasField(@TypeOf(idx_src_list), "items")) idx_src_list.items else idx_src_list;

          for (idx_items) |it| {
              const idx_key = #{expr_code};
              const gop = idx_result.getOrPut(#{alloc}, idx_key) catch @panic("INDEX allocation failed");
              if (!gop.found_existing) {
                  gop.value_ptr.* = std.ArrayListUnmanaged(#{element_zig_type}){};
              }
              gop.value_ptr.append(#{alloc}, it) catch @panic("INDEX append failed");
          }
          break :blk idx_result;
      }
    ZIG
  end

  def transpile_reduce(list_node, reduce_node)
    # REDUCE: list s> REDUCE(initial) acc + _.value
    # Generates a loop that accumulates values

    # 1. Setup Types
    acc_type = transpile_type(reduce_node.full_type)

    # 2. Transpile Inputs
    list_code = visit(list_node)
    initial_code = visit(reduce_node.initial_value)

    # 3. Handle placeholders for 'acc' and '_'
    @placeholder_name = "it"
    @acc_placeholder = "acc"
    expr_code = visit(reduce_node.expression)
    @placeholder_name = nil
    @acc_placeholder = nil

    # 4. Generate Zig code for reduce loop
    <<~ZIG
      blk: {
          const red_src_list = #{list_code};
          var acc: #{acc_type} = #{initial_code};

          // Handle both ArrayList and Slice
          const red_items = if (@hasField(@TypeOf(red_src_list), "items")) red_src_list.items else red_src_list;

          for (red_items) |it| {
              acc = #{expr_code};
          }
          break :blk acc;
      }
    ZIG
  end

  def transpile_order_by(list_node, order_node, smooth_node)
    # ORDER_BY: list s> ORDER_BY _.field
    # Generates code that copies and sorts the list

    # 1. Setup Types
    list_flux_type = list_node.full_type
    element_type_str = list_flux_type.to_s.gsub(/[\[\]%]/, '')
    element_zig_type = transpile_type(element_type_str)

    # 2. Transpile Inputs
    list_code = visit(list_node)

    # 3. Handle the '_' placeholder - use 'a' and 'b' for comparison
    # We need to generate the key expression for both 'a' and 'b'
    @placeholder_name = "a"
    key_expr_a = visit(order_node.expression)
    @placeholder_name = "b"
    key_expr_b = visit(order_node.expression)
    @placeholder_name = nil

    alloc = smooth_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

    # 4. Generate Zig code for sorting
    <<~ZIG
      blk: {
          const ord_src_list = #{list_code};

          // Handle both ArrayList and Slice
          const ord_src_items = if (@hasField(@TypeOf(ord_src_list), "items")) ord_src_list.items else ord_src_list;

          // Copy to new list
          var ord_result = try CheatLib.makeList(#{element_zig_type}, #{alloc}, ord_src_items);
          _ = &ord_result; // Suppress mutability warning (contents are mutated via .items)

          // Sort using custom comparator
          std.mem.sort(#{element_zig_type}, ord_result.items, {}, struct {
              pub fn lessThan(_: void, a: #{element_zig_type}, b: #{element_zig_type}) bool {
                  return #{key_expr_a} < #{key_expr_b};
              }
          }.lessThan);

          break :blk ord_result;
      }
    ZIG
  end

  def transpile_limit(list_node, limit_node, smooth_node)
    # LIMIT: list s> LIMIT n
    # Returns at most n items from the list

    # 1. Setup Types
    list_flux_type = list_node.full_type
    element_type_str = list_flux_type.to_s.gsub(/[\[\]%]/, '')
    element_zig_type = transpile_type(element_type_str)

    # 2. Transpile Inputs
    list_code = visit(list_node)
    count_code = visit(limit_node.count)

    alloc = smooth_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

    # 3. Generate Zig code for limit
    #    Use @min to handle case where list is smaller than limit
    <<~ZIG
      blk: {
          const lim_src_list = #{list_code};

          // Handle both ArrayList and Slice
          const lim_src_items = if (@hasField(@TypeOf(lim_src_list), "items")) lim_src_list.items else lim_src_list;

          // Calculate actual count (min of requested and available)
          const lim_requested: usize = @intCast(#{count_code});
          const lim_actual = @min(lim_requested, lim_src_items.len);

          // Create new list with limited items
          const lim_result = try CheatLib.makeList(#{element_zig_type}, #{alloc}, lim_src_items[0..lim_actual]);

          break :blk lim_result;
      }
    ZIG
  end

  def transpile_unnest(list_node, unnest_node, smooth_node)
    # UNNEST: list s> UNNEST _.arr (flatmap)
    # Flattens nested arrays into a single list

    # 1. Setup Types - get the element type of the INNER array
    inner_array_type = unnest_node.full_type.to_s  # e.g., "Int64[]"
    inner_element_type = inner_array_type.gsub(/[\[\]%]/, '')
    inner_zig_type = transpile_type(inner_element_type)

    # 2. Transpile Inputs
    list_code = visit(list_node)

    # 3. Handle the '_' placeholder
    @placeholder_name = "it"
    expr_code = visit(unnest_node.expression)
    @placeholder_name = nil

    alloc = smooth_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

    # 4. Generate Zig code for flattening
    <<~ZIG
      blk: {
          const unn_src_list = #{list_code};
          var unn_result = try CheatLib.makeList(#{inner_zig_type}, #{alloc}, &.{});

          // Handle both ArrayList and Slice
          const unn_outer_items = if (@hasField(@TypeOf(unn_src_list), "items")) unn_src_list.items else unn_src_list;

          for (unn_outer_items) |it| {
              // Get the inner array from each element
              const unn_inner = #{expr_code};
              const unn_inner_items = if (@hasField(@TypeOf(unn_inner), "items")) unn_inner.items else unn_inner;

              // Append all inner items to result
              for (unn_inner_items) |inner_it| {
                  try unn_result.append(#{alloc}, inner_it);
              }
          }
          break :blk unn_result;
      }
    ZIG
  end

  def transpile_distinct(list_node, distinct_node, smooth_node)
    # DISTINCT: list s> DISTINCT _.field (or DISTINCT _)
    # Returns unique elements, preserving insertion order

    # 1. Setup Types
    list_flux_type = list_node.full_type
    element_type_str = list_flux_type.to_s.gsub(/[\[\]%]/, '')
    element_zig_type = transpile_type(element_type_str)

    # Key type for uniqueness comparison
    key_flux_type = distinct_node.full_type
    key_zig_type = transpile_type(key_flux_type.to_s)

    # 2. Transpile Inputs
    list_code = visit(list_node)

    # 3. Handle the '_' placeholder - we need two versions
    #    One for the outer loop (it) and one for the inner check (it2)
    @placeholder_name = "it"
    expr_code = visit(distinct_node.expression)
    @placeholder_name = "it2"
    expr_code_inner = visit(distinct_node.expression)
    @placeholder_name = nil

    alloc = smooth_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

    # 4. Generate Zig code for order-preserving distinct
    #    Using linear scan for correctness with all types (including floats)
    <<~ZIG
      blk: {
          const dist_src_list = #{list_code};
          var dist_result = try CheatLib.makeList(#{element_zig_type}, #{alloc}, &.{});

          // Handle both ArrayList and Slice
          const dist_items = if (@hasField(@TypeOf(dist_src_list), "items")) dist_src_list.items else dist_src_list;

          for (dist_items) |it| {
              const dist_key = #{expr_code};

              // Check if this key already exists in result (linear scan)
              var dist_found = false;
              const dist_result_items = dist_result.items;
              for (dist_result_items) |it2| {
                  const dist_existing_key = #{expr_code_inner};
                  if (CheatLib.eql(dist_key, dist_existing_key)) {
                      dist_found = true;
                      break;
                  }
              }

              if (!dist_found) {
                  try dist_result.append(#{alloc}, it);
              }
          }
          break :blk dist_result;
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

  # Delegates to Type#zig_type for type-to-Zig conversion.
  # This keeps the transpiler interface stable while the logic lives in Type.
  def transpile_type(type)
    Type.new(type).zig_type
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

    # E. Error union coercion: T -> !T (Zig handles this automatically)
    #    No explicit cast needed when returning payload from error union function
    if to_str.start_with?("!")
      payload_type = to_str[1..]
      if from_str == payload_type || from == to.to_s[1..].to_sym
        return code  # Zig auto-wraps payload in error union
      end
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

