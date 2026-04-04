require_relative "ast"

# Pipeline Rewriter — placeholder for future AST-level pipeline optimization.
#
# Pipeline `s>` carries error-unwrapping semantics: `x s> f` where f returns
# `!T` auto-unwraps to `T` and propagates the error. This semantic is handled
# by the annotator when it visits BinaryOp(:SMOOTH). Rewriting `s>` to a bare
# FuncCall before annotation loses this behavior.
#
# Current status: the rewriter is a no-op. All pipeline handling stays in:
# - Annotator: type-checks pipeline, handles error unwrapping
# - pipeline_generator.rb: emits Zig loops for WHERE/SELECT/etc.
# - transpiler.rb transpile_Smooth: dispatches to pipeline_generator
#
# Future: when pipeline fusion is implemented, it will operate on the
# annotated AST (after type info is available) as a separate optimization pass.

class PipelineRewriter
  def rewrite!(ast)
    # No-op: pipeline semantics require annotation context.
  end
end
