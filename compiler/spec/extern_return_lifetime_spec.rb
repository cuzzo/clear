require "rspec"
require_relative "../ruby/backends/transpiler"

RSpec.describe "EXTERN borrowed return lifetimes" do
  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  def annotate(source)
    program = parse(source)
    SemanticAnnotator.new.annotate!(program)
    program
  end

  it "registers a return view tied to an EXTERN parameter" do
    program = annotate(<<~CLEAR)
      EXTERN STRUCT Scanner {} FROM "scanner";
      EXTERN FN peek(scanner: Scanner) RETURNS scanner:?String FROM "scanner";
      FN inspect(scanner: Scanner) RETURNS Void -> peek(scanner); END
    CLEAR

    declaration = program.statements.grep(AST::ExternFnDecl).last
    expect(declaration.return_lifetime.map(&:name)).to eq(["scanner"])
  end

  it "rejects a lifetime root that is not an EXTERN parameter" do
    expect do
      annotate(<<~CLEAR)
        EXTERN STRUCT Scanner {} FROM "scanner";
        EXTERN FN peek(scanner: Scanner) RETURNS ghost:String FROM "scanner";
      CLEAR
    end.to raise_error(CompilerError, /Lifetime Error.*ghost.*not a parameter/i)
  end

  it "materializes a borrowed EXTERN view before returning it as owned" do
    zig = ZigTranspiler.new.transpile(<<~CLEAR)
      EXTERN STRUCT Scanner {} FROM "scanner";
      EXTERN FN peek(scanner: Scanner) RETURNS scanner:String FROM "scanner";
      FN escape(scanner: Scanner) RETURNS String -> RETURN peek(scanner); END
    CLEAR

    expect(zig).to match(/heapAlloc\(\)\.dupe\(u8, .*scanner\.peek/m)
  end

  it "allows an explicit COPY to detach the view from the EXTERN argument" do
    expect do
      annotate(<<~CLEAR)
        EXTERN STRUCT Scanner {} FROM "scanner";
        EXTERN FN peek(scanner: Scanner) RETURNS scanner:String FROM "scanner";
        FN detach(scanner: Scanner) RETURNS String -> RETURN COPY peek(scanner); END
      CLEAR
    end.not_to raise_error
  end
end
