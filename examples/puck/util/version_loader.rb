require 'stringio'

module Puck
  # Loads one of the tutorial versions (v1-v7).
  #
  # Each version's Ruby files live in examples/puck/<version>/. We Kernel.load
  # the version's entry point, which defines Tokenizer / Parser / Compiler / VM
  # (and, for v7, MacroExpander) at the top level. Callers that want to USE
  # those classes simply reference them after this call.
  #
  # We never edit v*/*.rb on disk. Anything that needs to observe the tokenizer
  # or compiler from the outside (compile.rb) attaches TracePoints in
  # util/instrumenter.rb at runtime; the source files stay clean.
  module VersionLoader
    VERSIONS = %w[v1 v2 v3 v4 v5 v6 v7].freeze

    # Returns the source text for `version`. After this returns, top-level
    # Tokenizer/Parser/Compiler/VM constants reflect the requested version.
    def self.load_version(version, source_path = nil)
      raise "Unknown version: #{version}" unless VERSIONS.include?(version)

      base = File.expand_path("..", __dir__)
      source = File.read(source_path || File.join(base, version, "example.puck"))
      entry = File.join(base, version, version == "v1" ? "puck.rb" : "vm.rb")

      silence_stdout { Kernel.load(entry) }
      source
    end

    # Loading some versions causes their `if __FILE__ == $PROGRAM_NAME` blocks
    # to print to stdout. Swallow that during load so the visualizer's redraw
    # isn't polluted.
    def self.silence_stdout
      old_stdout = $stdout
      $stdout = StringIO.new
      yield
    ensure
      $stdout = old_stdout
    end
  end
end
