# frozen_string_literal: true

# Make a WARM run report the same blockers a cold one does.
#
# The module cache stores a compiled unit, so a cache hit skips parsing,
# annotating and lowering it -- and therefore skips re-raising everything that
# unit got wrong. A warm run's "0 blockers" means "no new blockers in what
# recompiled", which is not the same claim and reads identically. That forced
# every authoritative measurement through a ~10 minute uncached run.
#
# A unit's diagnostics are a function of the same sources the cache is already
# keyed on, so they can be cached alongside it and replayed on a hit. The
# harness keeps them in its own sidecar rather than inside the unit record: the
# compiler must not start depending on a probe's accumulators.
require 'json'

module ProbeErrorReplay
  PATH = ENV['CLEAR_PROBE_REPLAY_FILE']
  STORE = T_STORE = (PATH && File.file?(PATH) ? JSON.parse(File.read(PATH)) : {})

  def self.save
    return unless PATH

    File.write(PATH, JSON.generate(STORE))
  end

  # A recorded CompilerError cannot be marshalled back into one, so the replay
  # keeps the shape the reporters actually read: message, line, column.
  Replayed = Struct.new(:message, :token) do
    def to_s = message
  end
  ReplayToken = Struct.new(:line, :column)

  def fetch(unit_key, member_paths, &block)
    ran = false
    before_a = ProbeMultiError::RECORDED.length
    before_b = defined?(ProbeLoweringSurvives) ? ProbeLoweringSurvives::RECORDED.length : 0

    result = super(unit_key, member_paths) do
      ran = true
      block.call
    end

    if ran
      STORE[unit_key] = {
        'annotate' => ProbeMultiError::RECORDED[before_a..].to_a.map do |e|
          tok = e.respond_to?(:token) ? e.token : nil
          { 'message' => e.message.to_s, 'line' => tok&.line, 'column' => tok&.column,
            'unit' => ProbeMultiError::UNITS[ProbeMultiError::RECORDED.index(e)] }
        end,
        'lower' => defined?(ProbeLoweringSurvives) ? ProbeLoweringSurvives::RECORDED[before_b..].to_a : [],
      }
    else
      stored = STORE[unit_key]
      if stored
        stored.fetch('annotate', []).each do |r|
          ProbeMultiError::RECORDED << Replayed.new(r['message'], ReplayToken.new(r['line'], r['column']))
          ProbeMultiError::UNITS << r['unit']
        end
        ProbeLoweringSurvives::RECORDED.concat(stored.fetch('lower', [])) if defined?(ProbeLoweringSurvives)
      end
    end
    result
  end
end

TracePoint.new(:end) do |klass|
  k = klass.self
  next unless k.is_a?(Class)
  own = k.instance_methods(false) + k.private_instance_methods(false)
  # Identify the cache by what it defines, not by its name.
  next unless own.include?(:fetch) && own.include?(:reuse)
  k.prepend(ProbeErrorReplay)
  klass.disable
end.enable

at_exit { ProbeErrorReplay.save }
