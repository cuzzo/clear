require_relative '../src/ast/lexer'
require_relative '../src/ast/parser'
require_relative '../src/annotator'

# Extract ```clear code blocks from markdown files and verify they compile.
# Blocks containing "-- COMPILER ERROR" are expected to fail.
# Blocks containing "-- ILLUSTRATIVE" are skipped entirely.
# Blocks containing "-- SKIP-DOC-TEST" are skipped entirely.
#
# Each block is wrapped in FN main() if it doesn't define one,
# so standalone expressions/statements can be tested.

def extract_clear_blocks(file)
  content = File.read(file)
  blocks = []
  in_block = false
  current = []
  lang = nil
  is_illustrative = false

  content.each_line.with_index(1) do |line, lineno|
    if !in_block && line =~ /^```(?:ruby )?clear(\s+illustrative)?\s*$/
      in_block = true
      lang = 'clear'
      is_illustrative = !!$1
      current = []
    elsif in_block && line =~ /^```\s*$/
      in_block = false
      blocks << { code: current.join, start_line: lineno - current.size, file: file, illustrative: is_illustrative }
    elsif in_block
      current << line
    end
  end

  blocks
end

def wrap_in_main(code)
  # If code already defines FN main, use as-is
  return code if code.include?("FN main(")

  # Wrap standalone statements in a main function
  # Filter out lines that would cause issues as standalone statements
  lines = code.lines.reject { |l| l.strip.start_with?("--") && l.strip == "--" }
  "FN main() RETURNS Void ->\n#{code}\n    RETURN;\nEND\n"
end

def try_compile(code)
  tokens = Lexer.new(code).tokenize
  ast = Parser.new(tokens, code).parse
  annotator = SemanticAnnotator.new
  annotator.annotate!(ast)
  true
rescue => e
  e.message
end

DOC_FILES = %w[
  WALKTHROUGH.md
  README.md
]

RSpec.describe "Documentation code examples" do
  DOC_FILES.each do |file|
    next unless File.exist?(file)

    describe file do
      blocks = extract_clear_blocks(file)

      blocks.each_with_index do |block, idx|
        code = block[:code]
        line = block[:start_line]

        # Skip illustrative blocks (marked via fence: ```ruby clear illustrative)
        next if block[:illustrative]

        # Skip blocks that are clearly not CLEAR code (bash commands, etc.)
        next if code.strip.start_with?("$") || code.strip.start_with?("#")
        next if code.include?("bundle ") || code.include?("./clear ") || code.include?("ruby ")
        next if code.include?("redis-benchmark") || code.include?("zig build")

        expects_error = code.include?("-- COMPILER ERROR")

        if expects_error
          it "#{file}:#{line} (block #{idx + 1}) expects compiler error" do
            wrapped = wrap_in_main(code)
            result = try_compile(wrapped)
            expect(result).not_to eq(true),
              "Expected compiler error but code compiled successfully:\n#{code}"
          end
        else
          it "#{file}:#{line} (block #{idx + 1}) compiles without error" do
            wrapped = wrap_in_main(code)
            result = try_compile(wrapped)
            expect(result).to eq(true),
              "Expected code to compile but got error:\n#{result}\n\nCode:\n#{code}"
          end
        end
      end
    end
  end
end
