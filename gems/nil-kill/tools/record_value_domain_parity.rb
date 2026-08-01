# frozen_string_literal: true

# Writes the (raw observation -> value domain) pairs the Rust derivation is
# held to.
#
# The collector's C answers are the oracle: whatever it derives today is what
# the port has to keep deriving. Recording the raw observation beside it means
# the port can be developed and proved before any shim changes, against exactly
# the corpus the C implementation is already held to.
#
#   bundle exec ruby gems/nil-kill/tools/record_value_domain_parity.rb

require "json"
require "set"

EXT = File.expand_path("../ext/nil_kill_trace", __dir__)
$LOAD_PATH.unshift(EXT) unless $LOAD_PATH.include?(EXT)
require "nil_kill_trace"
require_relative "../lib/nil_kill"
require_relative "../spec/support/value_domain_corpus"

NilKillTraceNative.value_domain_root = NilKill::ROOT
NilKillTraceNative.reset_value_domain

# The corpus is one ordered sequence because a collection's shape is remembered
# against the classes it was carrying, so a later answer depends on the earlier
# ones. The raw observation is taken first: asking for the domain populates the
# shape memo, and the port has to build that memo itself from the same input.
# Source paths are recorded relative to the root, and a path outside it becomes
# a placeholder, so the fixture describes the corpus rather than the machine and
# the Ruby install that recorded it. Only one question is ever asked of a source
# path -- is it listed non-production -- and no path outside the project is.
def portable_source(path)
  return path.delete_prefix("#{NilKill::ROOT}/") if path.start_with?("#{NilKill::ROOT}/")

  "<external>"
end

def relativize(node)
  case node
  when Hash
    node.to_h do |key, value|
      next [key, portable_source(value)] if key == "source" && value.is_a?(String)

      [key, relativize(value)]
    end
  when Array then node.map { |entry| relativize(entry) }
  else node
  end
end

pairs = ValueDomainCorpus.each_value.map do |label, value|
  raw = relativize(JSON.parse(JSON.generate(NilKillTraceNative.raw_observation(value))))
  {
    "case" => label,
    "raw" => raw,
    "domain" => JSON.parse(JSON.generate(NilKillTraceNative.value_domain(value))),
  }
end

# One pair per line. Pretty-printing 647 of these was 142,000 lines of JSON,
# where re-recording one case buried it in a diff nobody could read.
path = File.expand_path("../spec/fixtures/value_domain_parity.jsonl", __dir__)
File.write(path, pairs.map { |pair| JSON.generate(pair) + "\n" }.join)
puts "recorded #{pairs.length} raw/domain pairs to #{path}"
