# frozen_string_literal: true

require "set"
require_relative "register_opcode_layout"

module MiniVM
  module Register
    Instruction = Struct.new(:ip, :opcode, :args, :source_line, :source_column, keyword_init: true) do
      def width
        1 + args.length
      end

      def next_ip
        ip + width
      end

      # Used by the optimizer's rewrite paths so we can carry source
      # position info through fused-compare-branch / jump-threading /
      # move-removal transforms without forgetting to set it on each
      # new Instruction.
      def with(**overrides)
        self.class.new(
          ip: overrides.fetch(:ip, ip),
          opcode: overrides.fetch(:opcode, opcode),
          args: overrides.fetch(:args, args),
          source_line: overrides.fetch(:source_line, source_line),
          source_column: overrides.fetch(:source_column, source_column)
        )
      end
    end

    class OpcodeLayout
      SPEC = OpcodeSpec
      ICALL = SPEC::BY_NAME.fetch(:ICALL).code
      FCALL = SPEC::BY_NAME.fetch(:FCALL).code
      NCALL = SPEC::BY_NAME.fetch(:NCALL).code
      IRET = SPEC::BY_NAME.fetch(:IRET).code
      HALT = SPEC::BY_NAME.fetch(:HALT).code
      JMP = SPEC::BY_NAME.fetch(:JMP).code
      JF = SPEC::BY_NAME.fetch(:JF).code
      FRET = SPEC::BY_NAME.fetch(:FRET).code
      SRET = SPEC::BY_NAME.fetch(:SRET).code
      FUSED_BRANCHES = %i[
        JILTF JIGTF JIEQF JINEQF JILTEF JIGTEF
        JFLTF JFGTF JFEQF JFNEQF JFLTEF JFGTEF
      ].map { |name| SPEC::BY_NAME.fetch(name).code }.freeze

      FIXED_ARITIES = SPEC::FIXED_ARITIES

      TERMINATORS = [IRET, FRET, SRET, HALT].freeze

      def arity_at(ops, ip)
        opcode = ops.fetch(ip)
        if call_opcode?(opcode)
          5 + (ops.fetch(ip + 3).to_i * 2)
        elsif opcode == NCALL
          4 + (ops.fetch(ip + 4).to_i * 2)
        else
          FIXED_ARITIES.fetch(opcode) do
            raise ArgumentError, "unknown register opcode #{opcode} at ip #{ip}"
          end
        end
      end

      def call_opcode?(opcode)
        opcode == ICALL || opcode == FCALL
      end

      def successors(instruction)
        if TERMINATORS.include?(instruction.opcode)
          []
        elsif (target_indexes = SPEC.branch_target_indexes(instruction.opcode)).empty?
          [instruction.next_ip]
        elsif instruction.opcode == JMP
          [instruction.args.fetch(target_indexes.fetch(0))]
        else
          [instruction.args.fetch(target_indexes.fetch(0)), instruction.next_ip]
        end
      end
    end

    class Program
      attr_reader :instructions, :layout

      # Decodes a flat ops array into Instructions. Optional
      # `source_lines` / `source_columns` parallel to ops attach per-
      # opcode CLEAR source positions (read at the opcode position;
      # operand-position entries are ignored).
      def self.decode(ops, layout: OpcodeLayout.new, source_lines: nil, source_columns: nil)
        instructions = []
        ip = 0
        while ip < ops.length
          opcode = ops.fetch(ip)
          arity = layout.arity_at(ops, ip)
          args = ops[(ip + 1)..(ip + arity)] || []
          line = source_lines && source_lines[ip]
          col = source_columns && source_columns[ip]
          instructions << Instruction.new(ip: ip, opcode: opcode, args: args, source_line: line, source_column: col)
          ip += 1 + arity
        end
        new(instructions, layout: layout)
      end

      def initialize(instructions, layout: OpcodeLayout.new)
        @instructions = instructions
        @layout = layout
      end

      def to_ops
        instructions.flat_map { |insn| [insn.opcode, *insn.args] }
      end

      # Returns an Int array parallel to `to_ops`, where entries at
      # opcode-start positions hold the source line and operand positions
      # hold 0 (the runner only consults opcode-start entries on error).
      def to_source_lines
        instructions.flat_map do |insn|
          line = insn.source_line.to_i
          [line, *Array.new(insn.args.length, 0)]
        end
      end

      # Sibling of `to_source_lines` for column metadata. Column 0
      # at operand positions is meaningless — runtime treats column 0
      # as "unknown" (same as line 0).
      def to_source_columns
        instructions.flat_map do |insn|
          col = insn.source_column.to_i
          [col, *Array.new(insn.args.length, 0)]
        end
      end

      def direct_thread_labels
        instructions.to_h { |insn| [insn.ip, "op_#{insn.ip}"] }
      end

      def successor_ips(instruction)
        valid_ips = direct_thread_labels.keys
        layout.successors(instruction).select { |ip| valid_ips.include?(ip) }
      end

      def instruction_by_ip
        @instruction_by_ip ||= instructions.to_h { |insn| [insn.ip, insn] }
      end
    end

    class Optimizer
      INT_COMPARE_TO_FUSED_FALSE = {
        8 => OpcodeLayout::SPEC::BY_NAME.fetch(:JILTF).code,
        9 => OpcodeLayout::SPEC::BY_NAME.fetch(:JIGTF).code,
        10 => OpcodeLayout::SPEC::BY_NAME.fetch(:JIEQF).code,
        11 => OpcodeLayout::SPEC::BY_NAME.fetch(:JINEQF).code,
        12 => OpcodeLayout::SPEC::BY_NAME.fetch(:JILTEF).code,
        13 => OpcodeLayout::SPEC::BY_NAME.fetch(:JIGTEF).code,
      }.freeze
      FLOAT_COMPARE_TO_FUSED_FALSE = {
        23 => OpcodeLayout::SPEC::BY_NAME.fetch(:JFLTF).code,
        24 => OpcodeLayout::SPEC::BY_NAME.fetch(:JFGTF).code,
        25 => OpcodeLayout::SPEC::BY_NAME.fetch(:JFEQF).code,
        26 => OpcodeLayout::SPEC::BY_NAME.fetch(:JFNEQF).code,
        27 => OpcodeLayout::SPEC::BY_NAME.fetch(:JFLTEF).code,
        28 => OpcodeLayout::SPEC::BY_NAME.fetch(:JFGTEF).code,
      }.freeze

      def optimize(program)
        program = fuse_compare_branches(program)
        program = thread_branch_targets(program)
        remove_removable(program)
      end

      private

      def fuse_compare_branches(program)
        live_out = liveness(program)
        rewritten = []
        skip_next = false

        program.instructions.each_cons(2) do |insn, next_insn|
          if skip_next
            skip_next = false
            next
          end

          fused = fused_compare_branch(insn, next_insn, live_out)
          if fused
            rewritten << fused
            skip_next = true
          else
            rewritten << insn
          end
        end

        rewritten << program.instructions.last if program.instructions.any? && !skip_next
        Program.new(rewritten, layout: program.layout)
      end

      def liveness(program)
        uses = {}
        defs = {}
        program.instructions.each do |insn|
          uses[insn.ip] = register_uses(insn).to_set
          defs[insn.ip] = register_defs(insn).to_set
        end

        live_in = Hash.new { |h, k| h[k] = Set.new }
        live_out = Hash.new { |h, k| h[k] = Set.new }
        changed = true
        while changed
          changed = false
          program.instructions.reverse_each do |insn|
            succ_out = program.successor_ips(insn).each_with_object(Set.new) do |ip, set|
              set.merge(live_in[ip])
            end
            new_in = uses.fetch(insn.ip) | (succ_out - defs.fetch(insn.ip))
            if new_in != live_in[insn.ip] || succ_out != live_out[insn.ip]
              live_in[insn.ip] = new_in
              live_out[insn.ip] = succ_out
              changed = true
            end
          end
        end
        live_out
      end

      def fused_compare_branch(insn, next_insn, live_out)
        return nil unless next_insn.opcode == OpcodeLayout::JF

        int_fused = INT_COMPARE_TO_FUSED_FALSE[insn.opcode]
        if int_fused && next_insn.args[0] == insn.args[0] && !live_out[next_insn.ip].include?([:i, insn.args[0]])
          return Instruction.new(ip: insn.ip, opcode: int_fused,
                                 args: [insn.args[1], insn.args[2], next_insn.args[1]],
                                 source_line: insn.source_line, source_column: insn.source_column)
        end

        float_fused = FLOAT_COMPARE_TO_FUSED_FALSE[insn.opcode]
        if float_fused && next_insn.args[0] == insn.args[0] && !live_out[next_insn.ip].include?([:i, insn.args[0]])
          return Instruction.new(ip: insn.ip, opcode: float_fused,
                                 args: [insn.args[1], insn.args[2], next_insn.args[1]],
                                 source_line: insn.source_line, source_column: insn.source_column)
        end

        nil
      end

      def register_uses(insn)
        OpcodeSpec.register_uses(insn.opcode, insn.args)
      end

      def register_defs(insn)
        OpcodeSpec.register_defs(insn.opcode, insn.args)
      end

      def thread_branch_targets(program)
        jumps = program.instructions.select { |insn| insn.opcode == OpcodeLayout::JMP }
          .to_h { |insn| [insn.ip, insn.args.fetch(0)] }

        return program if jumps.empty?

        rewritten = program.instructions.map do |insn|
          args = insn.args.dup
          case insn.opcode
          when OpcodeLayout::JMP
            args[0] = final_jump_target(args.fetch(0), jumps)
          else
            OpcodeSpec.branch_target_indexes(insn.opcode).each do |idx|
              args[idx] = final_jump_target(args.fetch(idx), jumps)
            end
          end
          Instruction.new(ip: insn.ip, opcode: insn.opcode, args: args, source_line: insn.source_line, source_column: insn.source_column)
        end
        Program.new(rewritten, layout: program.layout)
      end

      def final_jump_target(ip, jumps)
        seen = Set.new
        target = ip
        while jumps.key?(target) && !seen.include?(target)
          seen << target
          target = jumps.fetch(target)
        end
        target
      end

      def remove_removable(program)
        kept = program.instructions.reject { |insn| removable?(insn) }
        old_to_new = {}
        new_ip = 0
        kept_by_ip = kept.to_h { |insn| [insn.ip, insn] }
        program.instructions.each do |insn|
          old_to_new[insn.ip] = new_ip
          new_ip += insn.width if kept_by_ip.key?(insn.ip)
        end

        rewritten = []
        new_ip = 0
        kept.each do |insn|
          args = rewrite_targets(insn, old_to_new)
          rewritten << Instruction.new(ip: new_ip, opcode: insn.opcode, args: args, source_line: insn.source_line, source_column: insn.source_column)
          new_ip += insn.width
        end
        Program.new(rewritten, layout: program.layout)
      end

      def removable?(insn)
        case insn.opcode
        when 3, 18, 40 # IMOV/FMOV/SMOV
          insn.args[0] == insn.args[1]
        when OpcodeLayout::JMP
          insn.args[0] == insn.next_ip
        else
          false
        end
      end

      def rewrite_targets(insn, old_to_new)
        args = insn.args.dup
        OpcodeSpec.code_target_indexes(insn.opcode).each do |idx|
          args[idx] = old_to_new.fetch(args[idx])
        end
        args
      end
    end

    class AllocatorRewriter
      IOPS_3 = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 29].freeze
      FOPS_3 = [19, 20, 21, 22].freeze
      FCMP_3 = [23, 24, 25, 26, 27, 28].freeze
      IJUMP_CMP = [66, 67, 68, 69, 70, 71].freeze
      FJUMP_CMP = [72, 73, 74, 75, 76, 77].freeze

      attr_reader :segment_mappings

      def rewrite(program)
        rewritten = {}
        entries = segment_entries(program)
        param_counts = call_param_counts(program)
        # Per-segment virtual->physical maps, keyed by entry_ip. Used by
        # the debug names-table builder to convert the emitter's
        # virtual->name maps into physical->name. A no-op for normal
        # (non-debug) runs that ignore `segment_mappings`.
        @segment_mappings = {}

        entries.each do |entry_ip|
          segment = reachable_segment(program, entry_ip)
          next if segment.empty?

          mapping = allocate_segment(program, segment, param_counts.fetch(entry_ip, {}))
          enforce_register_caps!(mapping, entry_ip)
          @segment_mappings[entry_ip] = mapping
          segment.each do |insn|
            rewritten[insn.ip] = Instruction.new(
              ip: insn.ip,
              opcode: insn.opcode,
              args: rewrite_args(insn, mapping),
              source_line: insn.source_line,
              source_column: insn.source_column
            )
          end
        end

        Program.new(program.instructions.map { |insn| rewritten.fetch(insn.ip, insn) }, layout: program.layout)
      end

      private

      # Verifies that the segment-local mapping doesn't exceed the
      # configured per-kind register cap. The mapping stores physical
      # register indexes 0..N; cap means "no index >= N allowed."
      def enforce_register_caps!(mapping, entry_ip)
        RegisterFileLimits::ALL.each do |kind, cap|
          assigned = mapping.fetch(kind, {}).values
          next if assigned.empty?
          max_index = assigned.max
          next if max_index < cap
          raise RegisterFileLimits::OverRegisterCap,
                "register VM segment entry_ip=#{entry_ip} needs #{kind} register #{max_index}, " \
                "but RegisterFileLimits::#{kind.upcase} = #{cap}. " \
                "Tune the cap or reduce register pressure."
        end
      end

      def segment_entries(program)
        ([0] + program.instructions.filter_map do |insn|
          next unless [OpcodeLayout::ICALL, OpcodeLayout::FCALL].include?(insn.opcode)

          insn.args[1]
        end).uniq
      end

      def call_param_counts(program)
        counts = Hash.new { |h, k| h[k] = { i: 0, f: 0 } }
        program.instructions.each do |insn|
          next unless [OpcodeLayout::ICALL, OpcodeLayout::FCALL].include?(insn.opcode)

          target = insn.args[1]
          typed_args = insn.args[5..] || []
          i_count = 0
          f_count = 0
          typed_args.each_slice(2) do |kind, _reg|
            if kind == 1
              f_count += 1
            else
              i_count += 1
            end
          end
          counts[target][:i] = [counts[target][:i], i_count].max
          counts[target][:f] = [counts[target][:f], f_count].max
        end
        counts
      end

      def reachable_segment(program, entry_ip)
        by_ip = program.instruction_by_ip
        seen = {}
        stack = [entry_ip]
        until stack.empty?
          ip = stack.pop
          next if seen[ip]

          insn = by_ip[ip]
          next unless insn

          seen[ip] = true
          program.successor_ips(insn).each { |succ| stack << succ }
        end
        program.instructions.select { |insn| seen[insn.ip] }
      end

      def allocate_segment(program, segment, param_count)
        by_ip = segment.to_h { |insn| [insn.ip, insn] }
        uses = {}
        defs = {}
        segment.each do |insn|
          refs = register_refs(insn)
          uses[insn.ip] = refs.fetch(:uses)
          defs[insn.ip] = refs.fetch(:defs)
        end

        live_in = Hash.new { |h, k| h[k] = Set.new }
        live_out = Hash.new { |h, k| h[k] = Set.new }
        changed = true
        while changed
          changed = false
          segment.reverse_each do |insn|
            old_in = live_in[insn.ip]
            old_out = live_out[insn.ip]
            succ_out = program.successor_ips(insn).select { |ip| by_ip.key?(ip) }.each_with_object(Set.new) do |ip, set|
              set.merge(live_in[ip])
            end
            new_in = uses[insn.ip] | (succ_out - defs[insn.ip])
            if new_in != old_in || succ_out != old_out
              live_in[insn.ip] = new_in
              live_out[insn.ip] = succ_out
              changed = true
            end
          end
        end

        nodes = Set.new
        edges = Hash.new { |h, k| h[k] = Set.new }
        segment.each do |insn|
          nodes.merge(uses[insn.ip])
          nodes.merge(defs[insn.ip])
          defs[insn.ip].each do |defined|
            live_out[insn.ip].each do |live|
              next if live == defined || live.first != defined.first

              edges[defined] << live
              edges[live] << defined
            end
          end
        end

        {
          i: color_kind(:i, nodes, edges, param_count.fetch(:i, 0)),
          f: color_kind(:f, nodes, edges, param_count.fetch(:f, 0)),
          s: color_kind(:s, nodes, edges, 0),
        }
      end

      def color_kind(kind, nodes, edges, precolored_count)
        kind_nodes = nodes.select { |node| node.first == kind }
        mapping = {}
        precolored_count.times { |reg| mapping[[kind, reg]] = reg }

        kind_nodes.sort_by { |node| [mapping.key?(node) ? 0 : 1, -edges[node].length, node.last] }.each do |node|
          next if mapping.key?(node)

          used = edges[node].filter_map { |neighbor| mapping[neighbor] if neighbor.first == kind }.to_set
          color = 0
          color += 1 while used.include?(color)
          mapping[node] = color
        end
        mapping
      end

      def register_refs(insn)
        {
          uses: OpcodeSpec.register_uses(insn.opcode, insn.args).to_set,
          defs: OpcodeSpec.register_defs(insn.opcode, insn.args).to_set,
        }
      end

      def rewrite_args(insn, mapping)
        a = insn.args.dup
        OpcodeSpec.rewrite_registers!(insn.opcode, a, mapping)
        a
      end

      def rewrite_reg!(args, idx, kind, mapping)
        args[idx] = mapping.fetch(kind).fetch([kind, args[idx]], args[idx])
      end

      def rewrite_ncall_dst!(args, mapping)
        case args[0]
        when 1 then rewrite_reg!(args, 1, :i, mapping)
        when 2 then rewrite_reg!(args, 1, :f, mapping)
        when 3 then rewrite_reg!(args, 1, :s, mapping)
        end
      end

      def rewrite_typed_args!(args, start, mapping)
        idx = start
        while idx < args.length
          kind = case args[idx]
                 when 1 then :f
                 when 2 then :s
                 else :i
                 end
          rewrite_reg!(args, idx + 1, kind, mapping)
          idx += 2
        end
      end
    end

    PipelineResult = Struct.new(:ops, :source_lines, :source_columns, :segment_mappings, keyword_init: true)

    class Pipeline
      def initialize(optimizer: Optimizer.new, allocator: AllocatorRewriter.new)
        @optimizer = optimizer
        @allocator = allocator
      end

      # Returns flat ops. Existing callers (specs, harness) use this shape.
      def run(ops)
        program = Program.decode(ops)
        program = @allocator.rewrite(program)
        program = @optimizer.optimize(program)
        program.to_ops
      end

      # Like `run`, but threads parallel source-line metadata through.
      # Returns a PipelineResult holding both transformed ops and the
      # parallel source_lines array (same length as ops; opcode-position
      # entries hold CLEAR source lines, operand positions hold 0).
      def run_with_lines(ops, source_lines, source_columns = nil)
        program = Program.decode(ops, source_lines: source_lines, source_columns: source_columns)
        program = @allocator.rewrite(program)
        # `segment_mappings` is the virtual->physical map per call entry.
        # Captured here (post-allocator, pre-optimizer) so debug callers
        # can join with the emitter's virtual->name map to produce a
        # physical->name table for crash messages.
        mappings = @allocator.segment_mappings
        program = @optimizer.optimize(program)
        PipelineResult.new(
          ops: program.to_ops,
          source_lines: program.to_source_lines,
          source_columns: program.to_source_columns,
          segment_mappings: mappings
        )
      end
    end
  end
end
