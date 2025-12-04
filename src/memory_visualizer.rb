require_relative "arena"

class MemoryVisualizer
  def initialize(vm)
    @vm = vm
    @arena = Arena.current
  end

  def generate_mermaid
    lines = ["graph LR"]

    # 1. Visualize the Heap (Arena)
    lines << "  subgraph Arena [Arena (Heap Memory)]"
    lines << "    direction TB"

    # We need a map of object_id -> node_id to draw arrows later
    obj_map = {}

    # Access private allocations for visualization
    allocations = @arena.instance_variable_get(:@allocations)

    allocations.each_with_index do |obj, idx|
      node_id = "HEAP_#{obj.object_id}"
      obj_map[obj.object_id] = node_id

      # Style differently if dead
      style = obj.is_alive ? "" : "style #{node_id} fill:#ffcccc,stroke:#ff0000"

      content = safe_inspect(obj)
      lines << "    #{node_id}(\"#{idx}: #{content}\")"
      lines << "    #{style}" if !style.empty?
    end
    lines << "  end"

    # 2. Visualize the Stack
    @vm.instance_variable_get(:@frames).each_with_index do |frame, f_idx|
      frame_id = "FRAME_#{f_idx}"
      func_name = frame.chunk.name

      lines << "  subgraph #{frame_id} [Stack Frame #{f_idx}: #{func_name}]"
      lines << "    direction TB"

      frame.registers.each_with_index do |val_boxed, r_idx|
        next if val_boxed.nil?

        reg_node = "#{frame_id}_R#{r_idx}"

        # 1. CHECK THE TAG (The source of truth)
        tag = defined?(Value) ? Value.get_tag(val_boxed) : Value::TAG_OBJ

        # === CASE A: STACK DATA (Numbers, Bools, Bytes, Nils) ===
        if tag != Value::TAG_OBJ
          # Unbox to native (Int/Float/Bool)
          native_val = Formatter.to_native(val_boxed)

          # Format nicely (e.g. 0xAF for bytes)
          display = if tag == Value::TAG_BYTE
             "Byte(#{native_val})"
          else
             native_val.inspect
          end

          # RENDER AS RECTANGLE [ ]
          lines << "    #{reg_node}[\"R#{r_idx}: #{display}\"]"

        # === CASE B: HEAP POINTERS (Objects, Strings, Arrays) ===
        else
          # It is a pointer. It gets a CIRCLE node.
          lines << "    #{reg_node}((\"R#{r_idx}\"))"

          # Now, where does it point?
          # We need the actual Ruby object the pointer represents.
          actual_obj = Value.as_obj(val_boxed)

          # 1. Is it in the Arena? (Dynamic Heap Object)
          if obj_map.key?(actual_obj.object_id)
            target_id = obj_map[actual_obj.object_id]
            # Solid Arrow for Owners, Dotted for Views
            arrow = (actual_obj.is_a?(FluxView) || actual_obj.is_a?(FluxStackPtr)) ? "-.->" : "-->"
            lines << "    #{reg_node} #{arrow} #{target_id}"

          # 2. Is it a Constant/Static? (Not in Arena Map)
          else
            # Create a "floating" node for Constants so we see them clearly
            const_id = "CONST_#{actual_obj.object_id}"

            # Format the content
            content = safe_inspect(actual_obj)

            # Render a special Hexagon node for Constants/Statics
            lines << "    #{const_id}{{ #{content} }}"
            lines << "    #{reg_node} -.-> #{const_id}"
          end
        end
      end
    end

    lines.join("\n")
  end

  private

  def is_primitive?(val)
    val.is_a?(Numeric) || val.is_a?(TrueClass) || val.is_a?(FalseClass) || val.is_a?(FluxByte)
  end

  def safe_inspect(obj)
    # Escape quotes for Mermaid
    obj.inspect.gsub('"', "'").gsub('<', '&lt;').gsub('>', '&gt;')
  end
end

