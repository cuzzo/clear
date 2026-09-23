$LOAD_PATH.unshift File.expand_path("compiler/ruby")
require "ast/lexer"
require "ast/parser"
require "annotator"
[["/tmp/nb3.clear", "?String"], ["/tmp/nb6.clear", "String"]].each do |file, label|
  src = File.read(file)
  ast = ClearParser.new(Lexer.new(src).tokenize, src).parse
  SemanticAnnotator.new(source_code: src).annotate!(ast)
  main = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
  decl = main.body.first
  sym = decl.symbol
  puts "#{label}: sym.storage=#{sym&.storage} sym.rodata=#{sym&.rodata_provenance?} node.storage=#{decl.storage} value.storage=#{decl.value.respond_to?(:storage) ? decl.value.storage : '-'} value.rodata=#{decl.value.respond_to?(:rodata_provenance?) ? decl.value.rodata_provenance? : '-'}"
end
