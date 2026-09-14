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
  UNITS = []
  # Function-level census. The statement-level catch below keeps a function
  # going after one of its statements fails, but everything downstream in that
  # function then runs against state the failed statement never produced, so it
  # stops yielding INDEPENDENT errors. A whole run therefore reports "1 error"
  # when it means "1 error visible from here" -- no denominator, and one fix per
  # round.
  #
  # analyze_program_bodies! iterates one body statement per FUNCTION, so
  # catching THERE isolates functions from each other: every function is
  # attempted, and the result is X failing of N total.
  FN_TOTAL = []
  FN_FAILED = []
  CURRENT = [nil]

  def analyze_program_bodies!(declarations, program)
    stmts = declarations.body_statements
    FN_TOTAL << stmts.length
    ProbeMultiError.journal("UNIT\t#{stmts.length}")
    stmts.each do |stmt|
      CURRENT[0] = ProbeMultiError.label_for(stmt)
      begin
        visit(stmt)
      rescue StandardError => e
        raise unless e.class.name.to_s.end_with?('CompilerError')

        FN_FAILED << [CURRENT[0], e]
      ensure
        CURRENT[0] = nil
      end
    end

    synthetic_function_definitions.each do |fn|
      CURRENT[0] = ProbeMultiError.label_for(fn)
      begin
        visit_FunctionDef(fn)
      rescue StandardError => e
        raise unless e.class.name.to_s.end_with?('CompilerError')

        FN_FAILED << [CURRENT[0], e]
      ensure
        CURRENT[0] = nil
      end
      program.statements << fn
    end
  end

  # Name the failing function so the census is a work list, not a pile of
  # line numbers in a merged package.
  # Write each failure as it happens. at_exit does not run if the process dies
  # hard (a segfault, an OOM kill, an outer timeout), and a census that only
  # exists at exit is a census you lose exactly when the run was expensive.
  def self.journal(line)
    path = ENV['CLEAR_PROBE_CENSUS_FILE']
    return unless path

    File.open(path, 'a') { |f| f.puts(line) }
  rescue StandardError
    nil
  end

  def self.label_for(stmt)
    %i[name fn_name].each do |m|
      next unless stmt.respond_to?(m)

      value = stmt.public_send(m)
      return value.to_s unless value.nil?
    end
    stmt.class.name.to_s.split('::').last
  end

  def visit_stmts(stmts)
    stmts.each_with_index do |stmt, index|
      begin
        visit(stmt)
      rescue StandardError => e
        raise unless e.class.name.to_s.end_with?('CompilerError')
        # A whole-closure run compiles many units; the token carries a line
        # but no file, so the unit being compiled is what makes it locatable.
        RECORDED << e
        UNITS << $CLEAR_PROBE_UNIT
        # Attribute to the enclosing function: the statement-level catch fires
        # first, so without this the function census never sees the failure.
        if CURRENT[0]
          FN_FAILED << [CURRENT[0], e]
          ProbeMultiError.journal("FAIL\t#{CURRENT[0]}\t#{e.message.to_s.gsub(/\e\[[0-9;]*m/, '').lines.map(&:strip).reject(&:empty?).first}")
        end
        # A whole-closure run has thousands of statements and wants the whole
        # list; a single-function probe wants to stop before cascade noise
        # buries the real one.
        raise if RECORDED.length > Integer(ENV.fetch('CLEAR_PROBE_ERROR_CAP', '40'))
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
  total = ProbeMultiError::FN_TOTAL.sum
  by_fn = {}
  ProbeMultiError::FN_FAILED.each { |name, e| (by_fn[name] ||= []) << e }
  if total.positive?
    warn("@@CENSUS functions=#{total} failed=#{by_fn.length} passing=#{total - by_fn.length} " \
         "rate=#{((total - by_fn.length) * 100.0 / total).round(2)}%")
    # One line per FAILING FUNCTION, showing its first error: the later ones in
    # the same function are usually cascades of it.
    by_fn.each do |name, errs|
      e = errs.first
      text = e.message.to_s.gsub(/\e\[[0-9;]*m/, '')
      first = text.lines.map(&:strip).reject(&:empty?).first.to_s
      tok = e.respond_to?(:token) ? e.token : nil
      where = tok ? " @@PL=#{tok.line}@@PC=#{tok.column}" : ''
      warn("@@FN #{name} (#{errs.length}) :: #{first.sub(/\A\[Compiler Error\]\s*/, '')}#{where}")
    end
  end
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
