$LOAD_PATH.unshift File.expand_path("compiler/ruby")
require "ast/lexer"
require "ast/parser"
require "annotator"
src = File.read("/tmp/nb3.clear")
ast = ClearParser.new(Lexer.new(src).tokenize, src).parse
SemanticAnnotator.new(source_code: src).annotate!(ast)
main = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
main.body.each do |n|
  ti = n.respond_to?(:type_object) ? n.type_object : nil
  puts "#{n.class.name.split('::').last} name=#{n.respond_to?(:name) ? n.name : '-'} " \
       "type=#{ti&.resolved} opt=#{ti&.optional?} str=#{ti&.string?} " \
       "rodata_prov=#{n.respond_to?(:rodata_provenance?) ? n.rodata_provenance? : '-'} " \
       "storage=#{n.respond_to?(:storage) ? n.storage : '-'} " \
       "sym_storage=#{(n.respond_to?(:symbol) && n.symbol) ? n.symbol.storage : '-'} " \
       "sym_rodata=#{(n.respond_to?(:symbol) && n.symbol) ? n.symbol.rodata_provenance? : '-'}"
end
