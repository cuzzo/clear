# frozen_string_literal: true

# Rewrites spec/fixtures/value_domain.json from the collector's current
# answers. Run this only when a change to the value domain is intended: the
# fixture exists to make an unintended change fail.
#
#   bundle exec ruby gems/nil-kill/tools/record_value_domain.rb

require "json"
require "set"

EXT = File.expand_path("../ext/nil_kill_trace", __dir__)
$LOAD_PATH.unshift(EXT) unless $LOAD_PATH.include?(EXT)
require "nil_kill_trace"
require_relative "../lib/nil_kill"
require_relative "../spec/support/value_domain_corpus"

NilKillTraceNative.value_domain_root = NilKill::ROOT
NilKillTraceNative.reset_value_domain

cases = ValueDomainCorpus.each_value.map do |label, value|
  { "case" => label,
    "domain" => JSON.parse(JSON.generate(NilKillTraceNative.value_domain(value))) }
end

path = File.expand_path("../spec/fixtures/value_domain.json", __dir__)
File.write(path, JSON.pretty_generate("cases" => cases) + "\n")
puts "recorded #{cases.length} cases to #{path}"
