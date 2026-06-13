require_relative '../src/ast/diagnostic_registry' unless defined?(DiagnosticRegistry)
require 'set'

# Permanent guard: every error!(...) call site must use a registry
# code (`:UNDEFINED_VAR`, etc.) so `clear explain CODE` works and the
# diagnostic catalog stays the single source of truth.
#
# A small set of structural patterns can't easily migrate without
# refactoring upstream callers, so they're documented as exceptions
# here. New raw-string error! sites are regressions: either migrate
# to a registry code, or — if the site is structurally a wrapper —
# add to EXCEPTIONS with a one-line justification.
#
# A future tranche will plug exceptions into `clear explain` so even
# wrapper-style sites can surface a code at runtime; the budget
# numbers below shrink as that work lands.
RSpec.describe "DiagnosticRegistry — call-site audit" do
  # File-level budgets. The structural patterns covered:
  #
  #   1. Callback wrapper — `err = ->(n, msg) { error!(n, msg) }`
  #      lambdas passed to validators (Capabilities, EffectInference,
  #      LockHelper). The validator builds the msg; the lambda is glue.
  #      Migrating requires the validator to know about codes, which
  #      is the wrong layering.
  #
  #   2. Helper that takes a message parameter — `emit_typo_suggestion!`,
  #      `emit_registry_mismatch!`, etc. The message comes from the
  #      caller's context. Migrating requires every caller to be
  #      converted, which would defeat the helper.
  #
  #   3. Stdlib-data string — `matched_def[:reject_error]` and
  #      `coerce!` returns a string from a data structure / method.
  #      Migrating requires those producers to switch to codes too.
  # Tranche 8 closed every exception by stamping an umbrella code on
  # each pass-through site. Tier 2 fixable! work added one site that
  # passes a Symbol `code` as a variable (emit_match_partial_fix! takes
  # `code:` so it can be reused for MATCH_NEEDS_ENUM_OR_UNION and
  # MATCH_NON_EXHAUSTIVE). v2 fix B added a second such site
  # (emit_reentrant_error! takes `code:` so it can be reused for both
  # REENTRANCE_DIRECT_RECURSIVE and REENTRANCE_INDIRECT_RECURSIVE).
  # The USE_OF_MOVED_* rewrite added a third (emit_use_of_moved_in_loop_error!
  # takes `code:` so it serves both USE_OF_MOVED_IN_LOOP and
  # USE_OF_MOVED_IN_LOOP_SHORT). Phase 2 of WITH-capability access added a
  # fourth (emit_cap_field_needs_with! takes `code:` so it serves both
  # CAP_FIELD_NEEDS_WITH_EXCLUSIVE and CAP_FIELD_NEEDS_WITH_SNAPSHOT).
  # Phase 3 (WITH-CAP-NEEDS-X family) added a fifth
  # (emit_with_cap_mismatch! takes `code:` so it serves all six
  # WITH-CAP-NEEDS-X codes that share the insert-sigil fallback shape).
  # Budget = 5 covers all five helpers; the static parser can't see
  # that `code` always holds a real registry symbol at runtime.
  EXCEPTIONS = {
    'src/annotator/helpers/fixable_helpers.rb' => 5,
  }.freeze

  def self.scan_raw_sites
    sites = Hash.new(0)
    Dir.glob(File.expand_path('../src/**/*.rb', __dir__)).each do |path|
      rel = path.sub(File.expand_path('..', __dir__) + '/', '')
      next if rel == 'src/ast/source_error.rb'  # `error!` definition lives here
      content = File.read(path)
      i = 0
      while (idx = content.index('error!(', i))
        # Skip identifiers that end in error! (method names, e.g. emit_foo_error!)
        prev = idx == 0 ? nil : content[idx - 1]
        if prev && prev.match?(/[A-Za-z0-9_]/)
          i = idx + 1
          next
        end

        # Skip comment lines — `#` to the left of error! on the same line
        line_start = content.rindex("\n", idx) || -1
        if content[line_start + 1...idx].include?('#')
          i = idx + 1
          next
        end

        # Walk to matching close paren, tracking strings + brackets
        j = idx + 'error!('.length
        depth = 1
        in_str = nil
        while j < content.length && depth > 0
          c = content[j]
          if in_str
            if c == '\\'
              j += 2
              next
            elsif c == in_str
              in_str = nil
            end
          elsif c == '"' || c == "'"
            in_str = c
          elsif c == '('
            depth += 1
          elsif c == ')'
            depth -= 1
          end
          j += 1
        end

        # Find the second arg (after the receiver comma)
        body = content[idx + 'error!('.length...j - 1]
        d = 0
        s = nil
        comma = nil
        body.each_char.with_index do |c, k|
          if s
            s = nil if c == s && body[k - 1] != '\\'
          elsif c == '"' || c == "'"
            s = c
          elsif '([{'.include?(c)
            d += 1
          elsif ')]}'.include?(c)
            d -= 1
          elsif c == ',' && d == 0
            comma = k
            break
          end
        end

        if comma
          second = body[(comma + 1)..].strip
          unless second.start_with?(':') && second[1..].match?(/\A[A-Z]/)
            sites[rel] += 1
          end
        end

        i = j
      end
    end
    sites
  end

  ACTUAL = scan_raw_sites.freeze

  it "no file has more raw-string error! sites than its exception budget" do
    over = []
    ACTUAL.each do |file, count|
      budget = EXCEPTIONS[file] || 0
      next if count <= budget
      over << "  #{file}: found #{count}, budget #{budget}"
    end
    expect(over).to be_empty,
      "Raw-string error! site budget exceeded:\n#{over.join("\n")}\n\n" \
      "Either migrate the new site to a registry code, or — if it's a " \
      "structural wrapper — bump the budget in #{__FILE__} with a comment " \
      "explaining the pattern."
  end

  it "no exception budget exceeds the actual site count (no stale entries)" do
    stale = []
    EXCEPTIONS.each do |file, budget|
      actual = ACTUAL[file] || 0
      next if actual >= budget
      stale << "  #{file}: budget #{budget}, found #{actual}"
    end
    expect(stale).to be_empty,
      "Exception budgets are higher than the actual site count. " \
      "Lower the budget in #{__FILE__}:\n#{stale.join("\n")}"
  end

  it "files outside the exception list have zero raw-string sites" do
    leaks = ACTUAL.reject { |file, _| EXCEPTIONS.key?(file) }
    expect(leaks).to be_empty,
      "Raw-string error! sites in unexpected files:\n" +
      leaks.map { |f, n| "  #{f}: #{n}" }.join("\n") + "\n\n" \
      "Migrate to a registry code, or add the file + budget to EXCEPTIONS " \
      "in #{__FILE__}."
  end

  it "does not pass ad-hoc messages into annotator or AST fixable diagnostics" do
    offenders = []
    Dir.glob(File.expand_path('../src/{annotator,ast}/**/*.rb', __dir__)).each do |path|
      rel = path.sub(File.expand_path('..', __dir__) + '/', '')
      next if rel == 'src/ast/source_error.rb'

      content = File.read(path)
      i = 0
      while (idx = content.index('fixable!(', i))
        line_start = content.rindex("\n", idx) || -1
        if content[line_start + 1...idx].include?('#')
          i = idx + 1
          next
        end

        j = idx + 'fixable!('.length
        depth = 1
        in_str = nil
        while j < content.length && depth > 0
          c = content[j]
          if in_str
            if c == '\\'
              j += 2
              next
            elsif c == in_str
              in_str = nil
            end
          elsif c == '"' || c == "'"
            in_str = c
          elsif c == '('
            depth += 1
          elsif c == ')'
            depth -= 1
          end
          j += 1
        end

        body = content[idx + 'fixable!('.length...j - 1]
        offenders << "#{rel}:#{content[0...idx].count("\n") + 1}" if body.match?(/\bmessage:/)
        i = j
      end
    end

    expect(offenders).to be_empty,
      "fixable! diagnostics should pass code: plus registry params:\n  #{offenders.join("\n  ")}"
  end

  it "does not embed ad-hoc prose in annotator or AST fix descriptions" do
    offenders = []
    Dir.glob(File.expand_path('../src/{annotator,ast}/**/*.rb', __dir__)).each do |path|
      rel = path.sub(File.expand_path('..', __dir__) + '/', '')

      content = File.read(path)
      i = 0
      while (idx = content.index('Fix.new(', i))
        line_start = content.rindex("\n", idx) || -1
        if content[line_start + 1...idx].include?('#')
          i = idx + 1
          next
        end

        j = idx + 'Fix.new('.length
        depth = 1
        in_str = nil
        while j < content.length && depth > 0
          c = content[j]
          if in_str
            if c == '\\'
              j += 2
              next
            elsif c == in_str
              in_str = nil
            end
          elsif c == '"' || c == "'"
            in_str = c
          elsif c == '('
            depth += 1
          elsif c == ')'
            depth -= 1
          end
          j += 1
        end

        body = content[idx + 'Fix.new('.length...j - 1]
        desc_idx = body.index('description:')
        if desc_idx.nil?
          offenders << "#{rel}:#{content[0...idx].count("\n") + 1} missing description:"
        else
          desc_expr = body[(desc_idx + 'description:'.length)..].strip
          unless desc_expr.start_with?('fix_description(') ||
                 desc_expr.start_with?('fix_description_from_hash(') ||
                 desc_expr.start_with?('DiagnosticRegistry.fix_description(')
            offenders << "#{rel}:#{content[0...idx].count("\n") + 1}"
          end
        end
        i = j
      end
    end

    expect(offenders).to be_empty,
      "Fix descriptions should use DiagnosticRegistry fix-description keys:\n  #{offenders.join("\n  ")}"
  end

  it "keeps fix_hint prose centralized in DiagnosticRegistry" do
    offenders = []
    Dir.glob(File.expand_path('../src/{annotator,ast}/**/*.rb', __dir__)).each do |path|
      rel = path.sub(File.expand_path('..', __dir__) + '/', '')
      next if rel == 'src/ast/diagnostic_registry.rb'

      File.readlines(path).each_with_index do |line, idx|
        next if line.lstrip.start_with?('#')
        offenders << "#{rel}:#{idx + 1}" if line.match?(/\bfix_hints?:\s*["']/)
      end
    end

    expect(offenders).to be_empty,
      "Diagnostic fix_hints should live in DiagnosticRegistry:\n  #{offenders.join("\n  ")}"
  end
end
