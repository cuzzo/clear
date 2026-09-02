#!/usr/bin/env ruby
# frozen_string_literal: true

# Apply the fixes the per-function probe's diagnostics fully determine.
#
# Each rule keys off a compiler message that names both the site and the thing
# to change, so nothing is inferred: the argument index, the receiver type, the
# variable name all come from the error text. Run after a probe; the locations
# drift as soon as any file is edited, so re-probe between rounds.
require 'json'
require 'optparse'
require 'set'
require_relative 'selfhost_union_accessor'

ROOT = File.expand_path('../compiler/src', __dir__)
probe = File.expand_path('../.fn_probe.json', __dir__)
apply = false
OptionParser.new do |p|
  p.on('--apply') { apply = true }
  p.on('--probe FILE') { |v| probe = v }
end.parse!

def close_paren(t, i)
  d = 0
  instr = false
  while i < t.length
    c = t[i]
    if instr then instr = false if c == '"'
    elsif c == '"' then instr = true
    elsif c == '(' then d += 1
    elsif c == ')'
      d -= 1
      return i if d.zero?
    end
    i += 1
  end
  nil
end

def arg_spans(t, from, fin)
  spans = []
  d = 0
  start = from
  instr = false
  (from...fin).each do |i|
    c = t[i]
    if instr
      instr = false if c == '"'
      next
    end
    if c == '"'
      instr = true
      next
    end
    d += 1 if '([{'.include?(c)
    d -= 1 if ')]}'.include?(c)
    if c == ',' && d.zero?
      spans << [start, i]
      start = i + 1
    end
  end
  spans << [start, fin]
  spans
end

# The Nth argument of the call whose closing paren reaches the reported line.
# The Nth argument of the call the diagnostic is about. When more than one
# call on the line could be the one -- a call passed as an argument to another
# call has its own argument 1 -- the site is ambiguous and is left alone:
# guessing rewrites the inner call and the compiler then contradicts itself
# about the same operand forever.
def locate_arg(text, offsets, ln, argno, fn_name = nil, expect = nil)
  (0..8).each do |back|
    idx = ln - 1 - back
    break if idx.negative?

    cands = []
    text[offsets[idx]...offsets[idx + 1]].to_s
        .to_enum(:scan, /(?<![\w.])([a-zA-Z_]\w*[?!]?)\(/).each do
      mm = Regexp.last_match
      name = mm[1]
      open_at = offsets[idx] + mm.end(0) - 1
      fin = close_paren(text, open_at) or next
      next unless fin >= offsets[ln - 1]

      sp = arg_spans(text, open_at + 1, fin)[argno - 1] or next
      cands << [name, sp]
    end
    next if cands.empty?

    if fn_name && (exact = cands.find { |n, _| n == fn_name })
      return exact[1]
    end
    return cands.first[1] if cands.length == 1

    # Several calls on the line could be the subject. The declared parameter
    # type settles it exactly: only one callee declares `expects` at index N.
    if expect
      typed = cands.select { |n, _| PARAM_TYPES[n]&.[](argno - 1) == expect }
      return typed.first[1] if typed.length == 1
    end

    return nil
  end
  nil
end

variants, STRUCT_FIELDS = SelfhostUnionAccessor.load_types(ROOT)

# A field name is treated as optional only when EVERY struct declaring it
# declares it optional -- otherwise the same name on another receiver in the
# line would be rewritten wrongly.
OPTIONAL_FIELD = Hash.new(false)
begin
  seen = Hash.new { |h, k| h[k] = [] }
  STRUCT_FIELDS.each_value { |fs| fs.each { |f, ty| seen[f] << ty.to_s } }
  seen.each { |f, tys| OPTIONAL_FIELD[f] = tys.all? { |ty| ty.start_with?('?') } }
end
BOOL_FIELD = Hash.new(false)
begin
  seen = Hash.new { |h, k| h[k] = [] }
  STRUCT_FIELDS.each_value { |fs| fs.each { |f, ty| seen[f] << ty.to_s } }
  seen.each { |f, tys| BOOL_FIELD[f] = tys.all? { |ty| ty == '?Bool' } }
end
# variant name keyed by payload type, so `got X` names the variant directly
VARIANT_OF = variants.transform_values do |vs|
  vs.to_h { |name, type| [type.to_s.sub(/@\w+\z/, ''), name] }
end.freeze

CASTS = Dir.glob(File.join(ROOT, '**', '*.clear')).flat_map do |f|
  File.read(f).scan(/\bFN (cast\w+To\w+)\(/).flatten
end.to_set.freeze

DEFINED = Dir.glob(File.join(ROOT, '**', '*.clear')).flat_map do |f|
  File.read(f).scan(/\bFN ([\w?!]+)\s*(?:<[^>]*>)?\(/).flatten
end.to_set.freeze

PARAM_TYPES = {}
Dir.glob(File.join(ROOT, '**', '*.clear')).each do |f|
  File.read(f).scan(/\bFN ([\w?!]+)\(([^\n]*?)\)\s*RETURNS/) do |name, params|
    PARAM_TYPES[name] = params.split(/,\s*(?=(?:MUTABLE\s+)?\w+:)/).map do |p|
      p[/:\s*([\w@?\[\]{}]+)/, 1]
    end
  end
end
PARAM_TYPES.freeze

RETURNS = Dir.glob(File.join(ROOT, '**', '*.clear')).flat_map do |f|
  File.read(f).scan(/\bFN ([\w?!]+)\([^\n]*?\)\s*RETURNS\s+([\w@?\[\]{}!]+)/)
end.to_h.freeze

# Receivers in this tree are rarely bare identifiers: they are calls, indexed
# elements, and UNWRAPs. A narrow pattern makes a rule silently match nothing,
# which reads as "the class needs a new rule" when it does not.
RECV = /(?:UNWRAP\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)|[a-z_]\w*(?:__\w+)?\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)|[a-z_]\w*(?:\[[^\]]*\])?(?:\.[a-z_]\w*(?:\[[^\]]*\])?)*)/

def accessor_for(union, field)
  name = "#{union[0].to_s.downcase}#{union[1..]}__#{field}"
  return name if DEFINED.include?(name)

  # A field whose type differs across variants is published by the AST module
  # rather than as a per-union accessor.
  return "aST__node_#{field}" if %w[Locatable Node].include?(union) &&
                                 DEFINED.include?("aST__node_#{field}")
  return "aST__node__#{field}" if %w[Locatable Node].include?(union) &&
                                  DEFINED.include?("aST__node__#{field}")

  nil
end

rows = JSON.parse(File.read(probe)).select { |r| !r['ok'] && r['line'] && r['error'] }
by = Hash.new { |h, k| h[k] = [] }
rows.each { |r| by[r['file']] << r }

counts = Hash.new(0)
by.each do |f, rs|
  path = File.join(ROOT, f)
  text = File.read(path)
  offsets = [0]
  text.each_line { |l| offsets << offsets.last + l.length }
  # A WITH POLYMORPHIC alias is a borrow of the receiver: it is never optional
  # and never needs a cast. Unwrapping one is always wrong, however the
  # diagnostic's call is resolved.
  view_aliases = text.scan(/WITH POLYMORPHIC\s+\w+\s+AS\s+(?:MUTABLE\s+)?(\w+)/).flatten.to_set

  edits = []
  line_edits = []
  rs.each do |r|
    e = r['error']
    argno = e[/[Aa]rgument (\d+)/, 1].to_i

    if (m = e.match(/argument \d+ expects ([\w@\[\]{}]+), got \?([\w@\[\]{}]+)\z/)) && m[1] == m[2]
      sp = locate_arg(text, offsets, r['line'], argno, nil, m[1]) or next
      expr = text[sp[0]...sp[1]].strip
      next if expr.empty? || expr.start_with?('UNWRAP')
      next if view_aliases.include?(expr)
      # A view or a receiver the compiler reported as optional once can be
      # reported again after an unrelated edit; wrapping twice is never right.
      next if expr.include?('UNWRAP (')
      # `&x` is a mutating argument. Neither UNWRAP (&x) nor &UNWRAP (x) is
      # accepted here: an optional mutable argument needs an EXISTS AS
      # MUTABLE binding at the call site, which is not a wrap.
      next if expr.start_with?('&')

      edits << [sp[0], sp[1], " UNWRAP (#{expr})", :unwrap_arg]
    elsif (m = e.match(/argument \d+ expects (\w+), got (\w+)\z/)) && VARIANT_OF[m[1]]&.key?(m[2])
      sp = locate_arg(text, offsets, r['line'], argno, nil, m[1]) or next
      expr = text[sp[0]...sp[1]].strip
      next if expr.empty? || expr.include?("#{m[1]}{ #{VARIANT_OF[m[1]][m[2]]}:")

      edits << [sp[0], sp[1], " #{m[1]}{ #{VARIANT_OF[m[1]][m[2]]}: COPY #{expr} }", :wrap_variant]
    elsif (m = e.match(/argument \d+ expects (\w+), got (\w+)\z/)) && CASTS.include?("cast#{m[2]}To#{m[1]}")
      sp = locate_arg(text, offsets, r['line'], argno, nil, m[1]) or next
      expr = text[sp[0]...sp[1]].strip
      # The rewrite wraps the argument, so a later round sees its own output.
      # Without this the cast nests on every round.
      next if expr.empty? || expr.include?("cast#{m[2]}To#{m[1]}(")
      next if view_aliases.include?(expr)
      # The cast takes its value by value. A `&` on the argument marks the
      # OUTER call's parameter as mutating, so it belongs outside the cast.
      inner = expr.delete_prefix('&')
      marker = expr.start_with?('&') ? '&' : ''

      edits << [sp[0], sp[1], " #{marker}UNWRAP (cast#{m[2]}To#{m[1]}(#{inner}))", :cast_arg]
    elsif (m = e.match(/Pass '(\w+)' as '&\w+'/))
      sp = locate_arg(text, offsets, r['line'], argno)
      if sp && (expr = text[sp[0]...sp[1]].strip) =~ /\A#{m[1]}(\.|\z)/
        edits << [sp[0], sp[1], " &#{expr}", :mutable_arg]
      else
        line_edits << [r['line'], :mutable_arg_line, m[1]]
      end
    elsif (m = e.match(/passed immutable variable '(\w+)'/))
      line_edits << [r['line'], :declare_mutable, m[1]]
    elsif e.include?('UNWRAP_NON_OPTIONAL')
      line_edits << [r['line'], :drop_unwrap, nil]
    elsif (m = e.match(/Cannot access field '(\w+)' on optional '\?[\w@\[\]{}]+' without safe navigation/))
      line_edits << [r['line'], :unwrap_receiver, m[1]]
    elsif (m = e.match(/Cannot modify field '\w+' of immutable object '(\w+)'/))
      line_edits << [r['line'], :mutable_view, m[1]]
    elsif e =~ /Undefined variable 'AST'/
      line_edits << [r['line'], :ast_variant, nil]
    elsif (m = e.match(/Runtime IS_A requires a union-typed value on the left, got \?(\w+)/)) &&
          VARIANT_OF.key?(m[1])
      line_edits << [r['line'], :unwrap_is_a, nil]
    elsif (m = e.match(/Runtime IS_A requires a union-typed value on the left, got (\w+)\.?\z/))
      line_edits << [r['line'], :static_is_a, m[1]]
    elsif (m = e.match(/'(\w+)' is a union type\. Access variants with/))
      line_edits << [r['line'], :union_field_write, m[1]]
      line_edits << [r['line'], :union_field_read, m[1]]
    elsif (m = e.match(/RESTRICT capability requires a mutable variable, but '(\w+)' is immutable/))
      line_edits << [r['line'], :mutable_param, m[1]]
    elsif e =~ /Operator NEQ cannot compare \w+ with NIL/
      line_edits << [r['line'], :fold_nil_compare, nil]
    elsif (m = e.match(/Cannot infer `(\w+)` from an optional value/))
      line_edits << [r['line'], :annotate_optional, m[1]]
    elsif (m = e.match(/Operator \$\+ requires String operands, got ([\w?@\[\]]+)/))
      line_edits << [r['line'], :stringify_interp, m[1]]
    elsif e =~ /Ambiguous \?Bool (?:AND|OR) operand/
      line_edits << [r['line'], :orelse_bool, nil]
    elsif e =~ /OR_ELSE requires a fallible/
      line_edits << [r['line'], :drop_or_else, nil]
    elsif (m = e.match(/No overload for 'toString' matches arguments \((\w+)\)/))
      line_edits << [r['line'], :to_s_helper, m[1]]
    elsif (m = e.match(/argument \d+ expects (\[\][\w@]+|\[Set\][\w@]+|\{[^}]*\}[\w@]+), got NIL\z/))
      # Ruby defaults the collection parameter to an empty one; the
      # translation dropped the default and the caller passes nil.
      sp = locate_arg(text, offsets, r['line'], argno)
      if sp && text[sp[0]...sp[1]].strip == 'NIL'
        empty = m[1].start_with?('[Set]') ? 'Set[]' : (m[1].start_with?('{') ? '{}' : 'List[]')
        edits << [sp[0], sp[1], " #{empty}", :empty_collection_arg]
      end
    end
  end

  # Line rules run against the ORIGINAL line array. A span edit can cover a
  # newline -- an argument list split across lines replaced by one string --
  # which collapses lines and shifts every later index, so line rules must not
  # see a partially span-edited buffer. Both kinds are converted to spans over
  # the original text and applied together, right to left.
  original = text
  lines = original.lines
  line_edits.uniq.each do |ln, kind, name|
    i = ln - 1
    next unless lines[i]

    case kind
    when :declare_mutable
      j = i
      while j >= 0
        if lines[j] =~ /^(PUB |PRIVATE )?FN /
          # No local declares it, so the name is a parameter.
          if lines[j] =~ /[(,]\s*#{name}:/ && lines[j] !~ /MUTABLE #{name}:/
            lines[j] = lines[j].sub(/(?<=[(,] )#{name}:/, "MUTABLE #{name}:")
                               .sub(/\(#{name}:/, "(MUTABLE #{name}:")
            counts[kind] += 1
          end
          break
        end

        if lines[j] =~ /\bAS\s+#{name}\b/ && lines[j] !~ /AS\s+MUTABLE\s+#{name}\b/
          lines[j] = lines[j].sub(/\bAS\s+#{name}\b/, "AS MUTABLE #{name}")
          counts[kind] += 1
          break
        elsif lines[j] =~ /^(\s*)#{name}\s*(:[^=]*)?=/ && lines[j] !~ /\bMUTABLE\b/
          lines[j] = lines[j].sub(/^(\s*)#{name}\b/) { "#{Regexp.last_match(1)}MUTABLE #{name}" }
          counts[kind] += 1
          break
        end
        j -= 1
      end
    when :unwrap_receiver
      # The receiver of `.field` is optional. Ruby would have raised on nil
      # here, so the value is non-nil by construction: unwrap it rather than
      # introducing a safe-navigation branch Ruby does not have.
      lines[i] = lines[i].gsub(/(?<![\w.)])((?:[a-z_]\w*(?:__\w+)?\((?:[^()]|\([^()]*\))*\)|[a-z_]\w*))\.#{name}\b/) do
        whole = Regexp.last_match(0)
        recv = Regexp.last_match(1)
        # A guard match resets $~, so the original match has to be held first.
        rest = Regexp.last_match.post_match
        next whole if recv.start_with?('UNWRAP')
        # An assignment target is not an expression: unwrapping it would
        # produce a value on the left of `=`.
        next whole if rest =~ /\A\s*=[^=]/

        counts[kind] += 1
        "UNWRAP (#{recv}).#{name}"
      end
    when :mutable_view
      j = i
      while j >= 0
        if lines[j] =~ /WITH POLYMORPHIC\s+\w+\s+AS\s+#{name}\s*\{/
          lines[j] = lines[j].sub(/AS\s+#{name}/, "AS MUTABLE #{name}")
          counts[kind] += 1
          break
        end
        break if lines[j] =~ /^(PUB |PRIVATE )?FN /

        j -= 1
      end
    when :ast_variant
      # `AST.StructDef` is Ruby's AST::StructDef; the CLEAR union that holds
      # that variant is the one to name.
      lines[i] = lines[i].gsub(/\bAST\.(\w+)\b/) do
        whole = Regexp.last_match(0)
        v = Regexp.last_match(1)
        owner = VARIANT_OF.find { |_, vs| vs.value?(v) }&.first
        next whole unless owner

        counts[kind] += 1
        "#{owner}.#{v}"
      end
    when :fold_nil_compare
      # The operand is not optional, so Ruby's nil guard is decided here.
      # Only an unambiguous line is folded.
      if lines[i].scan(/!=\s*NIL/).length == 1 && lines[i].scan(/==\s*NIL/).empty?
        lines[i] = lines[i].sub(/(?<![\w.)])#{RECV}\s*!=\s*NIL/, 'TRUE')
        counts[kind] += 1
      elsif lines[i].scan(/==\s*NIL/).length == 1 && lines[i].scan(/!=\s*NIL/).empty?
        lines[i] = lines[i].sub(/(?<![\w.)])#{RECV}\s*==\s*NIL/, 'FALSE')
        counts[kind] += 1
      end
    when :annotate_optional
      # An optional initializer needs the binding's type spelled out; the
      # callee's declared return type is that type.
      m = lines[i].match(/^(\s*)MUTABLE #{name}\s*=\s*(?:TRY\s*\()?\s*([\w?!]+)\(/)
      if m && (ret = RETURNS[m[2]])
        ret = ret.delete_prefix('!')
        ret = "?#{ret}" unless ret.start_with?('?')
        lines[i] = lines[i].sub(/^(\s*)MUTABLE #{name}\s*=/) { "#{Regexp.last_match(1)}MUTABLE #{name}: #{ret} =" }
        counts[kind] += 1
      end
    when :static_is_a
      # The subject's static type already IS the tested type, so Ruby's guard
      # is decided at compile time: true when they match, false for a NIL
      # subject that can never be the type.
      lines[i] = lines[i].gsub(/(?<![\w.)])(#{RECV}|NIL)\s+IS_A\s+(\w+)/) do
        whole = Regexp.last_match(0)
        subject = Regexp.last_match(1)
        target = Regexp.last_match(2)
        rest = Regexp.last_match.post_match
        # `IS_A T AS x` binds the payload and `IS_A T@cap` carries a
        # capability: neither is a bare boolean test to fold away.
        next whole if rest =~ /\A\s*(?:AS\b|@)/

        if subject == 'NIL'
          counts[kind] += 1
          'FALSE'
        elsif target == name
          counts[kind] += 1
          'TRUE'
        else
          whole
        end
      end
    when :unwrap_is_a
      lines[i] = lines[i].gsub(/(?<![\w.)])(#{RECV})\s+IS_A\b/) do
        whole = Regexp.last_match(0)
        recv = Regexp.last_match(1)
        next whole if recv.start_with?('UNWRAP')

        counts[kind] += 1
        "UNWRAP (#{recv}) IS_A"
      end
    when :union_field_write
      lines[i] = lines[i].sub(/(?<![\w.)])((?:[a-z_]\w*(?:\.[a-z_]\w*)*))\.(\w+)\s*=\s*(.+?);\s*$/) do
        whole = Regexp.last_match(0)
        recv = Regexp.last_match(1)
        field = Regexp.last_match(2)
        value = Regexp.last_match(3)
        fn = "#{name[0].to_s.downcase}#{name[1..]}__set_#{field}_mut"
        next whole unless DEFINED.include?(fn)

        counts[kind] += 1
        "#{fn}(&#{recv}, #{value});"
      end
    when :union_field_read
      # The union has no field of that name; the generated accessor does.
      # Gating on the accessor's existence keeps a same-named field on some
      # other receiver on the line from being rewritten.
      # The receiver may be a path, a call, or an UNWRAP of either.
      recv_pat = /(?:UNWRAP\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)|[a-z_]\w*(?:__\w+)?\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)|[a-z_]\w*(?:\.[a-z_]\w*)*)/
      lines[i] = lines[i].gsub(/(?<![\w.)])(#{recv_pat})\.(\w+)\b/) do
        whole = Regexp.last_match(0)
        recv = Regexp.last_match(1)
        field = Regexp.last_match(2)
        rest = Regexp.last_match.post_match
        next whole if rest =~ /\A\s*[=(]/ && rest !~ /\A\s*==/

        fn = accessor_for(name, field)
        next whole unless fn

        counts[kind] += 1
        "#{fn}(#{recv})"
      end
    when :mutable_param
      # The body takes a RESTRICT view of the parameter, so the parameter
      # itself has to be declared MUTABLE.
      j = i
      while j >= 0
        if lines[j] =~ /^(PUB |PRIVATE )?FN /
          if lines[j] =~ /\(#{name}:/ || lines[j] =~ /,\s*#{name}:/
            lines[j] = lines[j].sub(/(?<=[(,] )#{name}:/, "MUTABLE #{name}:")
                               .sub(/\(#{name}:/, "(MUTABLE #{name}:")
            counts[kind] += 1
          end
          break
        end
        j -= 1
      end
    when :mutable_arg_line
      # The call spans lines, so the argument span could not be located; the
      # name still appears exactly once in argument position on this line.
      # Not after COPY/UNWRAP: `&` marks a mutating argument, and inside a
      # literal field or an unwrap it is a syntax error.
      pat = /(?<=[(,] )(?<!COPY )#{name}(?=\s*[,)])|(?<=\()(?<!COPY \()#{name}(?=\s*[,)])/
      at = lines[i].index(pat)
      # A lambda's USE(...) capture list is not an argument list; `&` there is
      # a syntax error.
      inside_use = at && lines[i][0...at].scan(/USE\(/).any? &&
                   lines[i][0...at].rpartition('USE(').last.count('(') >=
                   lines[i][0...at].rpartition('USE(').last.count(')')
      if lines[i].scan(pat).length == 1 && !inside_use
        lines[i] = lines[i].sub(pat, "&#{name}")
        counts[kind] += 1
      end
    when :stringify_interp
      # The diagnostic names the operand's type but not which operand it is,
      # so only an unambiguous line is rewritten: exactly one interpolation
      # that is not already stringified or unwrapped.
      bare_t = name.delete_prefix('?')
      helper_fn = "#{bare_t[0].to_s.downcase}#{bare_t[1..]}__to_s"
      # An operand already carrying .toString() is not finished when the type
      # has no such intrinsic: the earlier rule put it there, and the type's
      # own to_s is what Ruby called.
      # The diagnostic names the operand's type, not which operand it is, so
      # a line with several stringified operands is ambiguous -- the others
      # are ordinary Int64s whose toString is correct.
      stringified = lines[i].scan(/\$\{[a-z_]\w*(?:\.[a-z_]\w*)*\.toString\(\)\}/)
      if DEFINED.include?(helper_fn) && stringified.length == 1
        swapped = lines[i].gsub(/\$\{([a-z_]\w*(?:\.[a-z_]\w*)*)\.toString\(\)\}/) do
          counts[kind] += 1
          "${#{helper_fn}(#{Regexp.last_match(1)})}"
        end
        if swapped != lines[i]
          lines[i] = swapped
          next
        end
      end
      cands = lines[i].scan(/\$\{([^{}]+)\}/).flatten
                      .reject { |x| x.include?('.toString()') || x.include?('UNWRAP ') }
      if cands.length == 1
        inner = cands.first
        bare = name.delete_prefix('?')
        helper = "#{bare[0].to_s.downcase}#{bare[1..]}__to_s"
        repl = if name.start_with?('?')
                 "${UNWRAP (#{inner})}"
               elsif DEFINED.include?(helper)
                 # The type carries Ruby's to_s; toString has no overload for it.
                 "${#{helper}(#{inner})}"
               else
                 "${#{inner}.toString()}"
               end
        lines[i] = lines[i].sub("${#{inner}}", repl)
        counts[kind] += 1
      end
    when :orelse_bool
      # Ruby's truthiness on a nil-or-false value is exactly OR_ELSE FALSE.
      # Only operands that are provably optional are rewritten: a safe
      # navigation makes the expression optional outright, and a field name
      # qualifies when every struct declaring it declares it ?Bool. Wrapping a
      # plain Bool would just raise OR_ELSE_NEEDS_RECOVERABLE_LEFT instead.
      lines[i] = lines[i].gsub(/(?<![\w.)])([a-z_]\w*(?:\[[^\]]*\])?(?:\??\.[a-z_]\w*)+)(?=\s+(?:AND|OR)\b)/) do
        whole = Regexp.last_match(0)
        operand = Regexp.last_match(1)
        next whole unless operand.include?('?.') || BOOL_FIELD[operand.split('.').last]

        counts[kind] += 1
        "(#{operand} OR_ELSE FALSE)"
      end
    when :to_s_helper
      # The type has no toString intrinsic but carries Ruby's to_s as a
      # helper, which is the function Ruby called here.
      fn = "#{name[0].to_s.downcase}#{name[1..]}__to_s"
      if DEFINED.include?(fn)
        lines[i] = lines[i].gsub(/(?<![\w.])(#{RECV})\.toString\(\)/) do
          whole = Regexp.last_match(0)
          recv = Regexp.last_match(1)
          counts[kind] += 1
          "#{fn}(#{recv})"
        end
      end
    when :drop_or_else
      # OR_ELSE on a value that is neither fallible nor optional is dead: the
      # fallback can never be taken.
      # The fallback must be a complete simple value. `OR_ELSE CAST(...)` and
      # any other call would leave its argument list dangling.
      lines[i] = lines[i].sub(/\s+OR_ELSE\s+(?:\w+\[\]|\{\}|[\w:.]+(?![\w(]))/) do
        counts[kind] += 1
        ''
      end
    when :drop_unwrap
      # Two spellings reach the same diagnostic. Rewrite only when the line
      # offers exactly one candidate, so no guess is needed about which
      # subexpression the compiler meant.
      safe_nav = lines[i].scan(/\w\?\./).length
      unwraps = lines[i].scan(/\bUNWRAP\s*\(/).length
      if safe_nav == 1 && unwraps.zero?
        lines[i] = lines[i].sub(/(\w)\?\./) { "#{Regexp.last_match(1)}." }
        counts[kind] += 1
      elsif unwraps == 1 && safe_nav.zero?
        at = lines[i].index(/\bUNWRAP\s*\(/)
        open_at = lines[i].index('(', at)
        fin = close_paren(lines[i], open_at)
        if fin
          inner = lines[i][(open_at + 1)...fin].strip
          lines[i] = lines[i][0...at] + inner + lines[i][(fin + 1)..]
          counts[kind] += 1
        end
      end
    end
  end
  lines.each_with_index do |l, idx|
    next if l == original.lines[idx]

    edits << [offsets[idx], offsets[idx + 1] || original.length, l, :line_rule]
  end

  edits.uniq!
  edits.sort_by!(&:first)
  # Two diagnostics can name overlapping spans; applying both would splice one
  # replacement into the middle of the other.
  last_start = original.length
  applied = original.dup
  edits.reverse_each do |a, b, s, kind|
    next if b > last_start

    applied = applied[0...a] + s + applied[b..]
    last_start = a
    counts[kind] += 1 unless kind == :line_rule
  end
  File.write(path, applied) if apply
end


counts.sort_by { |_, v| -v }.each { |k, v| puts format('  %-16s %d', k, v) }
puts "total #{counts.values.sum}"
puts '(dry run -- pass --apply to write)' unless apply
