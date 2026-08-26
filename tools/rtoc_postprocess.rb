#!/usr/bin/env ruby
# frozen_string_literal: true

# Post-process machine-translated CLEAR.
#
# ruby-to-clear produces the same defect classes over and over, because they
# come from constructs Ruby has and CLEAR does not: a Struct accessor that
# looks like a method call, `nil` rendering as "" inside interpolation, `||=`
# on a nilable, a mixin used as a type, `respond_to?`. Fixing them one at a
# time costs a full build per site -- roughly nine minutes each on the
# annotator -- and none of that effort carries to the next translated phase.
#
# This carries it. Every rule below was learned from a real failure in the
# annotator translation; running it against a freshly translated MIR (or any
# other phase) applies all of them at once, before the first build.
#
#   ruby tools/rtoc_postprocess.rb --check            # report, change nothing
#   ruby tools/rtoc_postprocess.rb --fix              # apply mechanical fixes
#   ruby tools/rtoc_postprocess.rb --fix --only field_calls,enum_is_a
#   ruby tools/rtoc_postprocess.rb --check --root path/to/generated
#
# Rules are either MECHANICAL (a safe rewrite -- `--fix` applies it) or
# ADVISORY (the shape is wrong but the right answer needs a human -- always
# reported, never rewritten). Every mechanical rule is idempotent: running
# --fix twice changes nothing the second time.
#
# Precision is the whole design. Three earlier one-off versions of these
# sweeps were WRONG in ways that cost more than the bug:
#
#   * keyed by field name instead of owning struct, the field-call rule
#     reported zero sites while the build was failing on one of them;
#   * keyed by name, the enum rule reports 114 sites of which 95 are correct
#     code, because BlockExpr and Raise are union variants AND enum variants;
#   * ignoring narrowing, the interpolation rule rewrote seven correct lines
#     into errors of its own.
#
# So: every rule types both ends before it fires, and stays silent about
# anything it cannot type.

require 'optparse'
require 'set'

module RtocPostprocess
  extend self

  # ---------------------------------------------------------------- index --

  # What the tree declares: struct fields and their types, union variants,
  # enum variants, function signatures. Everything is keyed by its OWNER,
  # because the same field name has different types on different structs.
  class TypeIndex
    attr_reader :struct_fields, :union_variants, :enum_variants, :structs, :param_types, :accessors, :return_types

    def initialize(sources)
      @struct_fields = Hash.new { |hash, key| hash[key] = {} }
      @element_of = {}
      @union_variants = Hash.new { |hash, key| hash[key] = Set.new }
      @variant_payloads = Hash.new { |hash, key| hash[key] = {} }
      @enum_variants = Hash.new { |hash, key| hash[key] = Set.new }
      @structs = Set.new
      @param_types = {}
      @return_types = {}
      @accessors = Set.new
      @declared_in = {}
      @private_callers = Hash.new { |hash, key| hash[key] = Set.new }
      # Relative names are what findings report, so the index speaks them too.
      root = sources.first ? sources.min_by(&:length).sub(%r{/[^/]+\z}, '') : ''
      root = root.sub(%r{/(annotator|ast|mir|backends|semantic|compiler|ffi)\z}, '')
      @relative_of = sources.to_h { |path| [path, path.delete_prefix("#{root}/")] }
      sources.each { |path| scan(path) }
      sources.each { |path| scan_calls(path) }
    end

    def element_of(struct, field) = @element_of[[struct, field]]

    def variant_payloads(union) = @variant_payloads[union]

    attr_reader :private_callers

    # FN name -> declaring file, for every non-PUB FN some OTHER file calls.
    def cross_file_privates
      @cross_file_privates ||= @declared_in.each_with_object({}) do |(name, (home, visibility)), out|
        next if visibility == 'PUB'
        next if (@private_callers[name] - [home]).empty?

        out[name] = home
      end
    end

    def field_type(struct, field) = @struct_fields[struct][field]

    # `SwitchArm` is reached as `switchArm__body`.
    def accessor_name(struct, field)
      "#{struct[0].downcase}#{struct[1..]}__#{field}"
    end

    # Names that are ONLY ever enum variants -- never a struct, never a union
    # variant. Anything else is ambiguous and this tool will not touch it.
    def unambiguous_enum_variants
      return @unambiguous if @unambiguous

      union_names = @union_variants.values.reduce(Set.new, :|)
      @unambiguous = @enum_variants.each_with_object({}) do |(variant, owners), out|
        next if @structs.include?(variant) || union_names.include?(variant)
        next unless owners.length == 1

        out[variant] = owners.first
      end
    end

    private

    def scan_calls(path)
      relative = @relative_of[path]
      text = File.read(path)
      text.scan(/(?<![\w.])(\w+__\w*[?!]?)\(/) do |(name)|
        @private_callers[name] << relative if @declared_in.key?(name)
      end
    end

    def scan(path)
      current = nil
      File.readlines(path).each do |line|
        if (match = line.match(/\A(?:PUB )?STRUCT (\w+) \{/))
          current = match[1]
          @structs << match[1]
        elsif line.start_with?('}')
          current = nil
        elsif current && (match = line.match(/\A  ([a-z_]\w*): (.+?),?\s*\z/))
          @struct_fields[current][match[1]] = match[2]
          @element_of[[current, match[1]]] = Regexp.last_match(1) if match[2] =~ /\A\?*\[\](\w+)\z/
        end

        if (match = line.match(/\A(?:PUB )?UNION (\w+) \{ (.+?) \}/))
          match[2].split(',').each do |part|
            next unless part.include?(':')

            variant, payload = part.split(':', 2).map(&:strip)
            @union_variants[match[1]] << variant
            @variant_payloads[match[1]][variant] = payload
          end
        end
        if (match = line.match(/\APUB ENUM (\w+) \{ (.+?) \}/))
          match[2].split(',').each { |variant| @enum_variants[variant.strip] << match[1] }
        end
        if (match = line.match(/\A(?:PRIVATE |PUB )?FN (\w+[?!]?)(?:<[^>]*>)?\(.*?\)\s*RETURNS (\S+)/))
          @return_types[match[1]] = match[2]
        end
        if (match = line.match(/\A(PRIVATE |PUB )?FN (\w+__\w*[?!]?)\(/))
          @declared_in[match[2]] = [@relative_of[path], (match[1] || '').strip]
        end
        if (match = line.match(/\A(?:PRIVATE |PUB )?FN (\w+[?!]?)(?:<[^>]*>)?\((.*?)\)\s*(?:RETURNS|->|$)/))
          @accessors << match[1]
          @param_types[match[1]] = match[2].split(/,\s*(?![^<>{}]*[>}])/).map do |param|
            param.sub(/\A(?:MUTABLE )?\w+:\s*/, '').sub(/\s*=.*\z/, '').strip
          end
        end
      end
    end
  end

  # Per-line receiver typing, from the four places a type is locally evident:
  # a `node:` parameter, a `MUTABLE x: T` annotation, a FOR over a declared
  # list field, and the `_` a pipeline binds. Also tracks which bindings a nil
  # check has narrowed, so a rule does not "fix" an already-correct line.
  class Scope
    attr_reader :bindings, :optionals, :narrowed

    def initialize(index)
      @index = index
      reset
    end

    def reset
      @bindings = {}
      @optionals = {}
      @narrowed = Set.new
      @branch_stack = []
    end

    def observe(line)
      if line =~ /\A(?:PRIVATE |PUB )?FN /
        reset
        # EVERY typed parameter, not just `node:`. Typing only `node:` is why
        # the field-call rule missed `entry.kind()` on a CleanupEntry
        # parameter -- a whole build spent on a site the rule already knew how
        # to describe.
        if line =~ /\A(?:PRIVATE |PUB )?FN \w+[?!]?(?:<[^>]*>)?\((.*)\)/
          Regexp.last_match(1).split(/,\s*(?![^<>{}\[\]]*[>}\]])/).each do |param|
            next unless param =~ /\A(?:MUTABLE )?(\w+): \??([\w@]+)/

            @bindings[Regexp.last_match(1)] = Regexp.last_match(2)
          end
        end
      end
      if line =~ /MUTABLE (\w+): (\??[\w@\[\]]+) =/
        name = Regexp.last_match(1)
        type = Regexp.last_match(2)
        @bindings[name] = type.delete_prefix('?')
        type.start_with?('?') ? @optionals[name] = type : @optionals.delete(name)
      end
      owner = @bindings['node']
      if owner
        if line =~ /FOR (\w+) IN [\w.]*\.([a-z_]\w*)\b/ && (element = @index.element_of(owner, Regexp.last_match(2)))
          @bindings[Regexp.last_match(1)] = element
        end
        if line =~ /[\w.]*\.([a-z_]\w*) \|> (?:SELECT|WHERE|ANY|ALL|FIND)/ &&
           (element = @index.element_of(owner, Regexp.last_match(1)))
          @bindings['_'] = element
        end
      end
      # Narrowing is BRANCH-SCOPED, and getting that wrong is expensive in
      # both directions: too loose and a rule "fixes" correct lines, too
      # tight and it misses the sites that matter.
      #
      #   * a statement IF opens a scope that ELSE / ELSE_IF / END closes;
      #   * an IF EXPRESSION does NOT narrow its arms at all, so an UNWRAP
      #     inside one is required, not redundant;
      #   * `!= NIL`, `!(x == NIL)` and EXISTS are all the same check.
      #
      # A flat per-function set reported 159 redundant UNWRAPs of which the
      # first two sampled were both wrong -- one inside an IF expression, one
      # in a sibling ELSE_IF branch.
      # END closes FOR, WHILE, MATCH and WITH as well as IF, so the stack has
      # to carry an entry for EVERY opener or it desynchronises and pops a
      # narrowing that is still in force. That mistake put `val` back on the
      # report after it had been correctly cleared.
      if line =~ /\A\s*(?:ELSE_IF|ELSE)\b/
        @narrowed = (@branch_stack.last || Set.new).dup
      elsif line =~ /\A\s*END\b/
        @narrowed = @branch_stack.pop || Set.new
      end
      opens_block = line =~ /\bTHEN\s*\z/ ||
                    line =~ /\A\s*(?:FOR|WHILE)\b.*\bDO\s*\z/ ||
                    line =~ /\bSTART\s*\z/ ||
                    line =~ /\A\s*(?:WITH|DEFER)\b.*\{\s*\z/
      @branch_stack.push(@narrowed.dup) if opens_block && line !~ /\A\s*(?:ELSE_IF)\b/
      if line =~ /\bTHEN\s*\z/ && line =~ /\A\s*(?:IF|ELSE_IF)\b/
        line.scan(/(\w+) (?:!= NIL|EXISTS)/) { |(name)| @narrowed << name }
        line.scan(/!\(+(\w+) == NIL\)/) { |(name)| @narrowed << name }
      end
      line.scan(/EXISTS AS (\w+)/) { |(name)| @narrowed << name }
    end

    def optional_type(name)
      return nil if @narrowed.include?(name)

      @optionals[name]
    end

    def struct_of(receiver) = @bindings[receiver]
  end

  Finding = Struct.new(:rule, :file, :line, :message, keyword_init: true)

  # ---------------------------------------------------------------- rules --

  RULES = {}

  def rule(name, kind:, summary:, &block)
    RULES[name] = { kind: kind, summary: summary, apply: block }
  end

  # Ruby reaches a Struct member through an accessor, so `arm.body` IS a method
  # call. CLEAR has no such accessor unless one was written.
  rule(:field_calls, kind: :mechanical,
       summary: 'field read written as a zero-arg call') do |lines, index, findings, file, fix|
    scope = Scope.new(index)
    lines.each_with_index do |line, position|
      scope.observe(line)
      next if line.strip.start_with?('#')

      line.scan(/\b(\w+)\.([a-z_]\w*[?!]?)\(\)/) do |receiver, field|
        struct = scope.struct_of(receiver)
        next unless struct && index.field_type(struct, field.sub(/[?!]\z/, ''))

        # An accessor existing does NOT make `entry.kind()` legal -- CLEAR has
        # no methods on a struct, so a free FN has to be CALLED as one. Where
        # there is an accessor the call becomes `cleanupEntry__kind(entry)`;
        # where there is none it is a plain field read.
        accessor = index.accessor_name(struct, field)
        replacement = index.accessors.include?(accessor) ? "#{accessor}(#{receiver})" : "#{receiver}.#{field}"
        findings << Finding.new(rule: :field_calls, file: file, line: position + 1,
                                message: "#{receiver}.#{field}() -> #{replacement}")
        lines[position] = lines[position].gsub("#{receiver}.#{field}()", replacement) if fix
      end
    end
  end

  # IS_A tests a union's variant; an ENUM value is not a union.
  rule(:enum_is_a, kind: :mechanical,
       summary: 'IS_A against an enum variant') do |lines, index, findings, file, fix|
    pure = index.unambiguous_enum_variants
    lines.each_with_index do |line, position|
      line.scan(/\(([\w.]+) IS_A (\w+)\)/) do |receiver, variant|
        owner = pure[variant]
        next unless owner

        findings << Finding.new(rule: :enum_is_a, file: file, line: position + 1,
                                message: "#{receiver} IS_A #{variant} -- #{variant} is a variant of enum #{owner}")
        lines[position] = lines[position].sub("(#{receiver} IS_A #{variant})", "(#{receiver} == #{owner}.#{variant})") if fix
      end
    end
  end

  # Ruby prints a nil inside "#{...}" as the empty string; CLEAR rejects a
  # ?String. Only String-ish optionals are mechanical -- an Int64 or a boxed
  # value renders as something else and needs a decision.
  rule(:optional_interpolation, kind: :mechanical,
       summary: 'optional interpolated where CLEAR wants a String') do |lines, index, findings, file, fix|
    scope = Scope.new(index)
    lines.each_with_index do |line, position|
      scope.observe(line)
      next if line.strip.start_with?('#')

      line.scan(/\$\{([a-z_]\w*)\}/) do |(name)|
        type = scope.optional_type(name)
        next unless type

        if type =~ /\A\?String(@symbol)?\z/
          findings << Finding.new(rule: :optional_interpolation, file: file, line: position + 1,
                                  message: "${#{name}} is #{type}")
          lines[position] = lines[position].gsub("${#{name}}", "${(#{name} OR_ELSE \"\")}") if fix
        else
          findings << Finding.new(rule: :optional_interpolation, file: file, line: position + 1,
                                  message: "${#{name}} is #{type} -- ADVISORY, Ruby does not render this as \"\"")
        end
      end

      owner = scope.struct_of('node')
      next unless owner

      line.scan(/\$\{node\.([a-z_]\w*)\}/) do |(field)|
        type = index.field_type(owner, field)
        next unless type&.start_with?('?')
        next unless type =~ /\A\?String(@symbol)?\z/

        findings << Finding.new(rule: :optional_interpolation, file: file, line: position + 1,
                                message: "${node.#{field}} is #{type} on #{owner}")
        lines[position] = lines[position].gsub("${node.#{field}}", "${(node.#{field} OR_ELSE \"\")}") if fix
      end
    end
  end

  # `x ||= y` became `x = x OR y`, which is boolean. Correct where x really is
  # a Bool; wrong for every nilable accumulator.
  rule(:or_assign, kind: :mechanical,
       summary: '`x ||= y` translated as a boolean OR') do |lines, index, findings, file, fix|
    scope = Scope.new(index)
    lines.each_with_index do |line, position|
      scope.observe(line)
      next unless line =~ /\A(\s*)(\w+) = \(\2 OR (.+)\);\s*\z/

      indent = Regexp.last_match(1)
      name = Regexp.last_match(2)
      value = Regexp.last_match(3)
      type = scope.optionals[name]
      next unless type

      findings << Finding.new(rule: :or_assign, file: file, line: position + 1,
                              message: "#{name} is #{type}; OR is boolean")
      next unless fix

      lines[position] = "#{indent}IF (#{name} == NIL) THEN\n#{indent}  #{name} = #{value};\n#{indent}END"
    end
  end

  # `x OR "literal"` is Ruby's `||` default on a nilable.
  rule(:or_default, kind: :mechanical,
       summary: '`x OR literal` where OR_ELSE is meant') do |lines, index, findings, file, fix|
    scope = Scope.new(index)
    lines.each_with_index do |line, position|
      scope.observe(line)
      # A symbol literal is a default too -- handling only "..." left
      # `(node.alloc OR :heap)` for the build to find.
      line.scan(/\((\w+(?:\.\w+)*) OR ("(?:[^"\\]|\\.)*"|:\w+|\d+|TRUE|FALSE)\)/) do |receiver, literal|
        # `FALSE OR FALSE` is a genuine boolean OR, and so is any OR whose
        # left side is a Bool. Rewriting those to OR_ELSE corrupts working
        # code -- this rule reported one before the guard.
        next if %w[TRUE FALSE].include?(receiver)

        if receiver.include?('.')
          owner = scope.struct_of(receiver.split('.').first)
          field = index.field_type(owner, receiver.split('.').last) if owner
          if field && !field.start_with?('?')
            # Not optional at all: the default is dead and OR is the wrong
            # operator, so the fix is to DROP it, not to swap in OR_ELSE.
            findings << Finding.new(rule: :or_default, file: file, line: position + 1,
                                    message: "#{receiver} OR #{literal} -- #{receiver} is #{field}, drop the default")
            lines[position] = lines[position].sub("(#{receiver} OR #{literal})", receiver) if fix
            next
          end
        elsif scope.bindings[receiver] == 'Bool'
          next
        end

        findings << Finding.new(rule: :or_default, file: file, line: position + 1,
                                message: "#{receiver} OR #{literal}")
        lines[position] = lines[position].sub("(#{receiver} OR #{literal})", "(#{receiver} OR_ELSE #{literal})") if fix
      end
    end
  end

  # A Ruby `case` with a `when nil` arm. CLEAR has no NIL match case.
  rule(:nil_match_arm, kind: :advisory,
       summary: 'NIL arm in a PARTIAL MATCH') do |lines, _index, findings, file, _fix|
    lines.each_with_index do |line, position|
      next unless line =~ /\A\s*NIL ->/

      findings << Finding.new(rule: :nil_match_arm, file: file, line: position + 1,
                              message: line.strip[0, 80])
    end
  end

  # A union construction naming a variant that union does not have. Usually a
  # Ruby MIXIN used as a type (MIR::Stmt) or the wrong union reached for.
  rule(:unknown_variant, kind: :advisory,
       summary: 'union construction naming a variant the union lacks') do |lines, index, findings, file, _fix|
    lines.each_with_index do |line, position|
      line.scan(/\b(\w+)\{ (\w+):/) do |union, variant|
        next unless index.union_variants.key?(union)
        next if index.structs.include?(union)
        next if index.union_variants[union].include?(variant)

        findings << Finding.new(rule: :unknown_variant, file: file, line: position + 1,
                                message: "#{union}{ #{variant}: ... } -- #{union} has no such variant")
      end
    end
  end

  # Ruby reflection with no CLEAR counterpart.
  REFLECTION = {
    'respondsTo?' => /respondsTo\?\(/,
    '.class()' => /\.class\(\)/,
    'unsupportedRuby' => /unsupportedRuby\(/,
    '.to_a()' => /\.to_a\(\)/,
    'Kernel.' => /\bKernel\./,
    '.members' => /\.members\b/,
    'public_send' => /public_send/,
  }.freeze

  rule(:reflection, kind: :advisory,
       summary: 'Ruby reflection that CLEAR cannot express') do |lines, _index, findings, file, _fix|
    lines.each_with_index do |line, position|
      REFLECTION.each do |name, pattern|
        next unless line.match?(pattern)

        findings << Finding.new(rule: :reflection, file: file, line: position + 1, message: name)
      end
    end
  end

  # A field typed Any@multiowned is the translator saying it could not resolve
  # the type. CLEAR's Any is an f64, so the field is unusable as written.
  rule(:any_field, kind: :advisory,
       summary: 'field left as Any@multiowned') do |lines, _index, findings, file, _fix|
    current = nil
    lines.each_with_index do |line, position|
      current = Regexp.last_match(1) if line =~ /\A(?:PUB )?STRUCT (\w+) \{/
      current = nil if line.start_with?('}')
      next unless current && line =~ /\A  ([a-z_]\w*): Any@multiowned,?\s*\z/

      findings << Finding.new(rule: :any_field, file: file, line: position + 1,
                              message: "#{current}.#{Regexp.last_match(1)}")
    end
  end

  # `MUTABLE x = <nilable>` gives CLEAR nothing to infer from.
  rule(:unannotated_optional, kind: :advisory,
       summary: 'un-annotated bind of a nilable value') do |lines, index, findings, file, _fix|
    scope = Scope.new(index)
    lines.each_with_index do |line, position|
      scope.observe(line)
      next unless line =~ /\A\s*MUTABLE (\w+) = (\w+)\.([a-z_]\w*);\s*\z/

      struct = scope.struct_of(Regexp.last_match(2))
      next unless struct

      type = index.field_type(struct, Regexp.last_match(3))
      next unless type&.start_with?('?')

      findings << Finding.new(rule: :unannotated_optional, file: file, line: position + 1,
                              message: "MUTABLE #{Regexp.last_match(1)} = #{Regexp.last_match(2)}.#{Regexp.last_match(3)}; is #{type}")
    end
  end

  # A nilable field passed where the callee declares a non-optional parameter.
  rule(:optional_argument, kind: :advisory,
       summary: 'nilable argument at a non-optional parameter') do |lines, index, findings, file, _fix|
    scope = Scope.new(index)
    lines.each_with_index do |line, position|
      scope.observe(line)

      line.scan(/(\w+)\(([^()]*(?:\([^()]*\)[^()]*)*)\)/) do |callee, argument_text|
        declared = index.param_types[callee]
        next unless declared

        argument_text.split(/,\s*(?![^()]*\))/).each_with_index do |argument, slot|
          argument = argument.strip
          # Any typed receiver, not just `node.` -- restricting to one
          # parameter name is what let `cleanupEntry__resource_close_plan(entry)`
          # through, and it cost a build.
          actual = if argument =~ /\A(\w+)\.([a-z_]\w*)\z/
                     owner = scope.struct_of(Regexp.last_match(1))
                     owner && index.field_type(owner, Regexp.last_match(2))
                   elsif argument =~ /\A(\w+[?!]?)\((\w+)\)\z/
                     index.return_types[Regexp.last_match(1)]
                   end
          expected = declared[slot]
          next unless actual&.start_with?('?') && expected && !expected.start_with?('?')
          next if expected == 'Any@multiowned'
          next if scope.narrowed.include?(argument.split('.').first)

          findings << Finding.new(rule: :optional_argument, file: file, line: position + 1,
                                  message: "#{callee} arg #{slot + 1}: #{argument} is #{actual}, parameter is #{expected}")
        end
      end
    end
  end

  # `CAST({...} AS {K}V)` around a map literal that already has that type. The
  # translator emits it defensively; the parser's finished translation never
  # keeps one.
  rule(:cast_of_map_literal, kind: :advisory,
       summary: 'CAST around a map literal that is already typed') do |lines, _index, findings, file, _fix|
    lines.each_with_index do |line, position|
      next unless line =~ /CAST\(\{.*\} AS \{/

      findings << Finding.new(rule: :cast_of_map_literal, file: file, line: position + 1,
                              message: line.strip[0, 80])
    end
  end

  # `CAST("literal" AS String)` -- a String literal is already a String.
  rule(:cast_of_string_literal, kind: :mechanical,
       summary: 'CAST around a String literal') do |lines, _index, findings, file, fix|
    lines.each_with_index do |line, position|
      line.scan(/CAST\(("(?:[^"\\]|\\.)*") AS String\)/) do |(literal)|
        findings << Finding.new(rule: :cast_of_string_literal, file: file, line: position + 1,
                                message: "CAST(#{literal[0, 30]} AS String)")
        lines[position] = lines[position].sub("CAST(#{literal} AS String)", literal) if fix
      end
    end
  end

  # A union carrying both `X: X` and `XMultiowned: X@multiowned`. The finished
  # parser translation collapses these; the capability belongs on the binding.
  rule(:multiowned_variant, kind: :advisory,
       summary: 'union variant duplicated for @multiowned') do |lines, _index, findings, file, _fix|
    lines.each_with_index do |line, position|
      line.scan(/(\w+)Multiowned: (\w+)@multiowned/) do |variant, payload|
        next unless variant == payload

        findings << Finding.new(rule: :multiowned_variant, file: file, line: position + 1,
                                message: "#{variant}Multiowned: #{payload}@multiowned")
      end
    end
  end

  # A bare identifier that no enclosing FN declares. This is what a too-broad
  # search-and-replace produces -- I made exactly this mistake twice while
  # hand-fixing, replacing `node.window` file-wide instead of in one function,
  # and each cost a full build to discover.
  rule(:undeclared_local, kind: :advisory,
       summary: 'identifier used with no declaration in its function') do |lines, _index, findings, file, _fix|
    declared = Set.new
    body = []
    flush = lambda do
      body.each do |position, line|
        line.scan(/\$\{([a-z_]\w*)\}/) do |(name)|
          next if declared.include?(name)

          findings << Finding.new(rule: :undeclared_local, file: file, line: position + 1,
                                  message: "${#{name}} -- no declaration in this function")
        end
      end
      body = []
      declared = Set.new
    end
    lines.each_with_index do |line, position|
      if line =~ /\A(?:PRIVATE |PUB )?FN /
        flush.call
        line.scan(/(?:MUTABLE )?(\w+): /) { |(name)| declared << name }
      end
      declared << Regexp.last_match(1) if line =~ /MUTABLE (\w+)/
      declared << Regexp.last_match(1) if line =~ /\A\s*(\w+) = /
      line.scan(/AS (?:MUTABLE )?(\w+)/) { |(name)| declared << name }
      # Lambda parameters and USE captures declare names too; without these the
      # rule reports `%(bindings: String) USE(...)` as undeclared.
      line.scan(/%\(([^)]*)\)/) do |(params)|
        params.scan(/(?:MUTABLE )?(\w+):/) { |(name)| declared << name }
      end
      line.scan(/USE\(([^)]*)\)/) do |(captures)|
        captures.split(',').each { |capture| declared << capture.strip.sub(/\AMUTABLE /, '') }
      end
      line.scan(/FOR (\w+) IN/) { |(name)| declared << name }
      line.scan(/EXISTS AS (\w+)/) { |(name)| declared << name }
      declared << '_'
      body << [position, line]
    end
    flush.call
  end

  # `IF x IS_A []T AS y ... ELSE <use x> END` -- Ruby's `body.is_a?(Array)` on a
  # value that is a UNION of the list shape and the single shape. The IS_A arm
  # is fine; the ELSE arm passes the union on where the payload is wanted, and
  # that only fails once something downstream declares the payload type.
  rule(:two_variant_else_arm, kind: :advisory,
       summary: 'IS_A on a 2-variant union whose ELSE arm passes the union through') do |lines, index, findings, file, _fix|
    scope = Scope.new(index)
    lines.each_with_index do |line, position|
      scope.observe(line)
      next unless line =~ /IF (\w+) IS_A (\[\])?([\w@]+)/

      subject = Regexp.last_match(1)
      probe = "#{Regexp.last_match(2)}#{Regexp.last_match(3)}"
      union = scope.struct_of(subject)
      # Only a union with exactly two variants is unambiguous: the ELSE arm can
      # then only mean "the other payload", never "the union itself".
      next unless union && index.union_variants[union].length == 2

      tail = lines[position + 1, 6].to_a.join(' ')
      next unless tail.include?('ELSE') && tail =~ /\b#{Regexp.escape(subject)}\b/

      findings << Finding.new(rule: :two_variant_else_arm, file: file, line: position + 1,
                              message: "#{subject} IS_A #{probe} on 2-variant #{union}; ELSE arm still uses #{subject}")
    end
  end

  # `UNWRAP (x)` where a nil check already narrowed x. CLEAR rejects it: the
  # declaration says optional, the flow says otherwise. Ruby writes the guard
  # and the `T.must` separately and the translation keeps both.
  rule(:redundant_unwrap, kind: :mechanical,
       summary: 'UNWRAP of a value a nil check already narrowed') do |lines, index, findings, file, fix|
    scope = Scope.new(index)
    lines.each_with_index do |line, position|
      narrowed_before = scope.narrowed.dup
      scope.observe(line)
      line.scan(/UNWRAP \((\w+)\)/) do |(name)|
        next unless narrowed_before.include?(name)

        findings << Finding.new(rule: :redundant_unwrap, file: file, line: position + 1,
                                message: "UNWRAP (#{name}) -- already narrowed")
        lines[position] = lines[position].gsub("UNWRAP (#{name})", name) if fix
      end
    end
  end

  # `MUTABLE x = (opt OR_ELSE fallback)` with no annotation. The value is not
  # optional -- that is what OR_ELSE is for -- but CLEAR infers from the left
  # operand and every later use of x is then a ?T where a T is wanted. The
  # annotation is the whole fix, and it is invisible until something
  # interpolates x.
  rule(:unannotated_or_else, kind: :advisory,
       summary: 'un-annotated bind of an OR_ELSE result') do |lines, _index, findings, file, _fix|
    lines.each_with_index do |line, position|
      next unless line =~ /\A\s*MUTABLE (\w+) = \(.* OR_ELSE .*\);\s*\z/

      findings << Finding.new(rule: :unannotated_or_else, file: file, line: position + 1,
                              message: "MUTABLE #{Regexp.last_match(1)} = (... OR_ELSE ...) -- no annotation")
    end
  end

  # An interpolated CALL whose return type is optional. Same rule as an
  # interpolated identifier, but typed from the signature -- and easy to miss,
  # because the error points at a column inside a long format string and reads
  # as if it were about the neighbouring variable.
  rule(:optional_call_interpolation, kind: :advisory,
       summary: 'interpolated call that returns an optional') do |lines, index, findings, file, _fix|
    lines.each_with_index do |line, position|
      next if line.strip.start_with?('#')

      line.scan(/\$\{(\w+)\(/) do |(callee)|
        type = index.return_types[callee]
        next unless type&.start_with?('?')

        findings << Finding.new(rule: :optional_call_interpolation, file: file, line: position + 1,
                                message: "${#{callee}(...)} returns #{type}")
      end
    end
  end

  # A scalar passed where a UNION parameter is declared. Ruby has no wrapper,
  # so the translation passes the bare value and CLEAR wants the variant. Only
  # fired when exactly ONE variant of that union carries the argument's type --
  # otherwise the choice is a judgement, not a rewrite.
  rule(:missing_union_wrap, kind: :mechanical,
       summary: 'scalar passed where a union parameter is declared') do |lines, index, findings, file, fix|
    scope = Scope.new(index)
    payloads = {}
    index.union_variants.each_key do |union|
      # Variant -> payload type, read back from the union's own declaration.
      payloads[union] = {}
    end
    lines.each_with_index do |line, position|
      scope.observe(line)
      next if line.strip.start_with?('#')

      line.scan(/(\w+)\(([^()]*(?:\([^()]*\)[^()]*)*)\)/) do |callee, argument_text|
        declared = index.param_types[callee]
        next unless declared

        argument_text.split(/,\s*(?![^()]*\))/).each_with_index do |argument, slot|
          argument = argument.strip
          expected = declared[slot]&.delete_prefix('?')
          # An OPTIONAL union parameter still needs the wrap; keying on the
          # literal `?Emittable` missed `emit(node.alloc_ref)` entirely.
          next unless expected && index.union_variants.key?(expected)
          # A name can be BOTH a union and a struct -- `Type` is a struct in
          # ast/type.clear and a union in pipeline_host.clear. Wrapping on the
          # union reading of an ambiguous name reported 1012 sites, nearly all
          # of them correct code passing the struct.
          next if index.structs.include?(expected)

          # A bare identifier OR a field read off a typed receiver -- limiting
          # this to bare identifiers left `move_guard_name(node.name)` for the
          # build to find.
          actual = if argument =~ /\A\w+\z/
                     scope.struct_of(argument)
                   elsif argument =~ /\A(\w+)\.([a-z_]\w*)\z/
                     owner = scope.struct_of(Regexp.last_match(1))
                     owner && index.field_type(owner, Regexp.last_match(2))
                   end
          next unless actual
          next if actual.start_with?('?')
          next if actual == expected

          matching = index.variant_payloads(expected).select { |_, payload| payload == actual }
          next unless matching.length == 1

          variant = matching.keys.first
          findings << Finding.new(rule: :missing_union_wrap, file: file, line: position + 1,
                                  message: "#{callee} arg #{slot + 1}: #{argument} is #{actual}, parameter is union #{expected}")
          next unless fix

          lines[position] = lines[position].sub(/(#{Regexp.escape(callee)}\([^()]*?)#{Regexp.escape(argument)}(?![\w.])/,
                                                "\\1#{expected}{ #{variant}: COPY #{argument} }")
        end
      end
    end
  end

  # `OR_ELSE` on a value that is not optional. Usually the residue of typing a
  # local that the translation had left inferred -- the annotation is right and
  # the default is now dead, but CLEAR rejects rather than ignores it.
  rule(:or_else_on_plain, kind: :mechanical,
       summary: 'OR_ELSE on a value that is not optional') do |lines, index, findings, file, fix|
    scope = Scope.new(index)
    lines.each_with_index do |line, position|
      scope.observe(line)
      next if line.strip.start_with?('#')

      line.scan(/\((\w+) OR_ELSE ((?:"(?:[^"\\]|\\.)*"|[^()]|\([^()]*\))*)\)/) do |name, fallback|
        declared = scope.bindings[name]
        next unless declared
        next if scope.optionals.key?(name)
        # Only a local THIS FUNCTION annotated non-optional. Searching the
        # whole file above instead stripped a needed OR_ELSE off a `message`
        # parameter, because an unrelated function earlier in the file had a
        # `MUTABLE message: String`. Fifth over-fire, same root cause every
        # time: a name matched without its owner.
        function_start = lines[0...position].rindex { |earlier| earlier =~ /\A(?:PRIVATE |PUB )?FN / } || 0
        next unless lines[function_start...position].any? { |earlier| earlier =~ /MUTABLE #{Regexp.escape(name)}: [^?]/ }

        findings << Finding.new(rule: :or_else_on_plain, file: file, line: position + 1,
                                message: "(#{name} OR_ELSE ...) -- #{name} is #{declared}")
        lines[position] = lines[position].sub("(#{name} OR_ELSE #{fallback})", name) if fix
      end
    end
  end

  # A field passed to a parameter whose declared type it cannot be. Ruby has
  # no field types, so the translation infers one from whatever a construction
  # site happened to pass -- `RcDowngrade.source` came out String because a
  # caller passed a name, while every consumer runs it through `emit`, which
  # takes an Emittable.
  #
  # The consumers are the evidence: when a field is only ever handed to
  # parameters of one type, and that is not the field's declared type, the
  # declaration is what is wrong.
  rule(:field_type_contradicted, kind: :advisory,
       summary: 'field type contradicted by every use of it') do |lines, index, findings, file, _fix|
    scope = Scope.new(index)
    seen = {}
    lines.each_with_index do |line, position|
      scope.observe(line)
      next if line.strip.start_with?('#')

      line.scan(/(\w+)\(([^()]*(?:\([^()]*\)[^()]*)*)\)/) do |callee, argument_text|
        declared = index.param_types[callee]
        next unless declared

        argument_text.split(/,\s*(?![^()]*\))/).each_with_index do |argument, slot|
          next unless argument.strip =~ /\A(\w+)\.([a-z_]\w*)\z/

          owner = scope.struct_of(Regexp.last_match(1))
          field = Regexp.last_match(2)
          next unless owner

          actual = index.field_type(owner, field)
          expected = declared[slot]
          next unless actual && expected
          next if actual == expected
          # `Any` is a generic parameter, not evidence; and a difference that
          # is only a capability or an optional wrapper is not a wrong TYPE.
          next if expected.delete_suffix('@multiowned') == 'Any'
          bare = ->(type) { type.delete_prefix('?').sub(/@(multiowned|boxed|shared|local)\z/, '') }
          next if bare.call(actual) == bare.call(expected)

          key = [file, owner, field]
          seen[key] ||= []
          seen[key] << [position + 1, callee, expected, actual]
        end
      end
    end
    seen.each do |(file_name, owner, field), uses|
      # Only when EVERY use agrees on a type the declaration does not have.
      wanted = uses.map { |use| use[2].delete_prefix('?').sub(/@(multiowned|boxed|shared|local)\z/, '') }.uniq
      next unless wanted.length == 1
      # One call site is a coincidence; two agreeing is evidence.
      next unless uses.length >= 2

      declared_type = index.field_type(owner, field)
      next if declared_type.delete_prefix('?').sub(/@(multiowned|boxed|shared|local)\z/, '') == wanted.first

      findings << Finding.new(rule: :field_type_contradicted, file: file_name, line: uses.first[0],
                              message: "#{owner}.#{field} is #{declared_type}, but all #{uses.length} use(s) want #{wanted.first}")
    end
  end

  # A non-PUB FN called from another file. Ruby has no package visibility, so
  # ruby-to-clear guesses -- and a `?`-suffixed predicate almost always comes
  # out private because Ruby marked it `private` for its own reasons.
  #
  # Cross-file is the right test rather than cross-package: it is a strict
  # superset (a package can span files) and it needs no package map.
  rule(:private_across_files, kind: :mechanical,
       summary: 'non-PUB FN called from another file') do |lines, index, findings, file, fix|
    index.cross_file_privates.each do |name, home|
      next unless home == file

      lines.each_with_index do |line, position|
        next unless line =~ /\A(PRIVATE )?FN #{Regexp.escape(name)}\(/

        findings << Finding.new(rule: :private_across_files, file: file, line: position + 1,
                                message: "#{name} is called from #{index.private_callers[name].length} other file(s)")
        lines[position] = line.sub(/\A(?:PRIVATE )?FN /, 'PUB FN ') if fix
      end
    end
  end

  # A field INTERPOLATED into a string but declared as something no string can
  # hold. `ArrayInit.count` came out Emittable while every construction site
  # passes a String and the only consumer interpolates it -- the argument-based
  # evidence rule cannot see that, because the field is never passed anywhere.
  rule(:interpolated_non_string_field, kind: :advisory,
       summary: 'field interpolated but declared as a node type') do |lines, index, findings, file, _fix|
    scope = Scope.new(index)
    lines.each_with_index do |line, position|
      scope.observe(line)
      next if line.strip.start_with?('#')

      line.scan(/\$\{(\w+)\.([a-z_]\w*)\}/) do |receiver, field|
        owner = scope.struct_of(receiver)
        next unless owner

        type = index.field_type(owner, field)
        next unless type

        bare = type.delete_prefix('?').sub(/@\w+\z/, '')
        next if %w[String Int64 UInt64 Float64 Bool].include?(bare)
        next if bare.end_with?('@symbol') || bare == 'String@symbol'
        # A union or struct cannot be interpolated; either the field type is
        # wrong or the site needs a render call.
        next unless index.structs.include?(bare) || index.union_variants.key?(bare)

        findings << Finding.new(rule: :interpolated_non_string_field, file: file, line: position + 1,
                                message: "${#{receiver}.#{field}} but #{owner}.#{field} is #{type}")
      end
    end
  end

  # `x[:field]` is Ruby hash syntax; on a struct it is a field read. Advisory
  # because CLEAR really does index a {String@symbol}V map that way.
  rule(:hash_field, kind: :advisory,
       summary: 'x[:field] -- Ruby hash syntax, sometimes a struct read') do |lines, _index, findings, file, _fix|
    lines.each_with_index do |line, position|
      line.scan(/(\w+)\[:(\w+)\]/) do |receiver, field|
        findings << Finding.new(rule: :hash_field, file: file, line: position + 1,
                                message: "#{receiver}[:#{field}]")
      end
    end
  end

  # ----------------------------------------------------------------- main --

  def main(argv)
    options = { root: File.expand_path('../compiler/src', __dir__), mode: :check, only: nil, quiet: false }
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby tools/rtoc_postprocess.rb [--check|--fix] [--root DIR] [--only RULES]'
      parser.on('--check', 'Report findings, change nothing (default)') { options[:mode] = :check }
      parser.on('--fix', 'Apply every mechanical rule') { options[:mode] = :fix }
      parser.on('--root DIR') { |value| options[:root] = File.expand_path(value) }
      parser.on('--only RULES', 'Comma-separated rule names') { |value| options[:only] = value.split(',').map(&:to_sym) }
      parser.on('--quiet', 'Counts only, no per-site lines') { options[:quiet] = true }
      parser.on('--list', 'List the rules and exit') do
        RULES.each { |name, spec| puts format('  %-24s %-11s %s', name, spec[:kind], spec[:summary]) }
        exit 0
      end
      parser.on('-h', '--help') { puts parser; exit 0 }
    end.parse!(argv)

    sources = Dir.glob(File.join(options[:root], '**', '*.clear')).sort
    if sources.empty?
      warn "rtoc_postprocess: no .clear sources under #{options[:root]}"
      return 2
    end

    index = TypeIndex.new(sources)
    selected = options[:only] ? RULES.slice(*options[:only]) : RULES
    findings = []
    changed = 0

    sources.each do |path|
      relative = path.delete_prefix("#{options[:root]}/")
      lines = File.read(path).split("\n")
      before = lines.dup
      selected.each do |name, spec|
        fix = options[:mode] == :fix && spec[:kind] == :mechanical
        spec[:apply].call(lines, index, findings, relative, fix)
      end
      next unless lines != before

      File.write(path, "#{lines.join("\n")}\n".sub(/\n\n\z/, "\n"))
      changed += 1
    end

    report(findings, selected, changed, options)
  end

  def report(findings, selected, changed, options)
    by_rule = findings.group_by(&:rule)
    puts "rtoc_postprocess: #{findings.length} finding(s) across #{selected.length} rule(s)"
    puts
    selected.each_key do |name|
      hits = by_rule[name] || []
      next if hits.empty?

      puts format('  %-24s %-11s %d', name, RULES[name][:kind], hits.length)
      next if options[:quiet]

      hits.first(8).each { |finding| puts format('      %s:%d  %s', finding.file, finding.line, finding.message) }
      puts "      ... #{hits.length - 8} more" if hits.length > 8
    end
    if options[:mode] == :fix
      puts
      puts "rtoc_postprocess: rewrote #{changed} file(s); advisory findings are reported, never rewritten"
    end
    findings.empty? ? 0 : 1
  end
end

exit(RtocPostprocess.main(ARGV)) if $PROGRAM_NAME == __FILE__
