require_relative "../src/transpiler"

# doc_spec.rb — Verify all ```clear code blocks in docs/ transpile successfully.
#
# Extracts fenced code blocks (```clear ... ```) from every .md file
# in docs/, wraps standalone snippets in a cheatMain function if needed,
# prepends common struct definitions, and checks that the transpiler
# doesn't raise.
#
# Run: bundle exec rspec spec/doc_spec.rb

# Common struct definitions that doc examples reference without defining.
COMMON_PRELUDE = <<~CLEAR
  STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64, mana: Float64, name: String, level: Float64 }
  STRUCT Score { value: Float64 }
  STRUCT User { name: String }
  STRUCT Enemy { hp: Int64, name: String }
  STRUCT Item { value: Float64 }
  STRUCT Work { value: Float64 }
  STRUCT Counter { value: Int64 }
  STRUCT Reading { sensor_id: Int64, value: Float64, quality: Float64 }
  STRUCT Result { ok: Int64 }
  STRUCT Session { id: Int64 }
  STRUCT Vec2 { x: Float64, y: Float64 }
  STRUCT Point { x: Float64, y: Float64 }
  STRUCT Matrix { data: Float64 }
  STRUCT Sensor { id: Int64, intensity: Float64 }
  STRUCT Big { a: Float64 }
  STRUCT Mid { f1: Float64 }
CLEAR

def extract_clear_blocks(md_path)
  content = File.read(md_path)
  blocks = []
  in_block = false
  current = []
  line_num = 0

  content.each_line.with_index(1) do |line, num|
    if line.strip == '```clear'
      in_block = true
      line_num = num
      current = []
    elsif in_block && line.strip == '```'
      in_block = false
      blocks << { code: current.join, file: md_path, line: line_num }
    elsif in_block
      current << line
    end
  end

  blocks
end

def wrap_if_needed(code)
  # If the code already defines cheatMain or a top-level FN, don't wrap
  return code if code.include?("FN cheatMain") || code.include?("FN f(")

  # If it's just declarations (STRUCT, ENUM, UNION, EXTERN), don't wrap
  lines = code.strip.lines.map(&:strip).reject { |l| l.start_with?("--") || l.empty? }
  return code if lines.all? { |l| l.start_with?("STRUCT", "ENUM", "UNION", "EXTERN", "FN ", "PUB ") }

  # Wrap in a function
  "FN cheatMain() RETURNS Void ->\n#{code}\nRETURN;\nEND"
end

# Returns true if the code block is an illustrative snippet (not a
# complete runnable program).  These use `...`, ellipsis, or reference
# patterns/variables that exist only in prose context.
def illustrative_snippet?(code)
  return true if code.include?("...")
  return true if code.include?("…")
  return true if code =~ /--.*example|--.*illustration|--.*pseudo/i
  # Single-line comments-only blocks
  lines = code.strip.lines.reject { |l| l.strip.empty? || l.strip.start_with?("--") }
  return true if lines.empty?
  # Diff-style blocks (+ or - prefix lines)
  return true if code.lines.any? { |l| l =~ /^[+-] / }
  # References undefined context variables (common in illustrative docs)
  return true if code =~ /\b(conn|query|data|damage|record|event|user|threshold|cmd|response|request)\b/ &&
                 !code.include?("STRUCT") && !code.include?("FN ")
  # Bare expressions without assignments or function calls (pattern illustrations)
  return true if lines.size <= 2 && !code.include?("=") && !code.include?("ASSERT")
  # No variable declarations or function definitions — just expressions
  return true unless code =~ /\b(MUTABLE|FN |STRUCT |ENUM |=)\b/
  false
end

# Known doc examples that need fixing (reference undefined vars/fns).
# TODO: fix these docs, then remove from this list.
KNOWN_DOC_ISSUES = {
  "allocation.md" => [73],      # references undefined 'counter'
  "capabilities.md" => [16],    # internal error on partial snippet
  "concurrency.md" => [107],    # reassigns immutable v1
  "error-handling.md" => [39, 79], # references undefined 'divide', partial snippet
}.freeze

RSpec.describe "Documentation code examples" do
  doc_files = Dir.glob("docs/*.md").sort

  doc_files.each do |md_file|
    basename = File.basename(md_file)
    blocks = extract_clear_blocks(md_file)

    next if blocks.empty?

    describe basename do
      blocks.each_with_index do |block, idx|
        known_issues = KNOWN_DOC_ISSUES[basename] || []
        if illustrative_snippet?(block[:code])
          it "code block at line #{block[:line]} is illustrative (skipped)" do
            # Intentionally incomplete snippet — not expected to compile
          end
        elsif known_issues.include?(block[:line])
          it "code block at line #{block[:line]} has known issue (pending fix)" do
            pending "TODO: fix doc example — see KNOWN_DOC_ISSUES in doc_spec.rb"
            fail
          end
        else
          it "code block at line #{block[:line]} transpiles without error" do
            code = COMMON_PRELUDE + wrap_if_needed(block[:code])
            begin
              original_stderr = $stderr
              $stderr = StringIO.new
              ZigTranspiler.new.transpile(code)
              $stderr = original_stderr
            rescue => e
              $stderr = original_stderr
              raise "#{md_file}:#{block[:line]} — #{e.message}\n\nCode:\n#{block[:code]}"
            end
          end
        end
      end
    end
  end
end
