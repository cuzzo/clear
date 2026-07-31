# typed: false
# frozen_string_literal: true

require_relative "json_io"

module NilKill
  module Runtime
    # Turning what the collector saw into the rows the rest of the pipeline
    # reads.
    #
    # None of this needs a VM. The input is a document the collector wrote when
    # the traced program exited: its own tables, plus the one thing only that
    # process could know -- which package each file came from. The shaping is
    # the code that used to run at_exit, unchanged, reading that document
    # instead of live collector state.
    class CollectorExport
      RAW_GLOB = "collector-raw-*.json.gz"

      def self.write(runtime_dir:, plan:, root: NilKill::ROOT)
        anchors = anchors_by_key(plan, root)
        JsonIO.matching(runtime_dir, RAW_GLOB).each do |path|
          raw = JSON.parse(JsonIO.read(path), symbolize_names: true)
          new(raw, anchors, plan).write(runtime_dir, raw.fetch(:pid))
        end
      end

      # "<abs path>\1<line>\1<selector>" => the anchor symbols the plan wants
      # there. One observed event can satisfy several requests, so the collector
      # reports coordinates and the fan-out happens here.
      def self.anchors_by_key(plan, root)
        Array(plan && plan.dig("runtime_evidence", "requests")).each_with_object({}) do |request, map|
          anchor = request["anchor"]
          next unless anchor.is_a?(Hash)

          range = request["execution_range"] || anchor["range"]
          next unless range.is_a?(Hash)

          path = File.expand_path(anchor.fetch("relative_path"), root)
          selector = anchor.fetch("display_name").to_s
          symbol = anchor.fetch("symbol").to_s
          (range.fetch("start_line").to_i..range.fetch("end_line").to_i).each do |line|
            key = "#{path}\x01#{line + 1}\x01#{selector}"
            (map[key] ||= []) << symbol unless map[key]&.include?(symbol)
          end
        end
      end

      def initialize(raw, anchors, plan = nil)
        @raw = raw
        @anchors = anchors
        @plan = plan
      end

      # The same set of files the traced program used to write itself.
      def write(runtime_dir, pid)
        {
          "runtime-calls" => native_scip_call_rows,
          "methods" => native_scip_method_rows,
          "method-edges" => native_scip_method_edge_rows,
          "executed-callsites" => executed_callsite_rows,
          "exact-anchor-executions" => exact_anchor_rows,
          "function-entries" => function_entry_rows,
          "state-values" => native_scip_state_rows,
          "ivars" => ivar_rows,
          "structs" => table(:structs),
          "tuples" => table(:tuples),
          # A reader whose result is a collection was derived into this file too
          # and then overwritten by these rows before anything read it, so only
          # what the mutation hook observed is kept.
          "collections" => collection_observation_rows,
          "tlets" => tlet_rows,
        }.each do |name, rows|
          path = File.join(runtime_dir, "#{name}-#{pid}.jsonl")
          File.open(path, "w") { |file| rows.each { |row| file.puts JSON.generate(row) } }
        end
        write_coverage(runtime_dir, pid)
      end

      # Ruby's line coverage for the traced run, so the report can tell a tracer
      # miss from a line the workload simply never reached. The collector wrote
      # down what Coverage returned; turning it into covered line numbers needs
      # no VM and so happens here.
      def write_coverage(runtime_dir, pid)
        coverage = @raw[:coverage]
        return if coverage.nil?

        covered_by_path = {}
        File.open(File.join(runtime_dir, "coverage-#{pid}.jsonl"), "w") do |file|
          coverage.each do |path, data|
            source = path.to_s
            # Native collection uses oneshot_lines. A shared SimpleCov session
            # may already be running in counted-lines mode, so accept that shape
            # rather than restarting or weakening the external session.
            oneshot = data.is_a?(Hash) ? data[:oneshot_lines] : nil
            lines = data.is_a?(Hash) ? data[:lines] : data
            covered =
              if oneshot
                Array(oneshot).compact
              else
                Array(lines).each_with_index.filter_map do |hits, i|
                  i + 1 if hits && hits.to_i.positive?
                end
              end
            covered = covered.uniq.sort
            next if covered.empty?

            covered_by_path[source] = covered.to_set
            file.puts JSON.generate(path: source, lines: covered)
          end
        end
        File.open(File.join(runtime_dir, "loops-#{pid}.jsonl"), "w") do |file|
          Hash(@plan && @plan["loop_sites"]).each_key do |key|
            path, line = key.split("\0", 2)
            line = line.to_i
            next unless covered_by_path[path]&.include?(line)

            # Espalier reads loop evidence as reached / not reached; it does not
            # use iteration magnitude, and line coverage supplies that fact
            # without charging every loop evaluation a hash update.
            file.puts JSON.generate(path: path, line: line, count: 1)
          end
        end
      end

      private

      def table(name)
        @raw.fetch(name, [])
      end

      def symbols_for(path, line, selector)
        @anchors.fetch("#{path}\x01#{line}\x01#{selector}", [])
      end

      def callee_facts(path, native)
        @callee_facts ||= {}
        @callee_facts[[path, native]] ||= {
          source_role: (path && nonproduction_source?(path) ? "nonproduction" : nil),
        }.merge(package(path, native: native))
      end

      def raw_root
        @raw_root ||= @raw.fetch(:root, NilKill::ROOT).to_s
      end

      def raw_targets
        @raw_targets ||= Array(@raw[:targets]).map(&:to_s)
      end

      def ruby_package
        { package_manager: "ruby", package: "ruby", version: @raw.fetch(:ruby_version, RUBY_VERSION) }
      end

      def workspace_package
        {
          package_manager: "workspace",
          package: ENV.fetch("NIL_KILL_PROJECT_NAME", File.basename(raw_root)),
          version: ENV.fetch("NIL_KILL_PROJECT_VERSION", "workspace"),
        }
      end

      def target_path?(absolute)
        raw_targets.any? do |target|
          absolute == target || absolute.start_with?("#{target}#{File::SEPARATOR}")
        end
      end

      # Which gem owns a file is a fact only the traced VM held, and it wrote its
      # gem table down. What that makes the file is decided here.
      def gem_spec_for(absolute)
        @default_names ||= Array(@raw[:default_gem_specs]).map { |name, _, _| name }.to_set
        under = lambda do |row|
          root = row.fetch(2).to_s
          absolute == root || absolute.start_with?("#{root}#{File::SEPARATOR}")
        end
        Array(@raw[:gem_specs]).find(&under) || Array(@raw[:default_gem_specs]).find(&under)
      end

      def package(path, native:)
        return ruby_package if native

        # TracePoint uses pseudo-paths such as `<internal:warning>` for Ruby-core
        # implementations written outside the workspace. Expanding those would
        # incorrectly label `Kernel#warn` and peers as project code.
        raw_path = path.to_s
        return ruby_package if raw_path.empty? || raw_path.start_with?("<internal:")

        absolute = File.expand_path(raw_path, raw_root)
        @package_by_path ||= {}
        @package_by_path[absolute] ||=
          if target_path?(absolute)
            workspace_package
          elsif (spec = gem_spec_for(absolute))
            name, version, _ = spec
            {
              # Ruby ships a growing portion of its standard library as default
              # gems. Bundler may activate a newer vendored copy, but that does
              # not turn StringIO, JSON, etc. into third-party APIs.
              package_manager: @default_names.include?(name) ? "ruby" : "rubygems",
              package: name,
              version: version,
            }
          elsif absolute == raw_root || absolute.start_with?("#{raw_root}#{File::SEPARATOR}")
            # Trace targets are intentionally narrower than the workspace: a
            # project may call a sibling tool without instrumenting its source.
            # It is still a workspace declaration, not a Ruby core method.
            workspace_package
          else
            ruby_package
          end
      end

      def nonproduction_source?(path)
        @nonproduction ||= begin
          roles = ENV["NIL_KILL_SOURCE_ROLES"].to_s
          if !roles.empty? && File.file?(roles)
            Array(JSON.parse(File.read(roles))["nonproduction"])
              .map { |entry| File.expand_path(entry, raw_root) }.to_set
          else
            Set.new
          end
        rescue StandardError
          Set.new
        end
        @nonproduction.include?(File.expand_path(path, raw_root))
      end

      def definition_path(path)
        return nil unless path.is_a?(String)
        return nil if path.start_with?("<")
        return nil if path.include?("/gems/nil-kill/lib/")

        path
      end

      def empty_runtime_value_domain
        { types: [], singletons: [], elements: [], keys: [], values: [], shapes: [] }
      end

      # Only rebuild a field when an alternative is genuinely new: domains are
      # stored unique and sorted by the same key, so re-merging an existing one
      # is exactly the identity.
      def merge_runtime_value_domain!(target, source)
        source.each do |field, values|
          values = Array(values)
          current = target[field]
          if current.nil?
            target[field] = sort_runtime_domain_values(values.uniq)
            next
          end
          next if values.empty?

          added = values.reject { |item| current.include?(item) }
          next if added.empty?

          target[field] = sort_runtime_domain_values(current | added)
        end
        target
      end

      def sort_runtime_domain_values(values)
        values.sort_by { |item| item.is_a?(Hash) ? JSON.generate(item) : item.to_s }
      end

      # Types the collector named directly, merged with the domains it recorded
      # by index. `production_only` drops what a test double contributed, which
      # call evidence must not export as a target.
      def domain_for(types, indices, production_only: false)
        domain = empty_runtime_value_domain
        Array(types).each { |type| merge_runtime_value_domain!(domain, types: [type]) }
        Array(indices).each do |index|
          observed = table(:domains).fetch(index)
          next if production_only && observed[:nonproduction]

          merge_runtime_value_domain!(domain, observed.reject { |field, _| field == :nonproduction })
        end
        domain
      end

      def executed_callsite_rows
        table(:executed_callsites).sort_by { |row| row.map(&:to_s) }
          .map { |path, line, selector, count| { path: path, line: line, selector: selector, count: count } }
      end

      def exact_anchor_rows
        table(:executed_callsites)
          .each_with_object(Hash.new(0)) do |(path, line, selector, count), tally|
            symbols_for(path, line, selector).each { |symbol| tally[symbol] += count }
          end
          .sort.map { |symbol, count| { symbol: symbol, count: count } }
      end

      def function_entry_rows
        table(:function_entries).sort_by { |row| row.map(&:to_s) }
          .map { |path, owner, name, line, count| { path: path, owner: owner, name: name, kind: "instance", line: line, count: count } }
      end

      def collection_observation_rows
        table(:collections).map do |row|
          row.merge(mutation_sites: Hash(row[:mutation_sites])
            .sort_by { |site, count| [-count, site.to_s] }.to_h)
        end
      end

      def tlet_rows
        table(:tlets).map do |row|
          { path: row.fetch(:path), line: row.fetch(:line),
            calls: row.fetch(:calls), classes: row.fetch(:classes) }
        end
      end

      # The same observations answer two questions: which classes a member holds
      # anywhere, and which it holds at one write site.
      def ivar_rows
        native_scip_state_rows.each_with_object({}) do |row, tally|
          record = (tally[[row.fetch(:class), "@#{row.fetch(:name)}"]] ||= { calls: 0, classes: [] })
          record[:calls] += row.fetch(:calls)
          record[:classes] |= row.fetch(:classes)
        end.map { |(owner, name), record| { class: owner, name: name, calls: record[:calls], classes: record[:classes].sort } }
      end

  def native_scip_call_rows
    run_id = @raw.fetch(:run_id, "")
    table(:records).flat_map do |row|
      callee = row.fetch(:callee)
      path = definition_path(callee[:path])
      callsite = row.fetch(:callsite)
      symbols = symbols_for(
        callsite.fetch(:path), callsite.fetch(:line), callsite.fetch(:selector)
      )
      symbols = [nil] if symbols.empty?
      symbols.map do |anchor_symbol|
      {
        schema_version: 1,
        event: "runtime_call",
        language: "ruby",
        run_id: run_id,
        caller: row.fetch(:caller),
        callsite: callsite.slice(:path, :line).merge(anchor_symbol: anchor_symbol),
        # A known definition site outranks the C-implementation flag for package
        # attribution: a generated accessor on a workspace class is workspace
        # code, not CRuby, even though the VM reported it as a native call.
        callee: callee.merge(path: path, line: (path ? callee[:line] : nil))
          .merge(callee_facts(path, callee.fetch(:native) && path.nil?)),
        receiver_domain: domain_for(
          row.fetch(:receiver_types), row.fetch(:receiver_domain_indices),
          production_only: true
        ),
        result_domain: domain_for(
          row.fetch(:result_types), row.fetch(:result_domain_indices),
          production_only: true
        ),
        result_truths: row.fetch(:result_truths),
        count: row.fetch(:count),
      }
      end
    end
  end

  # The evidence emitter reads parameter and return domains from methods-*.jsonl,
  # which the Ruby type tier used to produce. The collector already observes both
  # -- parameters at analyzed method entry, returns under the "return" selector --
  # so this regroups those records per function in the shape the emitter expects.
  def native_scip_method_rows
    records = table(:records)
    by_site = records.group_by do |row|
      [row.dig(:callsite, :path), row.dig(:callsite, :line)]
    end
    table(:function_entries).map do |path, owner, name, line, count|
      rows = by_site.fetch([path, line], [])
      params = rows.reject { |row| row.dig(:callsite, :selector) == "return" }
      returned = rows.find { |row| row.dig(:callsite, :selector) == "return" }
      row = {
        class: owner, method: name, kind: "instance", path: path, line: line,
        calls: count, ok_calls: count, raised_calls: 0,
        params_by_name: {}, param_singleton_types: {}, param_value_shapes: {},
        param_elem: {}, param_elem_shapes: {}, param_kv: {}, param_kv_shapes: {},
        params_ok: {}, params_raised: {}, param_sites: {},
        returns: [], return_singleton_types: [], return_value_shapes: [],
        return_elem: [], return_elem_shapes: [], return_kv: [[], []],
        return_kv_shapes: [[], []],
      }
      params.each do |param|
        slot = param.dig(:callsite, :selector)
        domain = domain_for(
          param.fetch(:receiver_types), param.fetch(:receiver_domain_indices)
        )
        row[:params_by_name][slot] = domain.fetch(:types)
        row[:param_singleton_types][slot] = domain.fetch(:singletons)
        row[:param_value_shapes][slot] = domain.fetch(:shapes)
        row[:param_elem][slot] = domain.fetch(:elements)
        row[:param_elem_shapes][slot] = []
        row[:param_kv][slot] = [domain.fetch(:keys), domain.fetch(:values)]
        row[:param_kv_shapes][slot] = [[], []]
      end
      if returned
        domain = domain_for(
          returned.fetch(:result_types), returned.fetch(:result_domain_indices)
        )
        row[:returns] = domain.fetch(:types)
        row[:return_singleton_types] = domain.fetch(:singletons)
        row[:return_value_shapes] = domain.fetch(:shapes)
        row[:return_elem] = domain.fetch(:elements)
        row[:return_kv] = [domain.fetch(:keys), domain.fetch(:values)]
      end
      row
    end
  end

  # The same observations answer two questions: which classes a member holds
  # anywhere (ivars) and which it holds at one write site (state-values).
  def native_scip_state_rows
    table(:state_values).map do |path, line, owner, name, classes, calls|
      { path: path, line: line, class: owner, name: name,
        classes: classes.compact.sort, calls: calls }
    end
  end

  # An edge is a fact about the call graph, not evidence about a requested
  # value, so it is recorded for every call between two analyzed methods rather
  # than only for callsites the plan demanded. Both endpoints are function
  # entries, so their owner and name are read back from those.
  def native_scip_method_edge_rows
    entries = table(:function_entries).to_h do |path, owner, name, line, _count|
      [[path, line], { class: owner, method: name, kind: "instance", path: path, line: line }]
    end
    table(:method_edges).filter_map do |caller_path, caller_line, callee_path, callee_line, calls|
      from = entries[[caller_path, caller_line]]
      to = entries[[callee_path, callee_line]]
      next unless from && to

      { caller: from, callee: to, calls: calls, ok_calls: calls, raised_calls: 0 }
    end
  end

    end
  end
end
