$LOAD_PATH.unshift File.expand_path("compiler/ruby")
require "ast/lexer"
require "ast/parser"
require "annotator"
src = File.read("/tmp/nb3.clear")
ast = ClearParser.new(Lexer.new(src).tokenize, src).parse
SemanticAnnotator.new(source_code: src).annotate!(ast)
seen = Hash.new(0)
AST.each_locatable(ast) { |n| seen[n.class.name.split("::").last] += 1 }
puts seen.inspect
