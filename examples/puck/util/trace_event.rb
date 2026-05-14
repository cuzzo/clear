module Puck
  # Flat event stream produced by util/instrumenter.rb and consumed by
  # compile.rb. Events are immutable value records; the visualizer steps
  # forward/backward through them and re-derives display state by replaying
  # from the start.
  #
  # Stages run in order: :tokenize -> :parse -> :compile. The first event of
  # each stage is a {kind: :stage_start}; the last is {kind: :stage_end}.
  #
  # Event kinds (per stage):
  #
  # :tokenize
  #   :token_emitted  { token:, source_pos:, line:, col_start:, col_end: }
  #
  # :parse
  #   :parse_enter    { method:, token_index: }
  #   :parse_exit     { method:, token_index: }
  #   :consume        { token_index:, token: }
  #   :node_built     { node:, spans_tokens: Range }
  #
  # :compile
  #   :compile_enter  { method:, ast_node: }
  #   :compile_exit   { method:, ast_node: }
  #   :emit           { bytecode:, codes_index:, target: :main | <procedure_name>,
  #                     produced_by: <ast_node or nil> }
  #   :patch          { codes_index:, target:, field: :arg, old:, new: }
  #
  # Hash structure was deliberate: faster to add new fields than to grow a
  # Struct surface as the tutorial grows.
  module TraceEvent
    def self.tokenize_start; { stage: :tokenize, kind: :stage_start } end
    def self.tokenize_end;   { stage: :tokenize, kind: :stage_end } end
    def self.parse_start;    { stage: :parse, kind: :stage_start } end
    def self.parse_end;      { stage: :parse, kind: :stage_end } end
    def self.compile_start;  { stage: :compile, kind: :stage_start } end
    def self.compile_end;    { stage: :compile, kind: :stage_end } end
  end
end
