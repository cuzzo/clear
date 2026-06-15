# typed: false
# frozen_string_literal: true

module AutoType
  class GuardedAutocorrect
    BOGUS_AUTOCORRECT_PATTERNS = [
      /\.class\.module_eval\b/,
      /\.class\.class_eval\b/,
    ].freeze

    def initialize(argv)
      @max_iterations = option_value(argv, "--max-iterations").to_i
      @max_iterations = 8 if @max_iterations <= 0
    end

    def run
      previous_count = nil
      @max_iterations.times do |idx|
        safe_nav = snapshot_safe_navigation
        full_files = snapshot_full_files
        run_srb_autocorrect
        restored_safe_nav = restore_safe_navigation(safe_nav)
        restored_bogus = restore_bogus_replacements(full_files)
        count = srb_error_count
        puts "Iter #{idx + 1}: errors=#{count || "unknown"}, &. restored=#{restored_safe_nav}, bogus reverted=#{restored_bogus}"
        break if count.nil?
        break if previous_count && count >= previous_count && restored_safe_nav.zero? && restored_bogus.zero?
        previous_count = count
      end
    end

    def option_value(argv, flag)
      idx = argv.index(flag)
      idx ? argv[idx + 1] : nil
    end

    def target_files
      AutoType.target_files
    end

    def snapshot_safe_navigation
      target_files.each_with_object({}) do |path, snap|
        File.readlines(path).each_with_index do |line, idx|
          next unless line.include?("&.")
          snap[path] ||= []
          snap[path] << { line: idx + 1, content: line }
        end
      end
    end

    def snapshot_full_files
      target_files.each_with_object({}) { |path, hash| hash[path] = File.readlines(path) }
    end

    def restore_safe_navigation(snapshot)
      restored = 0
      snapshot.each do |path, entries|
        next unless File.exist?(path)
        lines = File.readlines(path)
        changed = false
        entries.each do |entry|
          idx = entry[:line] - 1
          next if idx >= lines.length
          current = lines[idx]
          original = entry[:content]
          next if current == original
          next unless current == original.gsub("&.", ".")
          lines[idx] = original
          restored += 1
          changed = true
        end
        File.write(path, lines.join) if changed
      end
      restored
    end

    def restore_bogus_replacements(snapshot)
      restored = 0
      snapshot.each do |path, original_lines|
        next unless File.exist?(path)
        current = File.readlines(path)
        changed = false
        current.each_with_index do |line, idx|
          original = original_lines[idx]
          next unless original && line != original
          next unless BOGUS_AUTOCORRECT_PATTERNS.any? { |pattern| line.match?(pattern) && !original.match?(pattern) }
          current[idx] = original
          restored += 1
          changed = true
        end
        File.write(path, current.join) if changed
      end
      restored
    end

    def run_srb_autocorrect
      Open3.capture3({ "SRB_YES" => "1", "NO_COLOR" => "1" }, "bundle", "exec", "srb", "tc", "-a")
    end

    def srb_error_count
      _out, err, _status = Open3.capture3({ "SRB_YES" => "1", "NO_COLOR" => "1" }, "bundle", "exec", "srb", "tc")
      err.match(/Errors: (\d+)/)&.[](1)&.to_i
    end
  end
end
