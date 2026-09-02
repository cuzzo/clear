#!/usr/bin/env ruby
# frozen_string_literal: true

# Find CLEAR parameters that lost the default Ruby declares.
#
# The third shape of the same defect: rtoc infers signatures from usage while
# Ruby declares them. A dropped default leaves a required parameter -- often
# positioned after optional ones -- and every caller that omits it fails
# ARGUMENT_TYPE_ERROR, one diagnostic per call site.
require 'set'

RUBY_ROOT = File.expand_path('../compiler/ruby', __dir__)
CLEAR_ROOT = File.expand_path('../compiler/src', __dir__)

# Ruby positional/keyword parameters that carry a default.
ruby_defaults = Hash.new { |h, k| h[k] = {} }
Dir.glob("#{RUBY_ROOT}/**/*.rb").each do |f|
  cls = nil
  File.readlines(f).each do |l|
    cls = Regexp.last_match(1) if l =~ /^\s*class (\w+)/
    next unless cls && l =~ /^\s*def (?:self\.)?([\w?!]+)\((.*)\)/

    meth = Regexp.last_match(1)
    Regexp.last_match(2).split(/,(?![^(\[{]*[)\]}])/).each do |p|
      next unless p =~ /\A\s*_?(\w+):?\s*=\s*(.+)\z/

      ruby_defaults["#{cls}##{meth}"][Regexp.last_match(1)] = Regexp.last_match(2).strip
    end
  end
end

def clear_recv(cls) = "#{cls[0].downcase}#{cls[1..]}"

rows = []
Dir.glob("#{CLEAR_ROOT}/**/*.clear").each do |f|
  File.read(f).scan(/^(?:PUB |PRIVATE )?FN (\w+)__([\w?!]+)\(([^\n]*?)\)\s*RETURNS/) do |recv, meth, params|
    key = ruby_defaults.keys.find { |k| clear_recv(k.split('#').first) == recv && k.split('#').last == meth }
    next unless key

    params.split(/,\s*(?=(?:MUTABLE\s+)?\w+:)/).each do |p|
      m = p.match(/\A\s*(?:MUTABLE\s+)?(\w+):\s*([^=]+)\z/) or next # no `=` means no default

      pname = m[1]
      rbd = ruby_defaults[key].keys.find { |k| k == pname || "ignored_#{k}" == pname || pname.end_with?(k) }
      next unless rbd

      rows << [f.sub("#{CLEAR_ROOT}/", ''), "#{recv}__#{meth}", pname, m[2].strip, ruby_defaults[key][rbd][0, 22]]
    end
  end
end

puts "#{rows.length} parameter(s) missing the default Ruby declares:"
rows.first(25).each { |_, fn, p, ct, rbd| puts format('  %-44s %-22s %-20s ruby = %s', fn, p, ct, rbd) }
