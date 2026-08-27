#!/usr/bin/env ruby
# frozen_string_literal: true

# Fallibility propagation across the generated tree.
#
# Ruby raises from anywhere, so a Ruby method never declares that it can fail.
# CLEAR does: a function reaching a fallible callee must declare `RETURNS !T`
# and every caller must TRY it. rtoc gets the leaves right and then stops, so
# the obligation stalls partway up each call chain -- and the compiler reports
# exactly one stalled function per package build.
#
# This closes the whole chain at once: mark every function that RAISEs or calls
# a fallible one, TRY those calls, and repeat until nothing changes.
#
#   ruby tools/selfhost_fallibility.rb [--fix] [--root DIR]
require 'optparse'
require 'set'

module SelfhostFallibility
  extend self

  DECL = /^(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\(/.freeze

  # A call already covered by TRY or OR_ELSE has its error handled.
  def call_covered?(line, at)
    prefix = line[0...at]
    return true if prefix.end_with?('TRY (') || prefix =~ /TRY \(\s*\z/
    return true if prefix.end_with?('(TRY (')

    # `callee(...) OR_ELSE ...` handles the error at the call itself.
    rest = line[at..]
    close = matching_paren(rest, rest.index('('))
    close ? rest[(close + 1)..].to_s.lstrip.start_with?('OR_ELSE') : false
  end

  # Parens inside a string literal are text, not structure: a call carrying
  # `")"` as an argument closed at the wrong place and mangled the parser.
  def matching_paren(text, open)
    return nil unless open

    depth = 0
    in_string = false
    i = open
    while i < text.length
      char = text[i]
      if in_string
        i += 2 and next if char == '\\'

        in_string = false if char == '"'
        i += 1
        next
      end
      case char
      when '"' then in_string = true
      when '(' then depth += 1
      when ')'
        depth -= 1
        return i if depth.zero?
      end
      i += 1
    end
    nil
  end

  # Wrap every uncovered call to a now-fallible callee on this line.
  def wrap_calls(line, fallible, owner)
    result = line.dup
    searched = 0
    loop do
      hit = nil
      result[searched..].to_s.scan(/(?<![\w.])([\w?!]+)\(/) do
        callee = Regexp.last_match(1)
        at = searched + Regexp.last_match.begin(0)
        next unless fallible.include?(callee) && callee != owner
        next if call_covered?(result, at)

        hit = [callee, at]
        break
      end
      return result unless hit

      callee, at = hit
      open = at + callee.length
      close = matching_paren(result, open)
      return result unless close

      # A chain hanging off the call needs the TRY parenthesized, or the
      # method reads the fallible value as its receiver.
      chained = result[close + 1] == '.'
      wrapped = chained ? "(TRY (#{result[at..close]}))" : "TRY (#{result[at..close]})"
      result = "#{result[0...at]}#{wrapped}#{result[(close + 1)..]}"
      searched = at + wrapped.length - (close - at + 1) + callee.length
    end
  end

  def function_spans(lines)
    starts = []
    lines.each_with_index do |line, index|
      next unless (match = DECL.match(line))

      starts << [index, match[1]]
    end
    starts.each_with_index.map do |(index, name), position|
      finish = position + 1 < starts.length ? starts[position + 1][0] : lines.length
      [name, index, finish]
    end
  end

  # The declaration's `RETURNS` may sit on the opening line or a later one.
  def returns_line(lines, start, finish)
    (start...finish).find { |i| lines[i] =~ /RETURNS / }
  end

  def fallible_decl?(lines, index)
    lines[index] =~ /RETURNS !/
  end

  def load_tree(root)
    Dir.glob(File.join(root, '**', '*.clear')).sort.to_h { |path| [path, File.readlines(path)] }
  end

  def collect(files)
    fallible = Set.new
    spans = {}
    files.each do |path, lines|
      function_spans(lines).each do |name, start, finish|
        ret = returns_line(lines, start, finish)
        next unless ret

        spans[[path, name]] = [start, finish, ret]
        fallible << name if fallible_decl?(lines, ret)
      end
    end
    [fallible, spans]
  end

  def main(argv)
    root = File.expand_path('compiler/src', __dir__ + '/..')
    fix = false
    OptionParser.new do |parser|
      parser.on('--root DIR') { |v| root = File.expand_path(v) }
      parser.on('--fix', 'Declare and TRY the whole chain') { fix = true }
    end.parse!(argv)

    files = load_tree(root)
    promoted = []
    tried = 0
    loop do
      fallible, spans = collect(files)
      changed = false
      spans.each do |(path, name), (start, finish, ret)|
        lines = files[path]
        body = lines[start...finish]
        next if fallible_decl?(lines, ret)

        raises = body.any? { |l| l =~ /(?<![\w])RAISE(?![\w])/ }
        calls = body.any? do |l|
          l.enum_for(:scan, /(?<![\w.])([\w?!]+)\(/).any? do
            callee = Regexp.last_match(1)
            fallible.include?(callee) && callee != name && !call_covered?(l, Regexp.last_match.begin(0))
          end
        end
        next unless raises || calls

        lines[ret] = lines[ret].sub(/RETURNS ([^!\s])/, 'RETURNS !\1')
        promoted << "#{path.sub("#{root}/", '')}:#{ret + 1} #{name}"
        changed = true
      end

      # Every call to a fallible callee needs its error handled at the site.
      files.each do |path, lines|
        function_spans(lines).each do |owner, start, finish|
          (start...finish).each do |i|
            next if lines[i] =~ DECL

            updated = wrap_calls(lines[i], fallible, owner)
            next if updated == lines[i]

            lines[i] = updated
            tried += 1
            changed = true
          end
        end
      end
      break unless changed
    end

    if promoted.empty?
      puts 'selfhost_fallibility: every chain already declares its errors'
      return 0
    end
    promoted.first(15).each { |entry| puts "  #{entry}" }
    puts "selfhost_fallibility: #{promoted.length} function(s) must declare `!`"
    return 1 unless fix

    files.each { |path, lines| File.write(path, lines.join) }
    puts "selfhost_fallibility: rewrote #{files.keys.length} file(s); #{tried} call site(s) wrapped"
    0
  end
end

exit(SelfhostFallibility.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_fallibility.rb')
