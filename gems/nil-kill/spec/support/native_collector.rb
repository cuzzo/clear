# frozen_string_literal: true

# The collector is loaded straight out of ext/ so specs run against the object
# that was just built, with no gemspec or install step in between.
module NativeCollector
  EXT = File.expand_path("../../ext/nil_kill_trace", __dir__)
  AVAILABLE = File.exist?(File.join(EXT, "nil_kill_trace.so"))

  if AVAILABLE
    $LOAD_PATH.unshift(EXT) unless $LOAD_PATH.include?(EXT)
    require "nil_kill_trace"
    NilKillTraceNative.value_domain_root = NilKill::ROOT
  end
end
