# typed: false
# frozen_string_literal: true

module NilKill
  class StructRBI
    def initialize(argv)
      @output = option_value(argv, "--output")
      @include_existing = argv.include?("--include-existing-rbi")
      @complete = argv.include?("--complete")
      @validate = argv.include?("--validate")
      @max_validate_iterations = (option_value(argv, "--validate-max-iters") || "20").to_i
      @blocklist = Set.new
      @evidence = Store.read
    end

    def run
      if @validate
        run_with_validation
      else
        rbi = generate
        write_or_print(rbi)
      end
    end

    # Iteratively generate and srb-tc-validate the RBI, pruning sigs that
    # cause srb tc errors until the file is clean. Each failing run extracts
    # the method names from "Got <type> originating from\n... .METHOD"
    # blocks in the srb tc output and adds them to a blocklist. The
    # subsequent generation drops sigs for those field names across all
    # struct classes, falling back to T.untyped (the safe default that
    # matches the prior Sorbet behaviour).
    #
    # Bounded by --validate-max-iters (default 20) to prevent runaway loops
    # on degenerate inputs.
    def run_with_validation
      raise "struct-rbi --validate requires --output PATH" unless @output
      path = File.expand_path(@output, ROOT)
      original = File.read(path) if File.file?(path)
      iter = 0
      loop do
        iter += 1
        rbi = generate
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, rbi)
        out, err, status = Open3.capture3({ "SRB_YES" => "1", "NO_COLOR" => "1" }, "bundle", "exec", "srb", "tc")
        combined = out + err
        if status.success?
          puts "wrote #{NilKill.rel(path)} (validated clean in #{iter} iter(s); blocklist: #{@blocklist.size})"
          puts "blocklist: #{@blocklist.to_a.sort.join(", ")}" if @blocklist.any?
          return
        end
        new_methods = extract_offending_methods(combined) - @blocklist
        if new_methods.empty? || iter >= @max_validate_iterations
          warn "struct-rbi --validate could not converge after #{iter} iter(s). Reverting."
          warn combined.lines.grep(/^src\/.*: /).first(10).join
          File.write(path, original) if original
          File.delete(path) if !original && File.file?(path)
          raise "struct-rbi --validate failed"
        end
        @blocklist |= new_methods
        warn "iter #{iter}: dropping #{new_methods.size} offending method(s): #{new_methods.to_a.sort.first(8).join(", ")}#{new_methods.size > 8 ? ", ..." : ""}"
      end
    end

    # Parse srb tc error output for the `Got <type> originating from` blocks
    # and pull the trailing `receiver.method` calls out. The method name is
    # what we blocklist -- aggressive (drops the sig across all classes
    # defining that method), but unambiguous and progressive.
    def extract_offending_methods(srb_output)
      methods = Set.new
      # 1. "Got `T` originating from:" blocks -- the original signal.
      srb_output.scan(/Got `[^`]+` originating from:\s*\n((?:(?:    \s*[^\n]+)\n)+)/).each do |block_lines|
        block_lines.first.scan(/\.([a-z_][a-zA-Z0-9_]*)[?!]?\b/).each { |m| methods << m[0] }
      end
      # 2. Other srb tc shapes that the iterative loop must also be able
      #    to blocklist or it can never converge (7002 argument type,
      #    7004 not-enough-args, 7046 always-false comparison, 7005
      #    result type). For each error, scan the highlighted source
      #    line(s) `NNNN | code` for `.field` accessor chains -- the
      #    field whose freshly-emitted RBI sig is wrong -- plus the
      #    `for argument`/`result type of method` names. A name that
      #    isn't actually a struct field is a harmless no-op at regen
      #    (no sig is dropped for it).
      srb_output.each_line do |line|
        if line =~ /^\s*\d+ \|/
          line.scan(/\.([a-z_][a-zA-Z0-9_]*)[?!]?\b/).each { |m| methods << m[0] }
        end
        line.scan(/for argument `([a-z_]\w*)`/).each { |m| methods << m[0] }
        line.scan(/result type of method `([a-z_]\w*[?!]?)`/).each { |m| methods << m[0].sub(/[?!]\z/, "") }
      end

      # 3. Direct errors referencing the generated RBI file by line number.
      if @output
        path = File.expand_path(@output, ROOT)
        if File.file?(path)
          lines = File.readlines(path)
          rel_path = NilKill.rel(path)
          srb_output.scan(/(?:#{Regexp.escape(path)}|#{Regexp.escape(rel_path)}):(\d+):/).each do |m|
            line_idx = m[0].to_i - 1
            # Look around line_idx for a method definition. Check line_idx and next 4 lines.
            (line_idx..(line_idx + 4)).each do |i|
              next unless lines[i]
              if lines[i] =~ /^\s*def\s+([a-zA-Z_]\w*[?!]?)/
                methods << $1.sub(/[?!]\z/, "")
                break
              end
            end
          end
        end
      end

      methods
    end

    def write_or_print(rbi)
      if @output
        path = File.expand_path(@output, ROOT)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, rbi)
        puts "wrote #{NilKill.rel(path)}"
      else
        puts rbi
      end
    end

    def generate
      facts = @evidence["facts"]
      candidates = Report.new.struct_field_candidates(Array(facts["struct_field_runtime"]), Array(facts["struct_field_static"]))
      return generate_complete(facts, candidates) if @complete
      existing = @include_existing ? Set.new : existing_rbi_slots
      grouped = Hash.new { |h, k| h[k] = [] }
      candidates.each do |candidate|
        next if candidate["type"] == "T.untyped"
        slot = [candidate["class"], candidate["field"]]
        next if existing.include?(slot)
        grouped[candidate["class"]] << candidate
      end
      lines = [
        "# typed: true",
        "# frozen_string_literal: true",
        "",
        "# AUTO-GENERATED by bundle exec tools/nil-kill struct-rbi.",
        "# Re-run nil-kill infer/collect before regenerating.",
        "",
      ]
      grouped.keys.sort.each do |klass|
        lines << "class #{klass}"
        grouped[klass].sort_by { |candidate| candidate["field"] }.each do |candidate|
          lines << "  sig { returns(#{candidate["type"]}) }"
          lines << "  def #{candidate["field"]}; end"
        end
        lines << "end"
        lines << ""
      end
      lines << "# No new struct field candidates." if grouped.empty?
      lines.join("\n")
    end

    def generate_complete(facts, candidates)
      @blocklist ||= Set.new
      candidate_types = candidates.each_with_object({}) { |candidate, hash| hash[[candidate["class"], candidate["field"]]] = candidate["type"] }
      existing_types = existing_rbi_types
      lines = [
        "# typed: true",
        "# frozen_string_literal: true",
        "",
        "# AUTO-GENERATED by bundle exec tools/nil-kill struct-rbi --complete.",
        "# Re-run nil-kill infer/collect before regenerating.",
        "",
      ]
      Array(facts["struct_declarations"]).sort_by { |decl| [decl["class"], decl["line"].to_i] }.each do |decl|
        fields = Array(decl["fields"])
        next if fields.empty?
        lines << "class #{decl["class"]}"
        fields.each do |field|
          type = if @blocklist.include?(field.to_s)
            # Validation pruned this method name globally. Fall back to
            # T.untyped to match the pre-RBI behaviour Sorbet had before.
            existing_types[[decl["class"], field]] && !@blocklist.include?(field.to_s) ? existing_types[[decl["class"], field]] : "T.untyped"
          else
            candidate_types[[decl["class"], field]] || existing_types[[decl["class"], field]] || "T.untyped"
          end
          lines << "  sig { returns(#{type}) }"
          lines << "  def #{field}; end"
        end
        lines << "end"
        lines << ""
      end
      lines.join("\n")
    end

    def existing_rbi_slots
      slots = Set.new
      existing_rbi_types.each_key { |slot| slots << slot }
      slots
    end

    def existing_rbi_types
      StructFieldTypeIndex.from_rbi(ROOT)
    end

    def option_value(argv, flag)
      idx = argv.index(flag)
      idx ? argv[idx + 1] : nil
    end
  end
end
