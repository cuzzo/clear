# typed: false
# frozen_string_literal: true

require_relative "ruby/sorbet"
require "prism"

module NilKill
  module Languages
    module Providers
      class Ruby < Provider
        RUNTIME_SCIP_SELECTOR_ALIASES = {
          "Set" => {
            "add" => ["add?"],
          }.freeze,
        }.freeze

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
          class_constructor = callee["native"] == true &&
            callee["owner"].to_s == "Class" && callee["name"].to_s == "new"

          method = ruby_runtime_scip_methods(path).find do |candidate|
            candidate.fetch(:name) == caller.fetch("method").to_s &&
              candidate.fetch(:line) == caller.fetch("line").to_i
          end
          return [] unless method

          source_name = callee.fetch("name").to_s == "initialize" ?
            "new" : callee.fetch("name").to_s
          calls = method.fetch(:calls).select { |call| call.fetch(:name) == source_name }
          if class_constructor
            calls = calls.select do |call|
              call[:receiver_owner].nil? && call[:receiver_name].nil?
            end
          end
          same_line = calls.select do |call|
            call.fetch(:line) == callsite.fetch("line").to_i
          end
          calls = same_line unless same_line.empty?
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

        def runtime_scip_event_eligible?(event:, root:)
          package = event.dig("callee", "package").to_s
          return false if %w[minitest mocha rspec-mocks rr].include?(package)

          callee_path = event.dig("callee", "path").to_s
          return true if callee_path.empty?

          absolute = File.expand_path(callee_path, root)
          root = File.expand_path(root)
          return true unless absolute.start_with?("#{root}#{File::SEPARATOR}")

          relative = absolute.delete_prefix("#{root}#{File::SEPARATOR}")
          components = Pathname.new(relative).each_filename.to_a
          basename = components.last.to_s
          !components.any? { |component| %w[test tests spec specs].include?(component) } &&
            !basename.match?(/(?:_test|_spec)\.rb\z/)
        end

        def runtime_scip_inferred_events(events:, root:, runtime_dir: nil)
          methods_by_path = {}
          runtime_observations = ruby_runtime_scip_observations(runtime_dir)
          method_observations = runtime_observations.fetch(:parameters)
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

            selector = callee.fetch("name").to_s == "initialize" ?
              "new" : callee.fetch("name").to_s
            identity = %w[
              owner name kind path line native receiver_type
              package_manager package version
            ].map { |field| callee[field] }
            index[selector][identity] ||= event
          end
          ivar_owners = ruby_runtime_scip_ivar_owners(
            methods_by_path,
            method_observations,
            runtime_observations
          )

          inferred = []
          methods_by_path.sort.each do |path, methods|
            methods.each do |method|
              receiver_domains = ruby_runtime_scip_local_owners(
                method,
                method_observations.fetch(
                  [path, method.fetch(:line), method.fetch(:name)],
                  {}
                ),
                runtime_observations,
                [path, method.fetch(:line), method.fetch(:name)],
                ivar_owners
              )
              method.fetch(:calls).each do |call|
                selector = call.fetch(:name)
                candidates = observed.fetch(selector, {}).values
                observed_receivers = receiver_domains.fetch(:owners)
                  .fetch(call[:receiver_name].to_s, [])
                if observed_receivers.empty? && call[:receiver_shape]
                  observed_receivers = ruby_runtime_scip_value_domain(
                    call.fetch(:receiver_shape),
                    :owners,
                    receiver_domains.fetch(:owners),
                    receiver_domains.fetch(:elements),
                    receiver_domains.fetch(:keys),
                    receiver_domains.fetch(:values),
                    runtime_observations
                  )
                end
                receiver_owners_for_call =
                  if call[:receiver_owner]
                    [call[:receiver_owner]]
                  else
                    observed_receivers
                  end
                if candidates.empty? && !receiver_owners_for_call.empty?
                  aliases = receiver_owners_for_call.flat_map do |receiver_owner|
                    RUNTIME_SCIP_SELECTOR_ALIASES
                      .fetch(receiver_owner, {})
                      .fetch(selector, [])
                  end.uniq
                  candidates = aliases.flat_map do |runtime_selector|
                    observed.fetch(runtime_selector, {}).values.filter_map do |event|
                      callee = event.fetch("callee")
                      next unless receiver_owners_for_call.any? do |receiver_owner|
                        ruby_runtime_owner_matches?(
                          callee.fetch("owner").to_s,
                          receiver_owner
                        ) || ruby_runtime_owner_matches?(
                          callee["receiver_type"].to_s,
                          receiver_owner
                        )
                      end

                      event.merge(
                        "callee" => callee.merge("name" => selector)
                      )
                    end
                  end
                end
                unless receiver_owners_for_call.empty?
                  receiver_kind = call[:receiver_kind]
                  receiver_kind ||= "instance" unless observed_receivers.empty?
                  narrowed = candidates.select do |event|
                    callee = event.fetch("callee")
                    receiver_owners_for_call.any? do |receiver_owner|
                      ruby_runtime_owner_matches?(
                        callee.fetch("owner").to_s,
                        receiver_owner
                      ) || ruby_runtime_owner_matches?(
                        callee["receiver_type"].to_s,
                        receiver_owner
                      )
                    end && (
                      receiver_kind.nil? ||
                      callee.fetch("kind").to_s == receiver_kind
                    )
                  end
                  candidates = narrowed
                else
                  owners = candidates.map do |event|
                    event.fetch("callee").fetch("owner").to_s
                  end.uniq
                  # An unexecuted dynamic receiver cannot inherit a global
                  # selector-wide dispatch union. Infer only when every
                  # observed candidate proves the same runtime owner; actual
                  # executed callsites remain represented by their events.
                  candidates = [] unless owners.one?
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
              assignments = Hash.new { |hash, name| hash[name] = [] }
              ivar_assignments = Hash.new { |hash, name| hash[name] = [] }
              block_bindings = []
              collection_writes = []
              collect = lambda do |child|
                return if child.is_a?(Prism::DefNode)

                if child.is_a?(Prism::LocalVariableWriteNode)
                  assignments[child.name.to_s] << ruby_runtime_scip_value_shape(child.value)
                elsif child.is_a?(Prism::InstanceVariableWriteNode)
                  ivar_assignments[child.name.to_s] <<
                    ruby_runtime_scip_value_shape(child.value)
                elsif child.is_a?(Prism::CallNode)
                  receiver_name = ruby_runtime_scip_receiver_name(child.receiver)
                  if receiver_name
                    collection_writes << {
                      receiver_name: receiver_name,
                      message: child.name.to_s,
                      arguments: Array(child.arguments&.arguments).map do |argument|
                        ruby_runtime_scip_value_shape(argument)
                      end,
                    }
                  end
                  block_parameters = ruby_runtime_scip_block_parameter_names(child.block)
                  unless block_parameters.empty?
                    block_bindings << {
                      receiver_name: ruby_runtime_scip_receiver_name(child.receiver),
                      receiver_shape: child.receiver &&
                        ruby_runtime_scip_value_shape(child.receiver),
                      message: child.name.to_s,
                      parameters: block_parameters,
                      arguments: Array(child.arguments&.arguments).map do |argument|
                        ruby_runtime_scip_value_shape(argument)
                      end,
                    }
                  end
                  location =
                    if %i[[] []=].include?(child.name) && child.opening_loc
                      child.opening_loc
                    else
                      child.message_loc || child.location
                    end
                  calls << {
                    name: child.name.to_s,
                    line: location.start_line,
                    range: ruby_runtime_scip_range(location),
                    receiver_owner: ruby_runtime_scip_receiver_owner(child.receiver),
                    receiver_kind: ruby_runtime_scip_receiver_kind(child.receiver),
                    receiver_name: ruby_runtime_scip_receiver_name(child.receiver),
                    receiver_shape: child.receiver &&
                      ruby_runtime_scip_value_shape(child.receiver),
                  }
                elsif child.class.name.end_with?("OperatorWriteNode") &&
                    child.respond_to?(:binary_operator) &&
                    child.respond_to?(:binary_operator_loc)
                  location = child.binary_operator_loc
                  calls << {
                    name: child.binary_operator.to_s,
                    line: location.start_line,
                    range: ruby_runtime_scip_range(location),
                    receiver_owner: child.respond_to?(:receiver) ?
                      ruby_runtime_scip_receiver_owner(child.receiver) : nil,
                    receiver_kind: child.respond_to?(:receiver) ?
                      ruby_runtime_scip_receiver_kind(child.receiver) : nil,
                    receiver_name: child.respond_to?(:receiver) ?
                      ruby_runtime_scip_receiver_name(child.receiver) : nil,
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
                assignments: assignments,
                ivar_assignments: ivar_assignments,
                block_bindings: block_bindings,
                collection_writes: collection_writes,
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

        def ruby_runtime_scip_receiver_kind(node)
          case node
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            "class"
          when Prism::StringNode, Prism::InterpolatedStringNode,
              Prism::ArrayNode, Prism::HashNode,
              Prism::SymbolNode, Prism::InterpolatedSymbolNode,
              Prism::IntegerNode, Prism::FloatNode,
              Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode,
              Prism::RangeNode
            "instance"
          end
        end

        def ruby_runtime_scip_receiver_name(node)
          case node
          when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode,
              Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode
            node.name.to_s
          end
        end

        def ruby_runtime_scip_observations(runtime_dir)
          parameters = Hash.new do |methods, key|
            methods[key] = Hash.new { |parameters, name| parameters[name] = Set.new }
          end
          parameter_elements = Hash.new do |methods, key|
            methods[key] = Hash.new { |parameters, name| parameters[name] = Set.new }
          end
          parameter_keys = Hash.new do |methods, key|
            methods[key] = Hash.new { |parameters, name| parameters[name] = Set.new }
          end
          parameter_values = Hash.new do |methods, key|
            methods[key] = Hash.new { |parameters, name| parameters[name] = Set.new }
          end
          returns = Hash.new { |methods, name| methods[name] = Set.new }
          return_elements = Hash.new { |methods, name| methods[name] = Set.new }
          return_keys = Hash.new { |methods, name| methods[name] = Set.new }
          return_values = Hash.new { |methods, name| methods[name] = Set.new }
          return {
            parameters: parameters,
            parameter_elements: parameter_elements,
            parameter_keys: parameter_keys,
            parameter_values: parameter_values,
            returns: returns,
            return_elements: return_elements,
            return_keys: return_keys,
            return_values: return_values,
          } unless runtime_dir

          Dir.glob(File.join(runtime_dir, "methods-*.jsonl")).sort.each do |path|
            File.foreach(path) do |line|
              row = JSON.parse(line)
              source_path = File.expand_path(row.fetch("path"))
              key = [source_path, row.fetch("line").to_i, row.fetch("method").to_s]
              all = row.fetch("params_by_name", {})
              ok = row.fetch("params_ok", {})
              all.each_key do |name|
                classes = Array(ok[name])
                classes = Array(all[name]) if classes.empty?
                parameters[key][name.to_s].merge(classes.map(&:to_s))
              end
              row.fetch("param_elem", {}).each do |name, classes|
                parameter_elements[key][name.to_s].merge(Array(classes).map(&:to_s))
              end
              row.fetch("param_elem_shapes", {}).each do |name, shapes|
                shape_keys, shape_values = ruby_runtime_scip_shape_hash_domains(shapes)
                parameter_keys[key][name.to_s].merge(shape_keys)
                parameter_values[key][name.to_s].merge(shape_values)
              end
              row.fetch("param_kv", {}).each do |name, pair|
                parameter_keys[key][name.to_s].merge(Array(pair&.first).map(&:to_s))
                parameter_values[key][name.to_s].merge(Array(pair&.[](1)).map(&:to_s))
              end
              returns[row.fetch("method").to_s].merge(Array(row["returns"]).map(&:to_s))
              return_elements[row.fetch("method").to_s]
                .merge(Array(row["return_elem"]).map(&:to_s))
              shape_keys, shape_values =
                ruby_runtime_scip_shape_hash_domains(row["return_elem_shapes"])
              return_keys[row.fetch("method").to_s].merge(shape_keys)
              return_values[row.fetch("method").to_s].merge(shape_values)
              return_pair = Array(row["return_kv"])
              return_keys[row.fetch("method").to_s]
                .merge(Array(return_pair[0]).map(&:to_s))
              return_values[row.fetch("method").to_s]
                .merge(Array(return_pair[1]).map(&:to_s))
            rescue JSON::ParserError, KeyError
              next
            end
          end
          parameters.each_value do |method_parameters|
            method_parameters.transform_values! { |classes| classes.to_a.sort }
          end
          [parameter_elements, parameter_keys, parameter_values].each do |observations|
            observations.each_value do |method_parameters|
              method_parameters.transform_values! { |classes| classes.to_a.sort }
            end
          end
          returns.transform_values! { |classes| classes.to_a.sort }
          [return_elements, return_keys, return_values].each do |observations|
            observations.transform_values! { |classes| classes.to_a.sort }
          end
          {
            parameters: parameters,
            parameter_elements: parameter_elements,
            parameter_keys: parameter_keys,
            parameter_values: parameter_values,
            returns: returns,
            return_elements: return_elements,
            return_keys: return_keys,
            return_values: return_values,
          }
        end

        def ruby_runtime_scip_value_shape(node)
          case node
          when Prism::LocalVariableReadNode
            { kind: :alias, name: node.name.to_s }
          when Prism::ArrayNode
            {
              kind: :array,
              elements: node.elements.map { |element| ruby_runtime_scip_value_shape(element) },
            }
          when Prism::HashNode
            pairs = node.elements.grep(Prism::AssocNode)
            {
              kind: :hash,
              keys: pairs.map { |pair| ruby_runtime_scip_value_shape(pair.key) },
              values: pairs.map { |pair| ruby_runtime_scip_value_shape(pair.value) },
            }
          when Prism::CallNode
            receiver_owner = ruby_runtime_scip_receiver_owner(node.receiver)
            if node.name == :new && receiver_owner
              { kind: :owner, owner: receiver_owner }
            else
              {
                kind: :call,
                message: node.name.to_s,
                receiver_owner: receiver_owner,
                receiver_name: ruby_runtime_scip_receiver_name(node.receiver),
                receiver: node.receiver && ruby_runtime_scip_value_shape(node.receiver),
                arguments: Array(node.arguments&.arguments).map do |argument|
                  ruby_runtime_scip_value_shape(argument)
                end,
                argument_count: node.arguments&.arguments&.length.to_i,
                block_result: ruby_runtime_scip_block_result_shape(node.block),
              }
            end
          else
            owner = ruby_runtime_scip_receiver_owner(node)
            owner ? { kind: :owner, owner: owner } : { kind: :unknown }
          end
        end

        def ruby_runtime_scip_local_owners(
          method,
          parameter_observations,
          runtime_observations,
          method_key,
          ivar_owners = {}
        )
          owners = parameter_observations.transform_values(&:dup)
          ivar_owners.each do |name, classes|
            owners[name] = (owners.fetch(name, []) | classes).sort
          end
          elements = runtime_observations.fetch(:parameter_elements)
            .fetch(method_key, {}).transform_values(&:dup)
          keys = runtime_observations.fetch(:parameter_keys)
            .fetch(method_key, {}).transform_values(&:dup)
          values = runtime_observations.fetch(:parameter_values)
            .fetch(method_key, {}).transform_values(&:dup)
          assignments = method.fetch(:assignments, {})
          iterations = assignments.length +
            method.fetch(:block_bindings, []).length +
            method.fetch(:collection_writes, []).length + 1
          iterations.times do
            changed = false
            assignments.each do |name, assigned|
              domains = assigned.map do |value|
                ruby_runtime_scip_value_domain(
                  value, :owners, owners, elements, keys, values,
                  runtime_observations
                )
              end
              unless domains.any?(&:empty?)
                inferred = (
                  domains.flatten.map(&:to_s).uniq | owners.fetch(name, [])
                ).sort
                if owners[name] != inferred
                  owners[name] = inferred
                  changed = true
                end
              end
            end
            assignments.each do |name, assigned|
              {
                elements: elements,
                keys: keys,
                values: values,
              }.each do |shape, local_shapes|
                domains = assigned.map do |value|
                  ruby_runtime_scip_value_domain(
                    value, shape, owners, elements, keys, values,
                    runtime_observations
                  )
                end
                next if domains.any?(&:empty?)

                inferred = domains.flatten.map(&:to_s).uniq.sort
                inferred |= local_shapes.fetch(name, [])
                next if local_shapes[name] == inferred

                local_shapes[name] = inferred
                changed = true
              end
            end
            changed = ruby_runtime_scip_apply_block_bindings(
              method.fetch(:block_bindings, []),
              owners,
              elements,
              keys,
              values,
              runtime_observations
            ) || changed
            changed = ruby_runtime_scip_apply_collection_writes(
              method.fetch(:collection_writes, []),
              owners,
              elements,
              keys,
              values,
              runtime_observations
            ) || changed
            break unless changed
          end
          {
            owners: owners,
            elements: elements,
            keys: keys,
            values: values,
          }
        end

        def ruby_runtime_scip_apply_block_bindings(
          bindings,
          owners,
          elements,
          keys,
          values,
          runtime_observations
        )
          changed = false
          bindings.each do |binding|
            collection = binding[:receiver_name].to_s
            receiver_shape = binding[:receiver_shape]
            collection_owner = owners.fetch(collection, [])
            if collection_owner.empty? && receiver_shape
              collection_owner = ruby_runtime_scip_value_domain(
                receiver_shape, :owners, owners, elements, keys, values,
                runtime_observations
              )
            end
            collection_elements = elements[collection]
            collection_keys = keys[collection]
            collection_values = values[collection]
            if receiver_shape
              collection_elements = ruby_runtime_scip_value_domain(
                receiver_shape, :elements, owners, elements, keys, values,
                runtime_observations
              ) if Array(collection_elements).empty?
              collection_keys = ruby_runtime_scip_value_domain(
                receiver_shape, :keys, owners, elements, keys, values,
                runtime_observations
              ) if Array(collection_keys).empty?
              collection_values = ruby_runtime_scip_value_domain(
                receiver_shape, :values, owners, elements, keys, values,
                runtime_observations
              ) if Array(collection_values).empty?
            end
            parameters = binding.fetch(:parameters)
            element_domain = {
              owners: collection_elements,
              elements: [],
              keys: collection_keys,
              values: collection_values,
            }
            scalar_domain = lambda do |classes|
              { owners: classes, elements: [], keys: [], values: [] }
            end
            argument_domain = lambda do |argument|
              next scalar_domain.call([]) unless argument

              {
                owners: ruby_runtime_scip_value_domain(
                  argument, :owners, owners, elements, keys, values,
                  runtime_observations
                ),
                elements: ruby_runtime_scip_value_domain(
                  argument, :elements, owners, elements, keys, values,
                  runtime_observations
                ),
                keys: ruby_runtime_scip_value_domain(
                  argument, :keys, owners, elements, keys, values,
                  runtime_observations
                ),
                values: ruby_runtime_scip_value_domain(
                  argument, :values, owners, elements, keys, values,
                  runtime_observations
                ),
              }
            end
            arguments = binding.fetch(:arguments, [])
            candidates = case [collection_owner.one? && collection_owner.first, binding[:message]]
                         in ["Hash", "each" | "each_pair" | "map"]
                           [
                             scalar_domain.call(collection_keys),
                             scalar_domain.call(collection_values),
                           ]
                         in ["Hash", "each_key"]
                           [scalar_domain.call(collection_keys)]
                         in ["Hash", "each_value"]
                           [scalar_domain.call(collection_values)]
                         in [_, "each_with_index"]
                           [element_domain, scalar_domain.call(["Integer"])]
                         in [_, "each_with_object"]
                           [element_domain, argument_domain.call(arguments[0])]
                         in [_, "inject" | "reduce"]
                           accumulator = arguments.empty? ?
                             element_domain : argument_domain.call(arguments[0])
                           [accumulator, element_domain]
                         in [_, "each_slice" | "each_cons"]
                           [{
                             owners: ["Array"],
                             elements: collection_elements,
                             keys: collection_keys,
                             values: collection_values,
                           }]
                         else
                           [element_domain]
                         end
            parameters.zip(candidates).each do |name, candidate|
              classes = Array(candidate[:owners]).map(&:to_s).uniq.sort
              next if classes.empty?

              inferred_owners = (owners.fetch(name, []) | classes).sort
              if owners[name] != inferred_owners
                owners[name] = inferred_owners
                changed = true
              end
              if classes.include?("Array")
                inferred_elements = (
                  elements.fetch(name, []) | Array(candidate[:elements])
                ).sort
                if elements[name] != inferred_elements
                  elements[name] = inferred_elements
                  changed = true
                end
              end
              next unless classes.include?("Hash")

              inferred_keys = (keys.fetch(name, []) | Array(candidate[:keys])).sort
              if keys[name] != inferred_keys
                keys[name] = inferred_keys
                changed = true
              end
              inferred_values = (values.fetch(name, []) | Array(candidate[:values])).sort
              if values[name] != inferred_values
                values[name] = inferred_values
                changed = true
              end
            end
          end
          changed
        end

        def ruby_runtime_scip_apply_collection_writes(
          writes,
          owners,
          elements,
          keys,
          values,
          runtime_observations
        )
          changed = false
          writes.each do |write|
            receiver = write.fetch(:receiver_name)
            arguments = write.fetch(:arguments)
            updates = case write.fetch(:message)
                      when "<<", "push", "append", "unshift"
                        {
                          elements: arguments.flat_map do |argument|
                            ruby_runtime_scip_value_domain(
                              argument, :owners, owners, elements, keys, values,
                              runtime_observations
                            )
                          end,
                          keys: arguments.flat_map do |argument|
                            ruby_runtime_scip_value_domain(
                              argument, :keys, owners, elements, keys, values,
                              runtime_observations
                            )
                          end,
                          values: arguments.flat_map do |argument|
                            ruby_runtime_scip_value_domain(
                              argument, :values, owners, elements, keys, values,
                              runtime_observations
                            )
                          end,
                        }
                      when "concat"
                        {
                          elements: arguments.flat_map do |argument|
                            ruby_runtime_scip_value_domain(
                              argument, :elements, owners, elements, keys, values,
                              runtime_observations
                            )
                          end,
                          keys: arguments.flat_map do |argument|
                            ruby_runtime_scip_value_domain(
                              argument, :keys, owners, elements, keys, values,
                              runtime_observations
                            )
                          end,
                          values: arguments.flat_map do |argument|
                            ruby_runtime_scip_value_domain(
                              argument, :values, owners, elements, keys, values,
                              runtime_observations
                            )
                          end,
                        }
                      when "[]=", "store"
                        {
                          keys: (arguments[0] ? [arguments[0]] : []).flat_map do |argument|
                            ruby_runtime_scip_value_domain(
                              argument, :owners, owners, elements, keys, values,
                              runtime_observations
                            )
                          end,
                          values: (arguments[1] ? [arguments[1]] : []).flat_map do |argument|
                            ruby_runtime_scip_value_domain(
                              argument, :owners, owners, elements, keys, values,
                              runtime_observations
                            )
                          end,
                        }
                      when "merge!", "update"
                        {
                          keys: arguments.flat_map do |argument|
                            ruby_runtime_scip_value_domain(
                              argument, :keys, owners, elements, keys, values,
                              runtime_observations
                            )
                          end,
                          values: arguments.flat_map do |argument|
                            ruby_runtime_scip_value_domain(
                              argument, :values, owners, elements, keys, values,
                              runtime_observations
                            )
                          end,
                        }
                      else
                        {}
                      end
            updates.each do |domain, inferred|
              inferred = Array(inferred).map(&:to_s).uniq
              next if inferred.empty?

              domains = { elements: elements, keys: keys, values: values }.fetch(domain)
              merged = (domains.fetch(receiver, []) | inferred).sort
              next if domains[receiver] == merged

              domains[receiver] = merged
              changed = true
            end
          end
          changed
        end

        def ruby_runtime_scip_ivar_owners(
          methods_by_path,
          method_observations,
          runtime_observations
        )
          domains = Hash.new { |hash, name| hash[name] = Set.new }
          methods_by_path.each do |path, methods|
            methods.each do |method|
              parameters = method_observations.fetch(
                [path, method.fetch(:line), method.fetch(:name)],
                {}
              ).transform_values(&:dup)
              method.fetch(:ivar_assignments, {}).each do |name, assignments|
                assignments.each do |assignment|
                  ruby_runtime_scip_value_domain(
                    assignment, :owners, parameters, {}, {}, {},
                    runtime_observations
                  ).each { |owner| domains[name] << owner }
                end
              end
            end
          end
          domains.transform_values { |owners| owners.to_a.sort }
        end

        def ruby_runtime_scip_shape_hash_domains(shapes)
          keys = Set.new
          values = Set.new
          visit = lambda do |shape|
            case shape
            when Array
              shape.each { |child| visit.call(child) }
            when Hash
              case shape["kind"]
              when "hash"
                Array(shape["keys"]).each do |child|
                  owner = ruby_runtime_scip_shape_owner(child)
                  keys << owner if owner
                  visit.call(child)
                end
                Array(shape["values"]).each do |child|
                  owner = ruby_runtime_scip_shape_owner(child)
                  values << owner if owner
                  visit.call(child)
                end
              when "array"
                visit.call(shape["elements"])
              end
            end
          end
          visit.call(shapes)
          [keys.to_a.sort, values.to_a.sort]
        end

        def ruby_runtime_scip_shape_owner(shape)
          return unless shape.is_a?(Hash)

          case shape["kind"]
          when "class" then shape["name"].to_s
          when "array" then "Array"
          when "hash" then "Hash"
          end
        end

        def ruby_runtime_scip_value_domain(
          value,
          domain,
          owners,
          elements,
          keys,
          values,
          runtime_observations
        )
          local_domains = {
            owners: owners,
            elements: elements,
            keys: keys,
            values: values,
          }
          return [value[:owner]].compact if value[:kind] == :owner && domain == :owners
          return local_domains.fetch(domain).fetch(value[:name], []) if value[:kind] == :alias
          if value[:kind] == :array
            return ["Array"] if domain == :owners

            child_domain = domain == :elements ? :owners : domain
            return Array(value[:elements]).flat_map do |element|
              ruby_runtime_scip_value_domain(
                element, child_domain, owners, elements, keys, values,
                runtime_observations
              )
            end.map(&:to_s).uniq.sort
          end
          if value[:kind] == :hash
            return ["Hash"] if domain == :owners

            shapes = domain == :keys ? value[:keys] :
              (domain == :values ? value[:values] : [])
            return Array(shapes).flat_map do |shape|
              ruby_runtime_scip_value_domain(
                shape, :owners, owners, elements, keys, values,
                runtime_observations
              )
            end.map(&:to_s).uniq.sort
          end
          return [] unless value[:kind] == :call

          message = value[:message]
          observed = runtime_observations.fetch(
            {
              owners: :returns,
              elements: :return_elements,
              keys: :return_keys,
              values: :return_values,
            }.fetch(domain)
          ).fetch(message, [])
          receiver = value[:receiver]
          receiver_domain =
            if receiver
              ruby_runtime_scip_value_domain(
                receiver, domain, owners, elements, keys, values,
                runtime_observations
              )
            else
              []
            end
          receiver_owners =
            if receiver
              ruby_runtime_scip_value_domain(
                receiver, :owners, owners, elements, keys, values,
                runtime_observations
              )
            else
              []
            end

          inferred = if receiver
            case message
                     when "[]", "fetch"
                       if domain == :owners
                         collection_values = []
                         collection_values |= ruby_runtime_scip_value_domain(
                           receiver, :values, owners, elements, keys, values,
                           runtime_observations
                         ) if receiver_owners.include?("Hash")
                         collection_values |= ruby_runtime_scip_value_domain(
                           receiver, :elements, owners, elements, keys, values,
                           runtime_observations
                         ) if (receiver_owners & ["Array", "Range"]).any?
                         collection_values
                       else
                         []
                       end
                     when "first", "last", "pop", "shift", "sample"
                       if value[:argument_count].to_i.positive?
                         domain == :owners ? ["Array"] : receiver_domain
                       elsif domain == :owners
                         ruby_runtime_scip_value_domain(
                           receiver, :elements, owners, elements, keys, values,
                           runtime_observations
                         )
                       else
                         []
                       end
                     when "select", "reject", "filter", "compact", "uniq",
                         "sort", "sort_by", "reverse", "take", "drop"
                       receiver_domain
                     when "keys"
                       domain == :owners ? ["Array"] :
                         (domain == :elements ? ruby_runtime_scip_value_domain(
                           receiver, :keys, owners, elements, keys, values,
                           runtime_observations
                         ) : [])
                     when "values"
                       domain == :owners ? ["Array"] :
                         (domain == :elements ? ruby_runtime_scip_value_domain(
                           receiver, :values, owners, elements, keys, values,
                           runtime_observations
                         ) : [])
                     when "map", "filter_map", "flat_map"
                       if domain == :owners
                         ["Array"]
                       elsif domain == :elements && value[:block_result]
                         ruby_runtime_scip_value_domain(
                           value[:block_result], :owners, owners, elements, keys,
                           values, runtime_observations
                         )
                       elsif %i[keys values].include?(domain) && value[:block_result]
                         ruby_runtime_scip_value_domain(
                           value[:block_result], domain, owners, elements, keys,
                           values, runtime_observations
                         )
                       else
                         []
                       end
                     when "merge"
                       receiver_owners.include?("Hash") && domain == :owners ?
                         ["Hash"] : receiver_domain
            else
              []
            end
          else
            case message
            when "Array"
              if domain == :owners
                ["Array"]
              elsif domain == :elements
                Array(value[:arguments]).flat_map do |argument|
                  ruby_runtime_scip_value_domain(
                    argument, :elements, owners, elements, keys, values,
                    runtime_observations
                  ) | ruby_runtime_scip_value_domain(
                    argument, :owners, owners, elements, keys, values,
                    runtime_observations
                  )
                end
              else
                []
              end
            when "Hash"
              domain == :owners ? ["Hash"] : []
            else
              []
            end
          end
          (Array(observed) | Array(inferred)).map(&:to_s).uniq.sort
        end

        def ruby_runtime_scip_block_result_shape(block)
          return unless block&.respond_to?(:body)

          body = block.body
          node = body.is_a?(Prism::StatementsNode) ? body.body.last : body
          ruby_runtime_scip_value_shape(node) if node
        end

        def ruby_runtime_scip_block_parameter_names(block)
          return [] unless block&.respond_to?(:parameters)

          parameters = block.parameters
          return [] unless parameters

          names = []
          visit = lambda do |node|
            if node.is_a?(Prism::RequiredParameterNode)
              names << node.name.to_s
              return
            end
            node.compact_child_nodes.each { |child| visit.call(child) }
          end
          visit.call(parameters)
          names
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
