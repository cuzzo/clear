$LOAD_PATH.unshift File.expand_path("compiler/ruby")
require "ast/lexer"
require "ast/parser"
require "annotator"
require "mir/cleanup_classifier"
src = File.read("/tmp/nb3.clear")
ast = ClearParser.new(Lexer.new(src).tokenize, src).parse
SemanticAnnotator.new(source_code: src).annotate!(ast)
main = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
decl = main.body.first
ti = decl.type_object
sl = ->(t) { nil }
%w[classify_mutable_owning_slot classify_optional classify_owned_return_call classify_collection
   classify_array_struct_strings classify_rc_or_link classify_owned_string classify_heap_storage
   classify_heap_composite classify_struct_cleanup_fields classify_structural_product
   classify_non_copy_union].each do |m|
  begin
    r = case m
        when "classify_optional" then CleanupClassifier.send(m, ti, sl, node: decl)
        when "classify_collection" then CleanupClassifier.send(m, ti, sl, node: decl)
        when "classify_rc_or_link", "classify_structural_product", "classify_non_copy_union" then CleanupClassifier.send(m, ti, sl)
        when "classify_heap_storage", "classify_heap_composite" then CleanupClassifier.send(m, ti, decl, sl, nil)
        else CleanupClassifier.send(m, ti, decl, sl)
        end
    puts "#{m} => #{r.inspect}" if r
  rescue => e
    puts "#{m} raised #{e.class}"
  end
end
