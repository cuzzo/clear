# frozen_string_literal: true

require_relative "spec_helper"
require "set"
require "tmpdir"

# The value domain used to be Ruby, and correctness here is agreement with that
# Ruby rather than plausibility. The fixture is what it answered, in full and
# in the recorded order -- a collection's shape is remembered against the
# classes it was carrying, so a different order asks a different question.
#
# Regenerate with tools/record_value_domain.rb after a deliberate change; do
# not edit it by hand.
RSpec.describe "collector value domain", if: NativeCollector::AVAILABLE do
  def recorded
    @recorded ||= JSON.parse(
      File.read(File.expand_path("fixtures/value_domain.json", __dir__))
    )
  end

  def replay
    NilKillTraceNative.reset_value_domain
    full = recorded.fetch("cases").to_h { |row| [row.fetch("case"), row.fetch("domain")] }
    wrong = []
    ValueDomainCorpus.each_value do |label, value|
      # Compared as JSON so a recorded document and a live Hash with symbol
      # keys are the same thing.
      actual = JSON.parse(JSON.generate(NilKillTraceNative.value_domain(value)))
      wrong << [label, full.fetch(label), actual] unless full.fetch(label) == actual
    end
    wrong
  end

  it "answers every recorded case exactly as the Ruby it replaced did" do
    wrong = replay
    expect(wrong).to be_empty, lambda {
      wrong.first(3).map { |label, expected, actual|
        "#{label}\n  recorded: #{expected.inspect[0, 300]}\n  actual:   #{actual.inspect[0, 300]}"
      }.join("\n") + "\n(#{wrong.length} of #{recorded.fetch("cases").length} cases differ)"
    }
  end

  it "derives a domain without dispatching a method the traced program defined" do
    # Every reflective step the domain takes is answered by the interpreter
    # directly. If one of them dispatched instead, this override would be
    # reached and the collector would be running application code underneath
    # the event it is handling.
    hostile = Class.new do
      def self.name = raise("Module#name must not be dispatched")
      def ==(_other) = raise("== must not be dispatched")
      def <=>(_other) = raise("<=> must not be dispatched")
      def hash = raise("hash must not be dispatched")
      def to_s = raise("to_s must not be dispatched")
      def each = raise("each must not be dispatched")
      def class = raise("class must not be dispatched")
    end
    subject = [hostile.new, hostile.new]

    expect { NilKillTraceNative.value_domain(subject) }.not_to raise_error
    expect(NilKillTraceNative.value_domain(subject).fetch(:types)).to eq(["Array"])
  end

  it "keeps the observation and reports the source role beside it" do
    Dir.mktmpdir("nil-kill-source-role") do |dir|
      declaration = File.join(dir, "double.rb")
      File.write(declaration, "class ValueDomainSpecDouble; end\n")
      File.write(File.join(dir, "roles.json"), JSON.generate("nonproduction" => [declaration]))
      require declaration

      isolated_env("NIL_KILL_SOURCE_ROLES" => File.join(dir, "roles.json")) do
        NilKillTraceNative.reset_value_domain
        double = Object.const_get(:ValueDomainSpecDouble).new
        expect(NilKillTraceNative.value_domain(double).fetch(:nonproduction)).to be(true)
        # The double is filtered out of the element domain; the production
        # sibling it was carried with is not.
        expect(NilKillTraceNative.value_domain([double, "kept"]).fetch(:elements))
          .to eq(["String"])
      end
    end
  end

  # A class with no declaration site at all is not a class that was declared in
  # production code, and the evidence records that absence rather than guessing.
  it "reports an unknown source role as unknown, not as production" do
    NilKillTraceNative.reset_value_domain
    expect(NilKillTraceNative.value_domain(1).fetch(:nonproduction)).to be_nil
  end
end
