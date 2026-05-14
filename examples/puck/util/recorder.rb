require_relative 'trace_event'

module Puck
  # Collects events from the instrumented compilation pipeline.
  #
  # Tokens are recorded eagerly (after the real Tokenizer completes) because
  # the tokenizer has no useful internal hook points: positions are recovered
  # by re-scanning the source. Parse and compile events arrive in real time
  # from the Instrumenter's TracePoints / prepend hooks while the real
  # Parser / Compiler run.
  class Recorder
    attr_reader :events

    def initialize
      @events = []
      @stage = nil
      @parse_stack = []         # [[method_id, entry_token_index], ...]
      @current_pos = 0
      @bytecode_emit_id_by_oid = {}
      @next_emit_id = 0
    end

    # --- tokenize stage ---------------------------------------------------

    def record_tokens(source, tokens)
      @stage = :tokenize
      @events << TraceEvent.tokenize_start
      positions = compute_token_positions(source, tokens)
      tokens.each_with_index do |tok, idx|
        pos = positions[idx]
        @events << {
          stage: :tokenize,
          kind: :token_emitted,
          index: idx,
          token: tok,
          source_pos: pos[:source_pos],
          line: pos[:line],
          col_start: pos[:col_start],
          col_end: pos[:col_end]
        }
      end
      @events << TraceEvent.tokenize_end
    end

    # --- parse stage ------------------------------------------------------

    def start_parse_stage
      @stage = :parse
      @parse_stack.clear
      @events << TraceEvent.parse_start
    end

    def end_parse_stage
      @events << TraceEvent.parse_end
    end

    def record_parse_enter(method, token_index)
      @parse_stack.push([method, token_index])
      @current_pos = token_index
      @events << { stage: :parse, kind: :parse_enter, method: method, token_index: token_index }
    end

    def record_parse_exit(method, token_index)
      @parse_stack.pop
      @current_pos = token_index
      @events << { stage: :parse, kind: :parse_exit, method: method, token_index: token_index }
    end

    def record_consume(token_index, token)
      @current_pos = token_index + 1
      @events << { stage: :parse, kind: :consume, token_index: token_index, token: token }
    end

    def record_node_built(node)
      return unless @stage == :parse
      return if @parse_stack.empty?  # nodes built outside a parse_* frame are ignored
      span_start = @parse_stack.last[1]
      span_end = [@current_pos - 1, span_start].max
      @events << {
        stage: :parse,
        kind: :node_built,
        node: node,
        spans_tokens: (span_start..span_end)
      }
    end

    # --- compile stage ----------------------------------------------------

    def start_compile_stage
      @stage = :compile
      @events << TraceEvent.compile_start
    end

    def end_compile_stage
      @events << TraceEvent.compile_end
    end

    def record_compile_enter(method, node)
      @events << { stage: :compile, kind: :compile_enter, method: method, ast_node: node }
    end

    def record_compile_exit(method, node)
      @events << { stage: :compile, kind: :compile_exit, method: method, ast_node: node }
    end

    def record_bytecode_new(bc, produced_by = nil)
      return unless @stage == :compile
      emit_id = (@next_emit_id += 1)
      @bytecode_emit_id_by_oid[bc.object_id] = emit_id
      @events << {
        stage: :compile,
        kind: :emit,
        emit_id: emit_id,
        op: bc.op,
        arg: bc.arg,
        produced_by: produced_by
      }
    end

    def record_bytecode_patch(bc, new_value)
      return unless @stage == :compile
      emit_id = @bytecode_emit_id_by_oid[bc.object_id]
      return unless emit_id  # constructed outside our recording window — ignore
      @events << {
        stage: :compile,
        kind: :patch,
        emit_id: emit_id,
        field: :arg,
        old: bc.arg,
        new: new_value
      }
    end

    # --- token position recovery ------------------------------------------

    private

    # Walk the source forward and find each token's byte position. Each
    # version's Tokenizer.value carries the original matched string (for
    # operators, keywords, symbols) or the integer value (for INTEGER), so
    # we coerce to_s and locate it greedily after the previous token's end.
    # This is robust for the Puck tokenizers because tokens never overlap and
    # whitespace is the only thing between them.
    def compute_token_positions(source, tokens)
      line_starts = compute_line_starts(source)
      positions = []
      pos = 0
      tokens.each do |tok|
        str = tok.value.to_s
        pos += 1 while pos < source.length && source[pos] =~ /\s/
        found = source.index(str, pos)
        if found.nil?
          positions << { source_pos: pos, line: 0, col_start: 0, col_end: 0 }
          next
        end
        line, col = pos_to_line_col(line_starts, found)
        positions << {
          source_pos: found,
          line: line,
          col_start: col,
          col_end: col + str.length
        }
        pos = found + str.length
      end
      positions
    end

    def compute_line_starts(source)
      starts = [0]
      source.each_char.with_index { |c, i| starts << (i + 1) if c == "\n" }
      starts
    end

    def pos_to_line_col(line_starts, pos)
      idx = line_starts.bsearch_index { |start| start > pos }
      line = idx ? idx - 1 : line_starts.length - 1
      [line, pos - line_starts[line]]
    end
  end
end
