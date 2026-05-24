require_relative "../src/backends/transpiler"

# doc_spec.rb — Verify all ```clear code blocks in docs/ transpile successfully.
#
# Extracts fenced code blocks (```clear ... ```) from every .md file
# in docs/, wraps standalone snippets in a main function if needed,
# prepends common struct definitions, and checks that the transpiler
# doesn't raise.
#
# To mark a code block as illustrative (not expected to compile),
# add `# ILLUSTRATIVE` as the first line inside the block:
#
#   ```clear
#   # ILLUSTRATIVE
#   x |> WHERE _.value > threshold;
#   ```
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
  STRUCT Session { id: Int64 }
  STRUCT Vec2 { x: Float64, y: Float64 }
  STRUCT Point { x: Float64, y: Float64 }
  STRUCT Sensor { id: Int64, intensity: Float64 }
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
  return code if code.include?("FN ")

  lines = code.strip.lines.map(&:strip).reject { |l| l.start_with?("#") || l.empty? }
  return code if lines.all? { |l| l.start_with?("STRUCT", "ENUM", "UNION", "EXTERN", "FN ", "PUB ") }

  "FN main() RETURNS Void ->\n#{code}\nRETURN;\nEND"
end

def illustrative?(code)
  code.strip.lines.first&.strip&.start_with?("# ILLUSTRATIVE")
end

RSpec.describe "Documentation code examples" do
  doc_files = Dir.glob("docs/*.md").sort

  doc_files.each do |md_file|
    basename = File.basename(md_file)
    blocks = extract_clear_blocks(md_file)

    next if blocks.empty?

    describe basename do
      blocks.each_with_index do |block, idx|
        if illustrative?(block[:code])
          it "code block at line #{block[:line]} is illustrative (skipped)" do
            # Marked with # ILLUSTRATIVE
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
