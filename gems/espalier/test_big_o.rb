require_relative "lib/espalier/big_o_analyzer"
require "yaml"

nil_kill_evidence = {
  "10" => { "items" => "Array" },
  "12" => { "names" => "String" }
}

analyzer = Espalier::BigOAnalyzer.new(language: :ruby, nil_kill_evidence: nil_kill_evidence)

ast_mock = [
  { type: :call, receiver: "items", method: "sort", line: 10 },
  { type: :loop, line: 11 },
  { type: :call, receiver: "unknown_obj", method: "process", line: 12 },
  { type: :callback, line: 15 }
]

result = analyzer.analyze_method("build_graph", ast_mock)
puts result.to_yaml
