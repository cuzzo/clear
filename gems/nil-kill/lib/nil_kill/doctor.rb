# typed: false
# frozen_string_literal: true

module NilKill
  class Doctor
    def run
      puts "ruby: #{RUBY_VERSION}"
      puts "ruby parser: #{Syntax::VERSION}"
      puts "targets: #{NilKill.target_dirs.map { |d| NilKill.rel(d) }.join(File::PATH_SEPARATOR)}"
      puts "excluded targets: #{NilKill.target_exclude_dirs.map { |d| NilKill.rel(d) }.join(File::PATH_SEPARATOR)}" unless NilKill.target_exclude_dirs.empty?
      puts "runtime traces: #{Dir.glob(File.join(RUNTIME_DIR, "*.jsonl")).size}"
      puts "sorbet: #{command_ok?(%w[bundle exec srb --version])}"
      puts "tapioca: #{command_ok?(%w[bundle exec tapioca --version])}"
      puts "rbs-trace: #{gem_ok?("rbs/trace") || gem_ok?("rbs-trace")}"
      puts "parlour: #{gem_ok?("parlour")}"
    end

    def command_ok?(cmd)
      _out, _err, status = Open3.capture3(*cmd)
      status.success? ? "ok" : "missing/error"
    end

    def gem_ok?(feature)
      require feature
      "ok"
    rescue LoadError
      nil
    end
  end
end
