#!/usr/bin/env ruby

require 'io/console'
require 'set'
require 'stringio'

begin
  require 'tty-screen'
  require 'tty-cursor'
  require 'tty-reader'
rescue LoadError
  # Optional; same fallback as run.rb.
end

require_relative 'util/version_loader'
require_relative 'util/terminal'
require_relative 'util/source_view'
require_relative 'util/ast_view'
require_relative 'util/recorder'
require_relative 'util/instrumenter'

# ---------------------------------------------------------------------------
# Pipeline driver. Loads a version, runs the instrumented compilation
# pipeline once, hands back the recorded events.
# ---------------------------------------------------------------------------

class Pipeline
  def self.run(version, source_path = nil)
    source = Puck::VersionLoader.load_version(version, source_path)
    recorder = Puck::Recorder.new

    tokens = Tokenizer.new(source).tokenize
    recorder.record_tokens(source, tokens)

    Puck::Instrumenter.with_recorder(recorder) do
      recorder.start_parse_stage
      ast = Parser.new(tokens).parse
      ast = MacroExpander.new.expand(ast) if defined?(MacroExpander)
      recorder.end_parse_stage

      recorder.start_compile_stage
      Compiler.new.compile(ast)
      recorder.end_compile_stage
    end

    { version: version, source: source, events: recorder.events }
  end
end

# ---------------------------------------------------------------------------
# CompileTracer: an index into the events array, with step/back/jump.
# Mirrors TraceVM's interface in run.rb (step, back, halted?).
# ---------------------------------------------------------------------------

class CompileTracer
  attr_reader :events

  def initialize(events)
    @events = events
    @index = 0
    @stage_starts = {}
    @events.each_with_index do |e, i|
      @stage_starts[e[:stage]] ||= i if e[:kind] == :stage_start
    end
    @focus_per_event = compute_focus_per_event
  end

  def step
    @index += 1 if @index < @events.length - 1
  end

  def back
    @index -= 1 if @index > 0
  end

  def jump_to(stage)
    target = @stage_starts[stage]
    @index = target if target
  end

  def jump_home; @index = 0; end
  def jump_end;  @index = @events.length - 1; end

  def index; @index; end
  def length; @events.length; end
  def current_event; @events[@index]; end

  def halted?
    @index >= @events.length - 1
  end

  # Replay events [0..@index] to produce the visible state. Cheap because
  # events are O(few hundred).
  def state
    s = State.new
    (0..@index).each { |i| s.apply(@events[i]) }
    s
  end

  # Focus info for the rendered source view at event index i:
  # { line:, span: { line:, col_start:, col_end: } | nil }
  #
  # The `line` is sticky — when the current event has no inherent source
  # position (stage markers, popping the compile stack to empty, etc.) we
  # keep showing the most recent line we knew about. The `>` carot moves
  # with the line; the `^^^^` span is only present when the current event
  # has its own span.
  def focus_at(i)
    @focus_per_event[i] || { line: nil, span: nil }
  end

  private

  def compute_focus_per_event
    state = State.new
    last_line = nil
    @events.map do |event|
      state.apply(event)
      span = derive_span(state, event)
      if span
        last_line = span[:line]
        { line: last_line, span: span }
      else
        { line: last_line, span: nil }
      end
    end
  end

  def derive_span(state, event)
    case event[:stage]
      when :tokenize then tokenize_span(state, event)
      when :parse    then parse_span(state, event)
      when :compile  then compile_span(state, event)
    end
  end

  def tokenize_span(state, event)
    return nil unless event[:kind] == :token_emitted
    { line: event[:line], col_start: event[:col_start], col_end: event[:col_end] }
  end

  def parse_span(state, event)
    case event[:kind]
      when :consume
        token_span(state.tokens[event[:token_index]])
      when :node_built
        node_span(state, event[:spans_tokens])
      when :parse_enter, :parse_exit
        idx = state.parse_stack.last&.[](1)
        token_span(idx && state.tokens[idx])
      else
        nil
    end
  end

  def compile_span(state, event)
    node =
      case event[:kind]
        when :emit  then event[:produced_by] || stack_top_node(state)
        when :patch
          bc = state.bytecodes.find { |b| b[:emit_id] == event[:emit_id] }
          (bc && bc[:produced_by]) || stack_top_node(state)
        else stack_top_node(state)
      end
    range = node && state.node_spans[node.object_id]
    node_span(state, range)
  end

  def stack_top_node(state)
    top = state.compile_stack.last
    node = top && top[1]
    node if node.respond_to?(:type) && node.respond_to?(:members)
  end

  def token_span(tok)
    return nil unless tok
    { line: tok[:line], col_start: tok[:col_start], col_end: tok[:col_end] }
  end

  def node_span(state, range)
    return nil if range.nil? || state.tokens.empty?
    first = state.tokens[range.first]
    last = state.tokens[range.last] || first
    return nil unless first
    if first[:line] == last[:line]
      { line: first[:line], col_start: first[:col_start], col_end: last[:col_end] }
    else
      # multi-line: underline only the first line's portion
      { line: first[:line], col_start: first[:col_start], col_end: first[:col_end] }
    end
  end
end

# Display state derived by replaying events. Mutated by `apply`.
class State
  attr_reader :tokens, :nodes, :parse_stack, :bytecodes, :compile_stack,
              :current_consume_token_index, :current_node, :current_emit_id,
              :current_patch_emit_id, :stage, :node_spans,
              :scope_mems, :current_scope

  # Bytecode ops that emit forward-jump placeholders. When one of these has
  # arg == nil, render it as "???" in the bytecode pane and add it to the
  # "active patches" list.
  PLACEHOLDER_OPS = [:JUMP, :JUMP_IF_FALSE].freeze

  def initialize
    @stage = nil
    @tokens = []
    @nodes = []
    @node_spans = {}  # ast_node object_id => spans_tokens range
    @parse_stack = []
    @bytecodes = []
    @compile_stack = []
    @current_consume_token_index = nil
    @current_node = nil
    @current_emit_id = nil
    @current_patch_emit_id = nil

    # Variable-name -> slot-index per scope. "main" is the top-level scope;
    # other keys are procedure names. Populated as STORE / LOAD bytecodes
    # fire, plus an initial seed from each Procedure's parameter list (which
    # the compiler assigns to slots 0..N-1 implicitly).
    @scope_mems = { "main" => {} }
    @scope_map = nil  # ast_node.object_id -> enclosing scope name (lazy)
    @current_scope = "main"
  end

  def apply(event)
    case event[:kind]
      when :stage_start
        @stage = event[:stage]
      when :token_emitted
        @tokens << {
          token: event[:token],
          line: event[:line],
          col_start: event[:col_start],
          col_end: event[:col_end],
          source_pos: event[:source_pos]
        }
      when :parse_enter
        @parse_stack.push([event[:method], event[:token_index]])
      when :parse_exit
        @parse_stack.pop
      when :consume
        @current_consume_token_index = event[:token_index]
      when :node_built
        @nodes << { node: event[:node], spans_tokens: event[:spans_tokens] }
        @node_spans[event[:node].object_id] = event[:spans_tokens]
        @current_node = event[:node]
      when :compile_enter
        @compile_stack.push([event[:method], event[:ast_node]])
      when :compile_exit
        @compile_stack.pop
      when :emit
        @bytecodes << {
          emit_id: event[:emit_id],
          op: event[:op],
          arg: event[:arg],
          produced_by: event[:produced_by],
          patched: false
        }
        @current_emit_id = event[:emit_id]
        @current_patch_emit_id = nil
        update_scope_from_emit(event)
      when :patch
        bc = @bytecodes.find { |b| b[:emit_id] == event[:emit_id] }
        if bc
          bc[:arg] = event[:new]
          bc[:patched] = true
        end
        @current_patch_emit_id = event[:emit_id]
    end
  end

  # Bytecodes that are still "open" placeholders: emit op is a forward-jump
  # op and arg is still nil. These are exactly the patch sites the compiler
  # is going to fill in later.
  def open_placeholders
    @bytecodes.each_with_index.select do |bc, _|
      PLACEHOLDER_OPS.include?(bc[:op]) && bc[:arg].nil?
    end
  end

  private

  # Walk the AST built so far and assign each node to its enclosing scope
  # name (procedure var or "main"). Also seed each procedure's scope with
  # its parameter list, since the compiler binds params to slots 0..N-1
  # before any STORE/LOAD fires.
  def rebuild_scope_map!
    @scope_map = {}
    @nodes.each do |entry|
      visit_for_scope(entry[:node], "main")
    end
  end

  def visit_for_scope(node, current_scope)
    return if node.nil?
    if node.is_a?(Array)
      node.each { |x| visit_for_scope(x, current_scope) }
      return
    end
    return unless node.respond_to?(:type) && node.respond_to?(:members)

    @scope_map[node.object_id] = current_scope

    next_scope = current_scope
    if node.type == :Procedure
      proc_name = node.var
      next_scope = proc_name
      @scope_mems[proc_name] ||= {}
      params = node.val.is_a?(Hash) ? (node.val[:params] || [node.val[:param]].compact) : []
      params.each_with_index { |p, i| @scope_mems[proc_name][p] ||= i }
    end

    # Walk ALL children (statements AND inline expression nodes), so leaf
    # nodes like Variable / Integer get attributed to their enclosing scope.
    Puck::AstView.collect_children(node).each do |_, child|
      visit_for_scope(child, next_scope)
    end
  end

  def update_scope_from_emit(event)
    pb = event[:produced_by]
    rebuild_scope_map! if @scope_map.nil? || (pb && !@scope_map.key?(pb.object_id))
    scope = (pb && @scope_map[pb.object_id]) || @current_scope || "main"
    @current_scope = scope
    @scope_mems[scope] ||= {}

    # STORE / LOAD use a slot index in their arg, and the produced_by node
    # carries the variable name (Assignment#var for STORE; Variable#name for
    # LOAD). Record the mapping.
    case event[:op]
      when :STORE
        name = pb && pb.respond_to?(:var) && pb.var
        @scope_mems[scope][name] = event[:arg] if name
      when :LOAD
        name = pb && pb.respond_to?(:name) && pb.name
        @scope_mems[scope][name] = event[:arg] if name
    end
  end
end

# ---------------------------------------------------------------------------
# Renderer.
#
# There is ONE view, used at every stage. It always shows:
#
#   [ source: up to 10 lines, > on the current line, ^^^^ under the active
#     token (tokenize stage only) ]
#
#   TOKENS                 AST                          BYTECODE
#   list of tokens         tree of nodes built so far   list of bytecodes
#   > on focused token     > on focused node            > on focused bytecode
#
#   # --- CONTROLS --- #
#   keys
#   # ----------------- #
#
# The `>` cursors migrate based on the current event:
#   tokenize :token_emitted  -> TOKENS focuses the new token; source ^^^^.
#   parse    :consume        -> TOKENS focuses the consumed token.
#   parse    :node_built     -> AST focuses the new node.
#   parse    :parse_enter    -> AST shows in-progress frames; no AST focus yet.
#   compile  :compile_enter  -> AST focuses the node being compiled.
#   compile  :emit           -> BYTECODE focuses the new bytecode; AST focuses
#                                the node that produced it.
#   compile  :patch          -> BYTECODE focuses the patched bytecode.
# ---------------------------------------------------------------------------

class CompileRenderer
  MIN_WIDTH = Puck::Terminal::MIN_WIDTH
  SOURCE_HEIGHT = 10

  def initialize(program, tracer)
    @program = program
    @tracer = tracer
    @source_view = Puck::SourceView.new(program[:source])
    @interactive = STDOUT.tty?
  end

  def render
    height, width = Puck::Terminal.size
    width = [width - 2, MIN_WIDTH].max

    state = @tracer.state
    event = @tracer.current_event

    body = render_body(state, event, width, height)
    controls = Puck::Terminal.controls_block(controls_text, width)

    body_height = [height - Puck::Terminal::CONTROLS_HEIGHT, 1].max
    body = body.first(body_height)
    body += Array.new(body_height - body.length, "")
    rows = body + controls
    Puck::Terminal.clear_and_home(@interactive) +
      rows.map { |row| Puck::Terminal.truncate(row, width).ljust(width) }.join("\r\n")
  end

  private

  def controls_text
    pos = "#{@tracer.index + 1}/#{@tracer.length}"
    stage = @tracer.current_event[:stage]
    "[#{stage}] event #{pos}    space:step  backspace:back  t:tokens  p:parse  c:compile  g/G:home/end  q:quit"
  end

  def render_body(state, event, width, height)
    top = render_source_area(state, event, width)
    panes_height = [height - SOURCE_HEIGHT - Puck::Terminal::CONTROLS_HEIGHT - 2, 6].max
    panes = render_three_panes(state, event, width, panes_height)
    top + [""] + panes
  end

  # Top area: source on the left, SCOPE sidebar on the right (matching run.rb).
  # SCOPE shows the compiler's mem hash for the current scope — variable
  # names and the slot index they map to. Empty during tokenize/parse stages.
  def render_source_area(state, event, width)
    scope_width = [[width / 4, 30].min, 18].max
    source_width = width - scope_width - 3
    source = render_source(source_width)
    scope = render_scope_pane(state, event, scope_width)
    SOURCE_HEIGHT.times.map do |i|
      a = (source[i] || '').ljust(source_width)
      b = (scope[i] || '').ljust(scope_width)
      "#{a} | #{b}"
    end
  end

  def render_source(width)
    focus = @tracer.focus_at(@tracer.index)
    span = (@tracer.current_event[:stage] == :tokenize) ? focus[:span] : nil
    @source_view.render(
      width: width,
      height: SOURCE_HEIGHT,
      focus_line: focus[:line],
      span: span
    ).lines.map(&:chomp)
  end

  # SCOPE pane: variable-name -> slot mapping for the compiler's current
  # scope (main or a procedure). Mirrors run.rb's SCOPE pane shape:
  #
  #     SCOPE main             SCOPE fizzbuzz
  #     M00: result            M00: limit
  #   > M01: x                 M01: i
  #
  # The `>` cursor lands on the slot the current bytecode is reading from
  # (:LOAD) or writing to (:STORE). During tokenize/parse no slot is active.
  def render_scope_pane(state, event, width)
    rows = [Puck::Terminal.truncate("SCOPE #{state.current_scope}", width)]
    bindings = state.scope_mems[state.current_scope] || {}
    active_slot = current_memory_slot(event)
    if bindings.empty?
      rows << Puck::Terminal.truncate("  (no bindings)", width)
    else
      bindings.sort_by { |_, slot| slot }.each do |name, slot|
        marker = (slot == active_slot) ? "> " : "  "
        rows << Puck::Terminal.truncate("#{marker}M%02d: %s" % [slot, name], width)
      end
    end
    rows + Array.new([SOURCE_HEIGHT - rows.length, 0].max, "")
  end

  # When the current event is a STORE/LOAD emit, returns the slot index the
  # op touches. Other events return nil (no slot is active).
  def current_memory_slot(event)
    return nil unless event[:kind] == :emit
    return nil unless [:STORE, :LOAD].include?(event[:op])
    event[:arg]
  end

  def render_three_panes(state, event, width, height)
    # During compile mode, drop the TOKENS pane and give that space to AST.
    # The AST is what the reader cares about — it produces the bytecode.
    if event[:stage] == :compile
      bc_w = [width / 3, 36].max
      ast_w = width - bc_w - 3
      ast = render_ast_pane(state, event, ast_w, height)
      bc = render_bytecode_pane(state, event, bc_w, height)
      height.times.map do |i|
        "#{(ast[i] || '').ljust(ast_w)} | #{(bc[i] || '').ljust(bc_w)}"
      end
    else
      pane_w = (width - 6) / 3
      pane_w = [pane_w, 20].max
      leftover = width - (pane_w * 3) - 6
      tokens = render_tokens_pane(state, event, pane_w, height)
      ast = render_ast_pane(state, event, pane_w + leftover, height)
      bc = render_bytecode_pane(state, event, pane_w, height)
      height.times.map do |i|
        a = (tokens[i] || '').ljust(pane_w)
        b = (ast[i] || '').ljust(pane_w + leftover)
        c = (bc[i] || '').ljust(pane_w)
        "#{a} | #{b} | #{c}"
      end
    end
  end

  # --- TOKENS pane ------------------------------------------------------

  def render_tokens_pane(state, event, width, height)
    rows = [Puck::Terminal.truncate("TOKENS (#{state.tokens.length})", width)]
    return rows + Array.new(height - 1, "") if state.tokens.empty?

    focus_range = focused_token_range(state, event)  # Range or nil
    focus_anchor = focus_range&.first || state.tokens.length - 1

    visible = height - 1
    start = window_start(focus_anchor, state.tokens.length, visible)
    state.tokens[start, visible].to_a.each_with_index do |t, i|
      idx = start + i
      marker = (focus_range && focus_range.cover?(idx)) ? ">" : " "
      tok = t[:token]
      rows << Puck::Terminal.truncate("#{marker} %03d  %-10s %s" % [idx, tok.type, tok.value.inspect], width)
    end
    rows + Array.new([height - rows.length, 0].max, "")
  end

  # The token range to mark with `>`. For most events this is a single token;
  # during parse/compile of an AST node, it's the full range of tokens that
  # produced that node — so the reader sees, at a glance, which source tokens
  # build the current AST node or bytecode.
  def focused_token_range(state, event)
    case event[:kind]
      when :token_emitted then (event[:index]..event[:index])
      when :consume       then (event[:token_index]..event[:token_index])
      when :node_built    then event[:spans_tokens]
      when :emit
        node = event[:produced_by] || compile_stack_node(state)
        node && state.node_spans[node.object_id]
      when :patch
        bc = state.bytecodes.find { |b| b[:emit_id] == event[:emit_id] }
        node = (bc && bc[:produced_by]) || compile_stack_node(state)
        node && state.node_spans[node.object_id]
      when :compile_enter, :compile_exit
        node = compile_stack_node(state)
        node && state.node_spans[node.object_id]
      when :parse_enter, :parse_exit
        idx = state.parse_stack.last&.[](1)
        cur = state.current_consume_token_index
        return nil unless idx && cur && cur >= idx
        (idx..cur)
      else
        nil
    end
  end

  # --- AST pane ---------------------------------------------------------

  def render_ast_pane(state, event, width, height)
    rows = [Puck::Terminal.truncate("AST (#{state.nodes.length})", width)]
    visible = height - 1

    if state.nodes.empty? && state.parse_stack.empty? && state.compile_stack.empty?
      rows << "  (no AST yet)"
      return rows + Array.new(height - rows.length, "")
    end

    focus_node = focused_ast_node(state, event)
    forest = build_forest(state.nodes)
    # When the focused node is an inline expression (Integer, Variable, ...),
    # the renderer never gives it its own line. Walk up to the enclosing
    # statement so `>` always lands somewhere visible.
    focus_target = Puck::AstView.find_focus_target(forest, focus_node) || focus_node
    tree_lines = []
    forest.each do |entry|
      Puck::AstView.render_source_like(entry[:node], "", focus_target, tree_lines, width)
    end

    # Append in-progress parse frames (only during parse stage) so the reader
    # can see what's about to be built. Each frame shows the token range it
    # has consumed so far (entry..current); the current end is the parser's
    # @pos, shared across all frames on the stack.
    if event[:stage] == :parse && state.parse_stack.any?
      cur = state.current_consume_token_index
      tree_lines << "" unless tree_lines.empty?
      tree_lines << Puck::Terminal.truncate("in progress:", width)
      state.parse_stack.reverse.each_with_index do |(method, entry_idx), i|
        marker = i.zero? ? ">" : " "
        span = (cur && cur >= entry_idx) ? "tok #{entry_idx}..#{cur}" : "tok #{entry_idx}"
        tree_lines << Puck::Terminal.truncate("#{marker} #{method}  #{span}", width)
      end
    end

    # Scroll so the focused line is visible.
    focus_row = tree_lines.find_index { |l| l.start_with?("> ") } || 0
    start = window_start(focus_row, tree_lines.length, visible)
    rows.concat(tree_lines[start, visible].to_a)
    rows + Array.new([height - rows.length, 0].max, "")
  end

  def focused_ast_node(state, event)
    case event[:kind]
      when :node_built
        event[:node]
      when :emit
        # The bytecode that just got emitted has a produced_by AST node when
        # the instrumenter could attribute it (works even for v1 which has no
        # per-statement compile method, via the :line TracePoint). Fall back
        # to the innermost compile_X frame.
        event[:produced_by] || compile_stack_node(state) || last_emit_node(state)
      when :patch
        # Patches target a previously-emitted bytecode. Focus the AST node
        # that produced that bytecode so the reader sees the link back.
        bc = state.bytecodes.find { |b| b[:emit_id] == event[:emit_id] }
        (bc && bc[:produced_by]) || compile_stack_node(state) || last_emit_node(state)
      when :compile_enter
        compile_stack_node(state) || last_emit_node(state)
      when :compile_exit
        # The stack was just popped; there may be no AST node on top now.
        # Fall back to the most recently emitted bytecode's producer so the
        # AST view doesn't lose its `>` between compile frames.
        last_emit_node(state) || compile_stack_node(state)
      else
        # During parse consume events between node_builds, focus the most
        # recently built node so the reader can see what was just built.
        state.nodes.last && state.nodes.last[:node]
    end
  end

  def compile_stack_node(state)
    top = state.compile_stack.last
    node = top && top[1]
    node if node.respond_to?(:type) && node.respond_to?(:members)
  end

  def last_emit_node(state)
    bc = state.bytecodes.last
    bc && bc[:produced_by]
  end

  # Identify roots — nodes not referenced as a child by any later-built node.
  def build_forest(entries)
    children = Set.new
    entries.each do |entry|
      collect_child_object_ids(entry[:node]).each { |oid| children << oid }
    end
    entries.reject { |entry| children.include?(entry[:node].object_id) }
  end

  def collect_child_object_ids(node)
    out = []
    visit = lambda do |v|
      if v.respond_to?(:type) && v.respond_to?(:members)
        out << v.object_id
        Puck::AstView.collect_children(v).each { |_, c| visit.call(c) }
      elsif v.is_a?(Array)
        v.each { |x| visit.call(x) }
      elsif v.is_a?(Hash)
        v.each_value { |x| visit.call(x) }
      end
    end
    # Iterate children only, not the node itself.
    return [] unless node.respond_to?(:type) && node.respond_to?(:members)
    Puck::AstView.collect_children(node).each { |_, c| visit.call(c) }
    out
  end

  def render_forest(roots, focus_node, width)
    lines = []
    roots.each do |entry|
      render_tree(entry[:node], focus_node, "", width, lines)
    end
    lines
  end

  def render_tree(node, focus_node, indent, width, lines)
    is_focus = focus_node && node.equal?(focus_node)
    prefix = "#{is_focus ? '>' : ' '} #{indent}"
    lines << Puck::Terminal.truncate("#{prefix}#{Puck::AstView.summary(node, width - indent.length - 2)}", width)

    child_indent = indent + "  "
    Puck::AstView.collect_children(node).each do |label, child|
      if child.respond_to?(:type) && child.respond_to?(:members)
        # Render the field label on its own line, then the child tree below.
        lines << Puck::Terminal.truncate("  #{child_indent}#{label}:", width) if label && !label.empty?
        render_tree(child, focus_node, child_indent + "  ", width, lines)
      elsif child.is_a?(Array)
        lines << Puck::Terminal.truncate("  #{child_indent}#{label}: [#{child.length}]", width)
        child.each do |x|
          if x.respond_to?(:type) && x.respond_to?(:members)
            render_tree(x, focus_node, child_indent + "  ", width, lines)
          else
            lines << Puck::Terminal.truncate("  #{child_indent}  #{x.inspect}", width)
          end
        end
      else
        lines << Puck::Terminal.truncate("  #{child_indent}#{label}: #{format_scalar(child)}", width)
      end
    end
  end

  def format_scalar(v)
    case v
      when nil then "nil"
      when Symbol, Numeric, String, TrueClass, FalseClass then v.inspect
      else v.to_s
    end
  end

  # --- BYTECODE pane ----------------------------------------------------

  def render_bytecode_pane(state, event, width, height)
    rows = [Puck::Terminal.truncate("BYTECODE (#{state.bytecodes.length})", width)]
    visible = height - 1

    if state.bytecodes.empty?
      rows << "  (none emitted)"
      open = state.open_placeholders
      rows << "" if visible > 2
      rows << Puck::Terminal.truncate("active patches: 0", width) if visible > 3
      return rows + Array.new([height - rows.length, 0].max, "")
    end

    focus_idx = focused_bytecode_index(state, event)
    start = window_start(focus_idx || state.bytecodes.length - 1, state.bytecodes.length, visible - 2)
    state.bytecodes[start, visible - 2].to_a.each_with_index do |bc, i|
      idx = start + i
      marker = (idx == focus_idx) ? ">" : " "
      placeholder = State::PLACEHOLDER_OPS.include?(bc[:op]) && bc[:arg].nil?
      arg_text = placeholder ? "???" : format_bytecode_arg(bc[:arg])
      tail = (event[:kind] == :patch && idx == focus_idx) ? "  <-- patched" : ""
      rows << Puck::Terminal.truncate("#{marker} %03d %-13s %s%s" % [idx, bc[:op], arg_text, tail], width)
    end

    rows << ""
    rows << Puck::Terminal.truncate("active patches: #{state.open_placeholders.length}", width)
    rows + Array.new([height - rows.length, 0].max, "")
  end

  def focused_bytecode_index(state, event)
    case event[:kind]
      when :emit  then state.bytecodes.length - 1
      when :patch then state.bytecodes.index { |b| b[:emit_id] == event[:emit_id] }
      else
        state.bytecodes.length - 1 if state.bytecodes.any? && event[:stage] == :compile
    end
  end

  # ByteCode args can be Symbols, Integers, Hashes (procedure refs), nil.
  # Procedure refs are huge — collapse to a short label.
  def format_bytecode_arg(arg)
    case arg
      when nil then "nil"
      when Hash
        arg[:params] ? "<proc #{arg[:params].inspect}>" : "<hash>"
      else arg.inspect
    end
  end

  # --- shared helpers ---------------------------------------------------

  # Pick the top-of-window so `focus_idx` lands ~1/3 from the top, clipped so
  # the window doesn't scroll past either end of the list.
  def window_start(focus_idx, total, visible)
    return 0 if total <= visible
    raw = [focus_idx - visible / 3, 0].max
    max_start = [total - visible, 0].max
    [raw, max_start].min
  end
end

# ---------------------------------------------------------------------------
# Runner: same interactive shape as run.rb's Runner.
# ---------------------------------------------------------------------------

class CompileRunner
  def initialize(program)
    @program = program
    @tracer = CompileTracer.new(program[:events])
    @renderer = CompileRenderer.new(program, @tracer)
    @reader = defined?(TTY::Reader) && STDIN.tty? ? TTY::Reader.new(interrupt: :exit) : nil
  end

  def auto(steps)
    puts @renderer.render
    steps.times do
      break if @tracer.halted?
      @tracer.step
      puts "\n--- step ---\n"
      puts @renderer.render
    end
  end

  def interactive
    STDOUT.sync = true
    Puck::Terminal.setup_cursor
    if @reader
      interactive_loop
    elsif STDIN.tty?
      STDIN.raw { interactive_loop }
    else
      interactive_loop
    end
  ensure
    Puck::Terminal.restore_cursor
  end

  private

  def interactive_loop
    loop do
      print @renderer.render
      action = Puck::Terminal.read_action(@reader)
      case action
        when :step     then @tracer.step
        when :back     then @tracer.back
        when :tokenize then @tracer.jump_to(:tokenize)
        when :parse    then @tracer.jump_to(:parse)
        when :compile  then @tracer.jump_to(:compile)
        when :home     then @tracer.jump_home
        when :end      then @tracer.jump_end
        when :quit     then break
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------

version = ARGV.shift || "v3"
source_path = ARGV[0] unless ARGV[0]&.start_with?("--")
steps_arg = ARGV.find { |arg| arg.start_with?("--steps=") }
steps = steps_arg&.split("=", 2)&.last&.to_i

unless Puck::VersionLoader::VERSIONS.include?(version)
  abort "Usage: ruby examples/puck/compile.rb [v1|v2|v3|v4|v5|v6|v7|v8|v9] [source.puck] [--steps=N]"
end

program = Pipeline.run(version, source_path)
runner = CompileRunner.new(program)

if steps
  runner.auto(steps)
else
  runner.interactive
end
