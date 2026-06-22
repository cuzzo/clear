require_relative "lib/decomplex"
require "benchmark"

files = ["lib/decomplex/ast.rb"]
detectors = Decomplex::DetectorRunner::DETECTORS.keys

Benchmark.bm(40) do |x|
  detectors.each do |det|
    x.report("#{det} (ruby)") do
      Decomplex::DetectorRunner.run(det, files, engine: "ruby")
    end
    x.report("#{det} (rust)") do
      Decomplex::DetectorRunner.run(det, files, engine: "rust")
    end
  end
end
