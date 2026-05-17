# typed: false
# frozen_string_literal: true

module NilKill
  class InteractiveReview
    def initialize(argv)
      @kind = option_value(argv, "--kind") || "replace_nil_with_default"
      @dry_run = argv.include?("--dry-run")
      @evidence = Store.read
      @selected = Set.new
    end

    def run
      actions = @evidence["actions"].select { |action| action["kind"] == @kind }
      abort "no #{@kind} actions found; run `bundle exec tools/nil-kill infer` first" if actions.empty?
      if !$stdin.tty?
        print_noninteractive(actions)
        return
      end
      loop do
        render(actions)
        print "nil-kill review> "
        input = $stdin.gets&.strip
        break if input.nil? || input == "q"
        case input
        when "a"
          selected = @selected.map { |idx| actions[idx] }
          Apply.new(@dry_run ? ["--dry-run"] : []).apply_actions(selected)
          break
        when "all"
          actions.each_index { |idx| @selected.add(idx) }
        when "none"
          @selected.clear
        when /\Ao\s+(\d+)\z/
          open_context(actions, $1.to_i - 1)
        when /\A\d+\z/
          toggle(input.to_i - 1, actions.size)
        else
          puts "commands: number toggles, o N opens context, all, none, a applies, q quits"
        end
      end
    end

    def option_value(argv, flag)
      idx = argv.index(flag)
      idx ? argv[idx + 1] : nil
    end

    def render(actions)
      puts ""
      puts "Review #{@kind} actions"
      actions.each_with_index do |action, idx|
        mark = @selected.include?(idx) ? "x" : " "
        puts "#{idx + 1}. [#{mark}] #{action["path"]}:#{action["line"]} #{action["message"]}"
      end
      puts "commands: number toggles, o N opens context, all, none, a applies, q quits"
    end

    def print_noninteractive(actions)
      actions.each_with_index do |action, idx|
        puts "#{idx + 1}. [ ] #{action["path"]}:#{action["line"]} #{action["message"]}"
      end
    end

    def toggle(idx, size)
      return puts "out of range" if idx.negative? || idx >= size
      @selected.include?(idx) ? @selected.delete(idx) : @selected.add(idx)
    end

    def open_context(actions, idx)
      action = actions[idx]
      return puts "out of range" unless action
      path = File.join(ROOT, action["path"])
      line = action["line"].to_i
      lines = File.readlines(path)
      first = [line - 4, 1].max
      last = [line + 4, lines.size].min
      puts ""
      puts "#{action["path"]}:#{line}"
      puts "#{action["message"]}"
      (first..last).each do |line_no|
        marker = line_no == line ? ">" : " "
        puts "#{marker} #{line_no.to_s.rjust(5)}  #{lines[line_no - 1]}"
      end
    rescue Errno::ENOENT
      puts "missing file: #{action["path"]}"
    end
  end
end
