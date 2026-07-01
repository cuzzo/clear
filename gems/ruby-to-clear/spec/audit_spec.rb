# frozen_string_literal: true

require "tmpdir"

require "spec_helper"
require "ruby_to_clear/audit"

RSpec.describe RubyToClear::Audit do
  it "renders node, call, stdlib, and block roadmap data for a directory glob" do
    Dir.mktmpdir("ruby-to-clear-audit") do |dir|
      src_dir = File.join(dir, "src")
      Dir.mkdir(src_dir)
      File.write(
        File.join(src_dir, "sample.rb"),
        <<~RUBY
          require "set"

          values = Set.new([1, 2, 3])
          names = values.map { |value| value.to_s }
          File.read("input.txt")
          File.join("tmp", "input.txt")
          { a: 1 }.size
          "a:b".split(":")
        RUBY
      )

      files = described_class.files_for(root: dir, glob: "src/**/*.rb")
      audit = described_class.new(files, root: dir, top: 10)
      audit.run

      report = audit.render_markdown
      expect(report).to include("# Ruby to CLEAR Prism Audit")
      expect(report).to include("## Translation Coverage")
      expect(report).to include("useful LoC coverage")
      expect(report).to include("## Roadmap Suggestions")
      expect(report).to include("## Now-Unlocked Work")
      expect(report).to include("Safe Block Lowering Candidates")
      expect(report).to include("High-Confidence Stdlib Adapter Calls")
      expect(report).to include("Receiver-Shape Call Candidates")
      expect(report).to include("Ranked Next Work")
      expect(report).to include("CallNode")
      expect(report).to include("map")
      expect(report).to include("Set.new")
      expect(report).to include("File.read")
      expect(report).to include("File.join -> path.join")
      expect(report).to include("hash_literal.size")
      expect(report).to include("string_literal.split")
      expect(report).to include("BlockNode")
      expect(report).to include("src/sample.rb")
    end
  end

  it "reports parse errors and risky roadmap buckets without failing the audit" do
    Dir.mktmpdir("ruby-to-clear-audit") do |dir|
      src_dir = File.join(dir, "src")
      Dir.mkdir(src_dir)
      File.write(
        File.join(src_dir, "shapes.rb"),
        <<~RUBY
          T.nilable(String)
          send(:dynamic_name)
          @value.to_s
          @@count.to_s
          $stdout.puts("x")
          File::Stat.new("input.txt")
          (user).name
          "name".size
          :name.to_s
          1.to_s
          [1].map(&:to_s)
          { a: 1 }.size
          nil.to_s
          true.to_s
          false.to_s
          [1].each { next }
        RUBY
      )
      File.write(File.join(src_dir, "bad.rb"), "def")

      files = described_class.files_for(root: dir, glob: "src/**/*.rb")
      audit = described_class.new(files, root: dir, top: 20)
      audit.run

      report = audit.render_markdown
      expect(audit.parse_errors.size).to eq(1)
      expect(report).to include("- parse errors: 1")
      expect(report).to include("partial files:")
      expect(report).to include("Unsupported Nodes In Transpiler Output")
      expect(report).to include("send")
      expect(report).to include("Dynamic/Reflection Categories")
      expect(report).to include("Dynamic Blocker Guidance")
      expect(report).to include("dynamic dispatch")
      expect(report).to include("closed case/table")
      expect(report).to include("nilable")
      expect(report).to include("block_arg")
      expect(report).to include("NextNode")
      expect(report).to include("src/shapes.rb")
    end
  end
end
