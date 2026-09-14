#!/usr/bin/env ruby
# frozen_string_literal: true

# Gate: `x == NIL` where x cannot be nil.
#
# Ruby is happy to write a defensive `return nil if v.nil?` on a value its own
# sig types as non-nilable -- the branch is simply dead. rtoc translates it
# literally and CLEAR rejects the impossible comparison with TYPE_ERROR_GENERIC,
# ~50 minutes into a 2b round.
#
# Only judged where the binding's type is KNOWN: `MUTABLE x = callee(...)` whose
# callee has a declared non-optional RETURNS. Anything inferred is left alone --
# guessing types here is how a gate starts crying wolf.
root = File.expand_path('../compiler/src', __dir__)

returns = {}
Dir.glob("#{root}/**/*.clear").sort.each do |path|
  File.readlines(path).each do |line|
    m = /^(?:PUB |PRIVATE )?FN\s+(\w+)(?:<[^>]*>)?\(.*\)\s*RETURNS\s+([^\s]+)/.match(line) or next

    returns[m[1]] = m[2]
  end
end

# A return type that can hold NIL: optional, or a very short name that is almost
# certainly a bare type parameter (T, U, E).
#
# LIMITATION: a longer generic like RESULT is treated as NON-nilable. That is
# what catches the real case -- with_fsm_segment_lowering_context RETURNS
# RESULT, and the lambda binds it to []Emittable -- but a RESULT that bound to
# an optional somewhere would be a false positive. Resolving it properly needs
# the binding inferred from the lambda, which is the compiler's job. The corpus
# is clean under this rule today; revisit if it starts crying wolf.
def nilable?(type)
  return true if type.nil?

  t = type.sub(/\A!/, '')
  t.start_with?('?') || t.length <= 2
end

bad = []
Dir.glob("#{root}/**/*.clear").sort.each do |path|
  lines = File.readlines(path)
  # name -> declared-non-optional, for locals bound directly from a call.
  # RESET at every function boundary: a file-global map matched a `value` bound
  # in one function against a `value == NIL` 2700 lines away in another, which
  # is 32 false positives and no real ones.
  bound = {}
  lines.each_with_index do |line, idx|
    bound = {} if line =~ /^(?:PUB |PRIVATE )?FN\s/

    if (m = /MUTABLE\s+(\w+)\s*=\s*(?:TRY\s*\()?\s*(\w+)\(/.match(line))
      rt = returns[m[2]]
      bound[m[1]] = [m[2], rt, idx + 1] if rt && !nilable?(rt)
    end
    line.scan(/\(?\s*(\w+)\s*==\s*NIL/) do
      name = Regexp.last_match(1)
      info = bound[name] or next

      callee, rt, decl = info
      bad << [path.sub("#{root}/", ''), idx + 1, name, callee, rt, decl]
    end
  end
end

if bad.empty?
  puts 'nil-compare gate: clean'
else
  bad.uniq.each do |f, l, name, callee, rt, decl|
    puts "#{f}:#{l}: `#{name} == NIL` but #{name} is bound at :#{decl} from #{callee}, which RETURNS #{rt}"
  end
  puts "nil-compare gate: #{bad.uniq.size} site(s)"
end
exit(bad.empty? ? 0 : 1)
