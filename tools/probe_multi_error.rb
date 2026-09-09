# frozen_string_literal: true

# See EVERY error in a probed function, not just the first.
#
# The annotator raises on the first `error!`, so one probe reports one error and
# a function with six of them needs six probe rounds. This patch -- loaded only
# by the probe, via RUBYOPT, never by a real build -- catches a compile error at
# the STATEMENT boundary, records it, and carries on with the next statement.
#
# The later errors are guidance, not verdicts: after a failure the session's
# state is whatever the failed statement left behind, so a downstream complaint
# can be an artifact. Every fix still has to be confirmed by the ordinary
# single-error probe.
#
# Nothing is required here: loading the compiler at RUBYOPT time would fix
# sorbet's checked level before the compiler chooses it. The patch waits for the
# class to finish defining itself instead.
module ProbeMultiError
  RECORDED = []

  def visit_stmts(stmts)
    stmts.each_with_index do |stmt, index|
      begin
        visit(stmt)
      rescue StandardError => e
        raise unless e.class.name.to_s.end_with?('CompilerError')
        RECORDED << e
        raise if RECORDED.length > 40
        next
      end
      refinements = guard_exit_refinements(stmt)
      next if refinements.empty?

      rest = stmts[(index + 1)..] || []
      next if rest.empty?

      with_value_type_refinements(refinements) { visit_stmts(rest) }
      return nil
    end
    nil
  end
end

TracePoint.new(:end) do |tp|
  mod = tp.self
  # Identify the session by what it defines, not by its name: asking an
  # arbitrary module for its name runs whatever that module wants it to.
  next unless mod.is_a?(Module)
  own = mod.instance_methods(false) + mod.private_instance_methods(false)
  next unless own.include?(:visit_stmts) && own.include?(:guard_exit_refinements)
  mod.prepend(ProbeMultiError)
  tp.disable
end.enable

at_exit do
  ProbeMultiError::RECORDED.each do |e|
    # The banner the probe scans for is added by the CLI at print time; a
    # recorded error never reaches it, so it carries its own -- and its own
    # position, since only the first error's banner is in the build output.
    text = e.message.to_s.gsub(/\e\[[0-9;]*m/, '')
    first = text.lines.map(&:strip).reject(&:empty?).first.to_s
    tok = e.respond_to?(:token) ? e.token : nil
    where = tok ? " @@PL=#{tok.line}@@PC=#{tok.column}" : ''
    warn("[Compiler Error] #{first.sub(/\A\[Compiler Error\]\s*/, '')}#{where}")
  end
end
