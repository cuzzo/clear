# frozen_string_literal: true

# Injected via RUBYOPT=-r.../stackprof_shim.rb to profile an arbitrary Ruby
# process. Starts StackProf immediately and dumps to STACKPROF_OUT at exit.
# The shim's at_exit registers before the workload's (e.g. Minitest autorun),
# so it runs after the workload finishes.

require "stackprof"

StackProf.start(
  mode: (ENV["STACKPROF_MODE"] || "cpu").to_sym,
  interval: (ENV["STACKPROF_INTERVAL"] || "1000").to_i,
  raw: false
)

at_exit do
  StackProf.stop
  StackProf.results(ENV.fetch("STACKPROF_OUT", "tmp/stackprof.dump"))
end
