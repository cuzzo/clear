# frozen_string_literal: true

# Stage 2b measurement: let the WHOLE closure lower even when some functions
# cannot.
#
# MIR lowering raises on the first function it cannot lower, so a linked run
# reports one site and no denominator -- the same shape `probe_multi_error`
# already fixed for annotation, one pass later in the pipeline. This patch,
# loaded only by a harness, catches the raise at the FUNCTION boundary, records
# it, and drops that function from the emitted items so the rest of the program
# still lowers.
#
# A dropped function is a hole: the Zig will not link until it carries a body.
# That is stage 2c's problem, not 2b's -- 2b asks "how much of the closure
# lowers", and this turns one raise into a work list with a denominator.
module ProbeLoweringSurvives
  RECORDED = []

  def lower_function_def(node)
    # An imported package is lowered once for itself (compile_module_mir) and
    # again by every unit that imports it (imported_module_items). If failures
    # only ever happen from the second pass on, the AST is not surviving the
    # first -- which is a different bug from "was never annotated".
    pass_no = (node.instance_variable_get(:@probe_lower_pass) || 0) + 1
    node.instance_variable_set(:@probe_lower_pass, pass_no)
    super
  rescue StandardError => e
    raise if e.is_a?(SystemExit) || e.is_a?(SignalException)

    tok = node.respond_to?(:token) ? node.token : nil
    RECORDED << {
      'fn' => node.respond_to?(:name) ? node.name.to_s : '?',
      'unit' => $CLEAR_PROBE_UNIT.to_s,
      'file' => tok && tok[:file],
      'line' => tok && tok[:line],
      'message' => e.message.to_s.gsub(/\e\[[0-9;]*m/, '').lines.first.to_s.strip[0, 300],
      'class' => e.class.name.to_s,
      'pass' => pass_no,
    }
    raise if RECORDED.length > Integer(ENV.fetch('CLEAR_LOWER_ERROR_CAP', '5000'))

    # Second pass with the body replaced by a panic. Everything that already
    # worked -- the signature, the param list, the return type -- is lowered
    # again from the same node, so the emitted Zig still declares and links
    # this function. Only its body is gone.
    #
    # Without this the closure has holes and `zig build-exe` cannot run at all,
    # which is the whole of stage 2c. Dropping the function is the fallback for
    # when even the signature cannot be lowered.
    begin
      @probe_stub_body = true
      super
    rescue StandardError => e2
      RECORDED.last['stub_failed'] = e2.message.to_s.gsub(/\e\[[0-9;]*m/, '').lines.first.to_s.strip[0, 200]
      nil
    ensure
      @probe_stub_body = false
    end
  end

  def lower_body(body)
    return [MIR::Panic.new('unlowered')] if @probe_stub_body

    super
  end
end

# Prepend to the CLASS, not to the module that happens to define
# lower_function_def: `lower_body` is defined on the class itself, so a module
# prepended to an INCLUDED module sits below it in the ancestry and its
# override never runs. That is what made every stub attempt fail again.
TracePoint.new(:end) do |tp|
  klass = tp.self
  next unless klass.is_a?(Class)
  own = klass.instance_methods(false) + klass.private_instance_methods(false)
  # Identify the lowering by what it defines, not by its name.
  next unless own.include?(:lower_body) && own.include?(:lower_module)
  klass.prepend(ProbeLoweringSurvives)
  tp.disable
end.enable
