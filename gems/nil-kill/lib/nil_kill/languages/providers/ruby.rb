# typed: false
# frozen_string_literal: true

require_relative "ruby/sorbet"
require "prism"

module NilKill
  module Languages
    module Providers
      class Ruby < Provider
        def language
          "ruby"
        end

        def extensions
          [".rb"]
        end

        def annotation_systems
          %w[sorbet]
        end

        def type_systems
          sorbet.type_systems
        end

        def runtime_tracing?
          true
        end

        def type_next_annotation_advice?
          true
        end

        def runtime_trace_events
          %w[
            method_call
            method_return
            method_raise
            param_observed
            field_observed
            collection_observed
            hash_shape_observed
            call_edge
            runtime_call
            coverage
          ]
        end

        def runtime_capabilities
          super.merge(
            "method_calls" => true,
            "params" => true,
            "returns" => true,
            "exceptions" => true,
            "fields" => true,
            "collections" => true,
            "hash_shapes" => true,
            "call_edges" => true,
            "line_coverage" => true,
            "runtime_scip_calls" => true
          )
        end

        def notes
          ["runtime collection uses the existing nil-kill collect command and Ruby source instrumentation"]
        end

        def runtime_scip_environment(root:)
          claims = {
            "runtime.language" => "ruby",
            "runtime.version" => RUBY_VERSION,
            "runtime.engine" => RUBY_ENGINE,
            "runtime.engine_version" => RUBY_ENGINE_VERSION,
          }
          lockfile = File.join(root, "Gemfile.lock")
          if File.file?(lockfile)
            claims["runtime.lockfile.Gemfile.lock.sha256"] =
              "sha256:#{Digest::SHA256.file(lockfile).hexdigest}"
          end
          claims
        end

        # Ruby TracePoint reports the current line but not the bytecode call
        # column. Prism supplies exact selector locations, including selectors
        # nested in a multiline expression whose line event belongs to the
        # outer call. All same-line matches are retained as a conservative
        # modeled candidate set.
        def runtime_scip_callsite_locations(event:, root:)
          caller = event.fetch("caller")
          callsite = event.fetch("callsite")
          callee = event.fetch("callee")
          path = File.expand_path(callsite.fetch("path"), root)
          return [] unless File.expand_path(caller.fetch("path"), root) == path
          return [] if callee["native"] == true &&
            callee["owner"].to_s == "Class" && callee["name"].to_s == "new"

          method = ruby_runtime_scip_methods(path).find do |candidate|
            candidate.fetch(:name) == caller.fetch("method").to_s &&
              candidate.fetch(:line) == caller.fetch("line").to_i
          end
          return [] unless method

          source_name = callee.fetch("name").to_s == "initialize" ?
            "new" : callee.fetch("name").to_s
          calls = method.fetch(:calls).select { |call| call.fetch(:name) == source_name }
          # The index authority explicitly models the traced workload as a
          # closed world. Within one caller method, the conservative dispatch
          # domain for a selector is therefore the union of every target
          # observed for that selector, including syntactic occurrences in
          # branches the workload did not take. This is inference, not compiler
          # proof; FactMine preserves that distinction in bound quality.
          calls.map do |call|
            {
              "range" => call.fetch(:range),
              "selector" => source_name,
            }
          end.uniq
        rescue KeyError, Errno::ENOENT, Prism::ParseError
          []
        end

        def runtime_scip_inferred_events(events:, root:)
          methods_by_path = {}
          eligible = events.select do |event|
            caller = event.fetch("caller")
            callsite = event.fetch("callsite")
            path = File.expand_path(callsite.fetch("path"), root)
            next false unless File.expand_path(caller.fetch("path"), root) == path

            methods = (methods_by_path[path] ||= ruby_runtime_scip_methods(path))
            methods.any? do |method|
              method.fetch(:name) == caller.fetch("method").to_s &&
                method.fetch(:line) == caller.fetch("line").to_i
            end
          end
          observed = eligible.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |event, index|
            callee = event.fetch("callee")
            next if callee["native"] == true &&
              callee["owner"].to_s == "Class" && callee["name"].to_s == "new"

            selector = callee.fetch("name").to_s == "initialize" ?
              "new" : callee.fetch("name").to_s
            identity = %w[
              owner name kind path line native receiver_type
              package_manager package version
            ].map { |field| callee[field] }
            index[selector][identity] ||= event
          end

          inferred = []
          methods_by_path.sort.each do |path, methods|
            methods.each do |method|
              method.fetch(:calls).each do |call|
                selector = call.fetch(:name)
                candidates = observed.fetch(selector, {}).values
                receiver_owner = call[:receiver_owner]
                if receiver_owner
                  narrowed = candidates.select do |event|
                    ruby_runtime_owner_matches?(
                      event.fetch("callee").fetch("owner").to_s,
                      receiver_owner
                    )
                  end
                  candidates = narrowed unless narrowed.empty?
                end
                candidates.each do |event|
                  inferred << event.merge(
                    "callsite" => {
                      "path" => path,
                      "line" => call.fetch(:line),
                      "range" => call.fetch(:range),
                      "selector" => selector,
                    }
                  )
                end
              end
            end
          end
          inferred.uniq do |event|
            callsite = event.fetch("callsite")
            callee = event.fetch("callee")
            [
              callsite.fetch("path"),
              callsite.fetch("range"),
              callsite.fetch("selector"),
              callee.fetch("owner"),
              callee.fetch("name"),
              callee.fetch("kind"),
              callee["path"],
              callee["line"],
            ]
          end
        end

        def return_type_index(root:)
          sorbet.return_type_index(root: root)
        end

        def field_type_index(root:)
          sorbet.field_type_index(root: root)
        end

        def static_diff_findings(root:, added_lines:, context_paths:, finding_class:)
          NilKill::RubyStaticDiffAudit.new(
            root: root,
            added_lines: added_lines,
            context_paths: context_paths,
            finding_class: finding_class
          ).findings
        end

        def sorbet
          @sorbet ||= Sorbet.new
        end

        private

        def ruby_runtime_scip_methods(path)
          stat = File.stat(path)
          cache_key = [path, stat.size, stat.mtime.to_f]
          @runtime_scip_source_cache ||= {}
          return @runtime_scip_source_cache.fetch(cache_key) if @runtime_scip_source_cache.key?(cache_key)

          result = Prism.parse_file(path)
          return [] unless result.success?

          methods = []
          visit = lambda do |node|
            if node.is_a?(Prism::DefNode)
              calls = []
              collect = lambda do |child|
                return if child.is_a?(Prism::DefNode)

                if child.is_a?(Prism::CallNode)
                  location = child.message_loc || child.location
                  calls << {
                    name: child.name.to_s,
                    line: location.start_line,
                    range: ruby_runtime_scip_range(location),
                    receiver_owner: ruby_runtime_scip_receiver_owner(child.receiver),
                  }
                end
                child.compact_child_nodes.each do |grandchild|
                  collect.call(grandchild)
                end
              end
              collect.call(node.body) if node.body
              methods << {
                name: node.name.to_s,
                line: node.location.start_line,
                calls: calls,
              }
              # Nested definitions are separate caller domains.
              node.compact_child_nodes.each { |child| visit.call(child) }
              return
            end
            node.compact_child_nodes.each { |child| visit.call(child) }
          end
          visit.call(result.value)
          @runtime_scip_source_cache.delete_if { |key, _value| key.first == path }
          @runtime_scip_source_cache[cache_key] = methods
        end

        def ruby_runtime_scip_range(location)
          if location.start_line == location.end_line
            [location.start_line - 1, location.start_column, location.end_column]
          else
            [
              location.start_line - 1,
              location.start_column,
              location.end_line - 1,
              location.end_column,
            ]
          end
        end

        def ruby_runtime_scip_receiver_owner(node)
          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            node.full_name
          when Prism::StringNode, Prism::InterpolatedStringNode
            "String"
          when Prism::ArrayNode
            "Array"
          when Prism::HashNode
            "Hash"
          when Prism::SymbolNode, Prism::InterpolatedSymbolNode
            "Symbol"
          when Prism::IntegerNode
            "Integer"
          when Prism::FloatNode
            "Float"
          when Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode
            "Regexp"
          when Prism::RangeNode
            "Range"
          end
        end

        def ruby_runtime_owner_matches?(observed, inferred)
          observed == inferred ||
            observed.split("::").last == inferred.to_s.split("::").last
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Ruby.new)
