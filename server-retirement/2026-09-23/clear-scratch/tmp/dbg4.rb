$LOAD_PATH.unshift File.expand_path("compiler/ruby")
require "ast/lexer"
require "ast/parser"
require "annotator"
require "mir/cleanup_classifier"
src = File.read("/tmp/nb3.clear")
ast = ClearParser.new(Lexer.new(src).tokenize, src).parse
SemanticAnnotator.new(source_code: src).annotate!(ast)
pick = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "pick" }
puts "pick return_type=#{pick.return_type&.resolved} storage=#{pick.storage} heap_carry=#{pick.heap_carry_return.inspect}"
main = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
decl = main.body.first
ti = decl.type_object
e = CleanupClassifier.send(:classify_binding, ti, decl, ->(t) { nil }, nil) rescue "raised: #{$!.class}"
puts "classify_binding => #{e.inspect}"
