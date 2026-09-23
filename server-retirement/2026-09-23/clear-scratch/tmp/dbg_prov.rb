$LOAD_PATH.unshift File.expand_path("compiler/ruby")
require "ast/lexer"
require "ast/parser"
require "annotator"
src = File.read("/tmp/nb3.clear")
ast = ClearParser.new(Lexer.new(src).tokenize, src).parse
SemanticAnnotator.new(source_code: src).annotate!(ast)
AST.each_locatable(ast) do |n|
  next unless n.class.name.to_s =~ /VarDecl|Assignment|BindExpr/
  name = n.respond_to?(:name) ? n.name : nil
  ti = n.type_object
  puts "decl #{name}: type=#{ti&.resolved} optional=#{ti&.optional?} string?=#{ti&.string?} rodata_prov=#{n.rodata_provenance?} storage=#{n.storage} sym_storage=#{n.symbol&.storage} sym_rodata=#{n.symbol&.rodata_provenance?}"
end
