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

      frame.registers.each_with_index do |val, r_idx|
        next if val.nil? # Skip empty registers

        reg_node = "#{frame_id}_R#{r_idx}"

        if is_primitive?(val)
          # Primitives live ON the stack
          lines << "    #{reg_node}[\"R#{r_idx}: #{val}\"]"
        else
          # References point TO the Arena
          lines << "    #{reg_node}((\"R#{r_idx}\"))"

          # Draw Arrow
          target_id = obj_map[val.object_id]
          if target_id
            # Dotted for Views, Solid for Owners
            arrow = (val.is_a?(FluxView) || val.is_a?(FluxPtr)) ? "-.->" : "-->"
            lines << "    #{reg_node} #{arrow} #{target_id}"
          elsif val.is_a?(FluxObject)
             # Object is in register but NOT in Arena? (Maybe a constant?)
             lines << "    #{reg_node} -.-> CONST_#{val.object_id}[\"Constant: #{safe_inspect(val)}\"]"
          end
        end
      end
      lines << "  end"
    end

    lines.join("\n")
  end

  private

  def is_primitive?(val)
    val.is_a?(Numeric) || val.is_a?(TrueClass) || val.is_a?(FalseClass) || val.is_a?(FluxByte)
  end

  def safe_inspect(obj)
    # Escape quotes for Mermaid
    obj.to_s.gsub('"', "'").gsub('<', '&lt;').gsub('>', '&gt;')
  end
end

