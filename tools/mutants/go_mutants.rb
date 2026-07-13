#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'

ROOT = File.expand_path('../..', __dir__)
BOOBYTRAP_SRC = File.join(ROOT, 'gems/boobytrap/src')

class GoMutantsRunner
  def initialize
    @mutants = []
    @subjects = {}
  end

  def scan_files
    Dir.glob(File.join(BOOBYTRAP_SRC, '*.go')).each do |file_path|
      next if file_path.end_with?('_test.go')

      rel_path = file_path.sub("#{ROOT}/", '')
      lines = File.readlines(file_path)
      current_func = '*'
      lexer_state = :code

      lines.each_with_index do |line, line_idx|
        clean_line, lexer_state = code_only_line(line, lexer_state)

        # Match function declarations
        if clean_line =~ /^\s*func\s+(?:\([^)]+\)\s+)?([A-Za-z0-9_]+)/
          current_func = $1
        end

        # Scan for mutatable tokens
        # Comparison operators
        col_offset = 0
        loop do
          match = clean_line.match(/(==|!=|<=|>=|<|>|\btrue\b|\bfalse\b)/, col_offset)
          break unless match

          tok = match[1]
          start_col = match.begin(0) + 1
          col_offset = match.end(0)
          if %w[< >].include?(tok)
            before = match.begin(0).positive? ? clean_line[match.begin(0) - 1] : nil
            adjacent = [before, clean_line[match.end(0)]]
            next if adjacent.include?(tok) || (tok == '<' && clean_line[match.end(0)] == '-')
          end

          kind = nil
          repl = nil
          case tok
          when '==' then kind = 'comparison_flip'; repl = '!='
          when '!=' then kind = 'comparison_flip'; repl = '=='
          when '<=' then kind = 'comparison_flip'; repl = '>'
          when '>=' then kind = 'comparison_flip'; repl = '<'
          when '<'  then kind = 'comparison_flip'; repl = '>='
          when '>'  then kind = 'comparison_flip'; repl = '<='
          when 'true' then kind = 'bool_literal_flip'; repl = 'false'
          when 'false' then kind = 'bool_literal_flip'; repl = 'true'
          end

          next unless kind

          @mutants << {
            file_path: file_path,
            rel_path: rel_path,
            line: line_idx + 1,
            column: start_col,
            original: tok,
            replacement: repl,
            kind: kind,
            method: current_func
          }
        end
      end
    end
  end

  def code_only_line(line, state)
    output = line.dup
    index = 0
    escaped = false
    while index < line.length
      char = line[index]
      following = line[index + 1]
      case state
      when :block_comment
        output[index] = ' ' unless char == "\n"
        if char == '*' && following == '/'
          output[index + 1] = ' '
          state = :code
          index += 2
        else
          index += 1
        end
      when :double_quote, :rune
        output[index] = ' ' unless char == "\n"
        delimiter = state == :double_quote ? '"' : "'"
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == delimiter
          state = :code
        end
        index += 1
      when :raw_string
        output[index] = ' ' unless char == "\n"
        state = :code if char == '`'
        index += 1
      else
        if char == '/' && following == '/'
          output[index...line.length] = ' ' * (line.length - index)
          break
        elsif char == '/' && following == '*'
          output[index, 2] = '  '
          state = :block_comment
          index += 2
        elsif char == '"'
          output[index] = ' '
          state = :double_quote
          index += 1
        elsif char == "'"
          output[index] = ' '
          state = :rune
          index += 1
        elsif char == '`'
          output[index] = ' '
          state = :raw_string
          index += 1
        else
          index += 1
        end
      end
    end
    [output, state]
  end

  def run(facts_out)
    puts "Found #{@mutants.length} potential Go mutants."

    # Let's shard or cap to make sure it doesn't take too long
    # We can skip equivalent ones or just run them in a fast way
    # Cap the deterministic sample so routine runs remain bounded.
    selected_mutants = @mutants.sample(100, random: Random.new(42))

    results = []
    selected_mutants.each_with_index do |m, idx|
      print "[#{idx + 1}/#{selected_mutants.length}] Mutating #{m[:rel_path]}:#{m[:line]}:#{m[:column]} in #{m[:method]} (#{m[:original]} -> #{m[:replacement]})... "

      # Apply mutation
      orig_content = File.read(m[:file_path])
      lines = orig_content.lines
      target_line = lines[m[:line] - 1]

      # Replace only the specific instance on that line
      col_idx = m[:column] - 1
      mutated_line = target_line[0...col_idx] + m[:replacement] + target_line[(col_idx + m[:original].length)..-1]
      lines[m[:line] - 1] = mutated_line

      stdout = ''
      stderr = ''
      status = nil
      begin
        File.write(m[:file_path], lines.join)
        stdout, stderr, status = Open3.capture3(
          'timeout', '120', 'bundle', 'exec', 'go', 'test', './...',
          chdir: BOOBYTRAP_SRC
        )
      ensure
        File.write(m[:file_path], orig_content)
      end

      combined_output = "#{stdout}\n#{stderr}"
      outcome = if status.exitstatus == 124
                  'timeout'
                elsif status.success?
                  'survived'
                elsif combined_output.match?(/\[build failed\]|syntax error|undefined:|cannot use .* as |mismatched types?/i)
                  'unviable'
                else
                  'killed'
                end

      puts outcome

      results << {
        id: "go:#{m[:rel_path]}:#{m[:line]}:#{m[:column]}:#{m[:kind]}",
        file: m[:rel_path],
        method: m[:method],
        kind: m[:kind],
        outcome: outcome,
        line: m[:line],
        column: m[:column],
        exit_code: status.exitstatus
      }

      # Update subjects
      subj_key = "#{m[:rel_path]}:#{m[:method]}"
      @subjects[subj_key] ||= {
        file: m[:rel_path],
        method: m[:method],
        mutations: 0,
        killed: 0,
        alive: 0,
        timeouts: 0,
        unviable: 0,
        skipped: 0
      }

      stats = @subjects[subj_key]
      stats[:mutations] += 1
      if outcome == 'killed'
        stats[:killed] += 1
      elsif outcome == 'survived'
        stats[:alive] += 1
      elsif outcome == 'timeout'
        stats[:timeouts] += 1
      else
        stats[:unviable] += 1
      end
    end

    # Format into mutant-facts/v1
    subjects_list = @subjects.values.map do |s|
      kill_rate = s[:mutations] > 0 ? (s[:killed].to_f / s[:mutations] * 100.0).round(2) : 0.0
      s.merge(
        kill_rate: kill_rate,
        gate_status: 'advisory',
        mutation_kind: 'stochastic'
      )
    end

    payload = {
      schema: 'mutant-facts/v1',
      source: 'tools/go-mutants',
      language: 'go',
      mutation_kind: 'stochastic',
      subjects: subjects_list,
      mutants: results
    }

    FileUtils.mkdir_p(File.dirname(facts_out))
    File.write(facts_out, JSON.pretty_generate(payload) + "\n")
    puts "Wrote facts to #{facts_out}"
  end
end

if __FILE__ == $PROGRAM_NAME
  runner = GoMutantsRunner.new
  runner.scan_files
  runner.run('/tmp/boobytrap-go-mutants.json')
end
