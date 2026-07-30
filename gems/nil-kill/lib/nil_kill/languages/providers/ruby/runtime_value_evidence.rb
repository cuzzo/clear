# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Ruby < Provider
        # Mechanical decoder for Ruby tracer artifacts. This module deliberately
        # does not parse source or connect observations through assignments,
        # calls, blocks, returns, or fields; FactMine owns those relationships.
        module RuntimeValueEvidence
          module_function

          def observations(runtime_dir:, root:)
            rows = []
            each_jsonl(runtime_dir, "methods-*.jsonl") do |method|
              scope = method_scope(method, root)
              method.fetch("params_by_name", {}).each do |name, types|
                key_shapes, value_shapes = key_value_shapes(
                  method.fetch("param_kv_shapes", {}).fetch(name, [])
                )
                rows << observation(
                  "parameter",
                  scope,
                  name,
                  domain(
                    types: types,
                    singletons: method.fetch("param_singleton_types", {}).fetch(name, []),
                    elements: method.fetch("param_elem", {}).fetch(name, []),
                    keys: method.fetch("param_kv", {}).fetch(name, [[], []])[0],
                    values: method.fetch("param_kv", {}).fetch(name, [[], []])[1],
                    shapes: method.fetch("param_value_shapes", {}).fetch(name, []) +
                      container_shapes(
                        types: types,
                        element_shapes: method.fetch("param_elem_shapes", {}).fetch(name, []),
                        key_shapes: key_shapes,
                        value_shapes: value_shapes
                      )
                  ),
                  method["calls"]
                )
              end
              unless Array(method["returns"]).empty? &&
                  Array(method["return_elem"]).empty? &&
                  Array(method.fetch("return_kv", [[], []])).flatten.empty?
                rows << observation(
                  "return",
                  scope,
                  "",
                  domain(
                    types: method["returns"],
                    singletons: method["return_singleton_types"],
                    elements: method["return_elem"],
                    keys: method.fetch("return_kv", [[], []])[0],
                    values: method.fetch("return_kv", [[], []])[1],
                    shapes: Array(method["return_value_shapes"]) +
                      container_shapes(
                        types: method["returns"],
                        element_shapes: method["return_elem_shapes"],
                        key_shapes: key_value_shapes(method.fetch("return_kv_shapes", []))[0],
                        value_shapes: key_value_shapes(method.fetch("return_kv_shapes", []))[1]
                      )
                  ),
                  method["ok_calls"]
                )
              end
            end
            each_jsonl(runtime_dir, "ivars-*.jsonl") do |field|
              rows << observation(
                "state",
                {
                  "language" => "ruby",
                  "path" => "",
                  "owner" => field["class"].to_s,
                  "function" => "",
                  "line" => 0,
                },
                field["name"],
                domain(types: field["classes"]),
                field["calls"]
              )
            end
            each_jsonl(runtime_dir, "state-values-*.jsonl") do |field|
              rows << observation(
                "state",
                {
                  "language" => "ruby",
                  "path" => relative_path(field["path"], root),
                  "owner" => field["class"].to_s,
                  "function" => "",
                  "line" => field["line"].to_i,
                },
                field["name"],
                domain(types: field["classes"]),
                field["calls"]
              )
            end
            each_jsonl(runtime_dir, "structs-*.jsonl") do |field|
              rows << observation(
                "state",
                {
                  "language" => "ruby",
                  "path" => relative_path(field["path"], root),
                  "owner" => field["class"].to_s,
                  "function" => "",
                  "line" => field["line"].to_i,
                },
                field["field"],
                domain(
                  types: field["classes"],
                  elements: field["elem_classes"],
                  keys: field["key_classes"],
                  values: field["value_classes"]
                ),
                field["calls"]
              )
            end
            each_jsonl(runtime_dir, "collections-*.jsonl") do |collection|
              rows << observation(
                "collection",
                {
                  "language" => "ruby",
                  "path" => relative_path(collection["path"], root),
                  "owner" => "",
                  "function" => "",
                  "line" => collection["line"].to_i,
                },
                collection["name"],
                domain(
                  types: collection["classes"],
                  elements: collection["elem_classes"],
                  keys: collection["key_classes"],
                  values: collection["value_classes"],
                  shapes: container_shapes(
                    kinds: [collection["kind"]],
                    element_shapes: collection["elem_shapes"],
                    key_shapes: collection["key_shapes"],
                    value_shapes: collection["value_shapes"]
                  )
                ),
                collection["calls"],
                slot_kind: collection["owner_kind"]
              )
            end
            merge_observations(rows)
          end

          def call(event:, root:)
            caller = event.fetch("caller")
            callsite = event.fetch("callsite")
            callee = event.fetch("callee")
            selector = callee.fetch("name").to_s == "initialize" ?
              "new" : callee.fetch("name").to_s
            target = {
              "symbol" => runtime_symbol(callee, selector),
              "owner" => callee["owner"].to_s,
              "name" => selector,
              "kind" => callee["kind"].to_s,
              "receiver_type" => callee["receiver_type"].to_s,
              "source_role" => target_source_role(callee, root),
              "package_manager" => symbol_word(callee["package_manager"] || "runtime"),
              "package_name" => symbol_word(callee["package"] || "ruby"),
              "package_version" => symbol_word(callee["version"] || "workspace"),
            }
            callee_path = callee["path"].to_s
            if callee["native"] != true && !callee_path.empty?
              absolute = File.expand_path(callee_path, root)
              if inside_root?(absolute, root)
                target["definition"] = {
                  "language" => "ruby",
                  "path" => relative_path(absolute, root),
                  "owner" => callee["owner"].to_s,
                  "name" => callee.fetch("name").to_s,
                  "kind" => callee["kind"].to_s,
                  "line" => callee["line"].to_i,
                }
              end
            end
            {
              "language" => "ruby",
              "caller" => {
                "language" => "ruby",
                "path" => relative_path(caller.fetch("path"), root),
                "owner" => caller["class"].to_s,
                "name" => caller["method"].to_s,
                "kind" => caller["kind"].to_s,
                "line" => caller["line"].to_i,
              },
              "callsite" => {
                "path" => relative_path(callsite.fetch("path"), root),
                "line" => callsite.fetch("line").to_i,
                "range" => normalized_range(callsite["range"]),
                "selector" => (callsite["selector"] || callee.fetch("name")).to_s,
                "anchor_symbol" => callsite["anchor_symbol"].to_s,
              }.compact,
              "target" => target,
              "receiver_domain" => normalized_domain_payload(event["receiver_domain"]),
              "result_domain" => normalized_domain_payload(event["result_domain"]),
              "result_truths" => Array(event["result_truths"]).uniq.sort_by { |truth| truth ? 1 : 0 },
              "receiver_source_role" =>
                callee["source_role"] == "nonproduction" ? "NON_PRODUCTION" : "UNKNOWN_SOURCE",
              "count" => event["count"].to_i,
            }.compact
          end

          def each_jsonl(runtime_dir, glob)
            NilKill::Runtime::JsonIO.matching(runtime_dir, glob).each do |path|
              NilKill::Runtime::JsonIO.foreach(path) do |line|
                yield JSON.parse(line)
              rescue JSON::ParserError
                next
              end
            end
          end

          def method_scope(method, root)
            {
              "language" => "ruby",
              "path" => relative_path(method["path"], root),
              "owner" => method["class"].to_s,
              "function" => method["method"].to_s,
              "line" => method["line"].to_i,
            }
          end

          def relative_path(path, root)
            return "" if path.to_s.empty?

            absolute = File.expand_path(path, root)
            Pathname.new(absolute).relative_path_from(Pathname.new(root)).to_s
          rescue ArgumentError
            path.to_s
          end

          def inside_root?(path, root)
            root = File.expand_path(root)
            path == root || path.start_with?("#{root}#{File::SEPARATOR}")
          end

          def normalized_range(range)
            return unless range.is_a?(Array)
            return range if range.length == 4
            return [range[0], range[1], range[0], range[2]] if range.length == 3
          end

          def runtime_symbol(callee, selector)
            manager = symbol_word(callee["package_manager"] || "runtime")
            package = symbol_word(callee["package"] || "ruby")
            version = symbol_word(callee["version"] || "workspace")
            owner = descriptor_owner(callee["owner"] || callee["receiver_type"] || "ruby")
            method = descriptor_name(selector)
            separator = callee["kind"].to_s == "class" ? "." : "#"
            "nil-kill-runtime #{manager} #{package} #{version} #{owner}#{separator}#{method}()."
          end

          def runtime_type_symbol(type)
            "nil-kill-runtime ruby ruby #{RUBY_VERSION} #{descriptor_owner(type)}#"
          end

          def runtime_singleton_symbol(type)
            "nil-kill-runtime ruby ruby #{RUBY_VERSION} #{descriptor_owner(type)}."
          end

          def target_source_role(callee, root)
            package = callee["package"].to_s
            return "NON_PRODUCTION" if callee["source_role"] == "nonproduction"
            return "NON_PRODUCTION" if %w[minitest mocha rspec-mocks rr].include?(package)
            # Generated native accessors in tests are still test replacements.
            # Their exact source provenance dominates the implementation
            # mechanism; otherwise a C-backed test Struct masquerades as a
            # standard-library target.
            return "NON_PRODUCTION" if nonproduction_path?(callee["path"], root)
            return "PRODUCTION" if callee["package_manager"].to_s == "workspace"
            return "STANDARD_LIBRARY" if callee["native"] == true ||
              callee["package_manager"] == "ruby"
            return "DEPENDENCY" unless package.empty?

            "UNKNOWN_SOURCE"
          end

          def nonproduction_path?(path, root)
            return false if path.to_s.empty?

            absolute = File.expand_path(path, root)
            relative = Pathname.new(absolute).relative_path_from(Pathname.new(root))
              .each_filename.to_a
            %w[test tests spec specs].any? { |component| relative.include?(component) } ||
              relative.last.to_s.match?(/(?:_test|_spec)\.rb\z/)
          rescue ArgumentError
            false
          end

          def symbol_word(value)
            text = value.to_s
            return "." if text.empty?
            return text if text.match?(/\A[A-Za-z0-9_.+@\/-]+\z/)

            "`#{text.gsub("`", "``")}`"
          end

          def descriptor_owner(value)
            value.to_s.split("::").reject(&:empty?)
              .map { |part| descriptor_name(part) }.join("/")
          end

          def descriptor_name(value)
            text = value.to_s
            # Match SCIP's canonical descriptor escaping exactly. Question
            # marks, bangs, equality signs, slashes, and most Ruby operators
            # must be backtick-escaped; only ASCII alphanumerics and these
            # four punctuation characters are legal bare names.
            return text if text.match?(/\A[A-Za-z0-9_+$-]+\z/)

            "`#{text.gsub("`", "``")}`"
          end

          def observation(kind, scope, slot, value_domain, count, slot_kind: "")
            {
              "kind" => kind,
              "scope" => scope,
              "slot" => slot.to_s,
              "slot_kind" => slot_kind.to_s,
              "domain" => value_domain,
              "count" => count.to_i,
            }
          end

          def domain(types: [], singletons: [], elements: [], keys: [], values: [], shapes: [])
            normalized_shapes = Array(shapes).filter_map { |shape| normalize_shape(shape) }.uniq
            normalized = {
              "types" => strings(types),
              "singletons" => strings(singletons),
              "elements" => strings(elements),
              "keys" => strings(keys),
              "values" => strings(values),
              "shapes" => normalized_shapes,
            }
            reconcile_record_identities!(normalized)
            normalized
          end

          def normalized_domain_payload(payload)
            return unless payload.is_a?(Hash)

            domain(
              types: payload["types"] || payload[:types],
              singletons: payload["singletons"] || payload[:singletons],
              elements: payload["elements"] || payload[:elements],
              keys: payload["keys"] || payload[:keys],
              values: payload["values"] || payload[:values],
              shapes: payload["shapes"] || payload[:shapes]
            )
          end

          # `T.untyped` is NilKill's absence-of-identity marker, not a runtime
          # alternative. When a value shape supplies an exact record identity,
          # replace that marker in the corresponding domain position. This is
          # mechanical schema normalization; CFG/DFG flow remains in FactMine.
          def reconcile_record_identities!(value_domain)
            shapes = value_domain.fetch("shapes")
            reconcile_record_slot!(value_domain, "types", shapes)
            reconcile_record_slot!(
              value_domain,
              "elements",
              shapes.flat_map { |shape| Array(shape["elements"]) }
            )
            reconcile_record_slot!(
              value_domain,
              "keys",
              shapes.flat_map { |shape| Array(shape["keys"]) }
            )
            reconcile_record_slot!(
              value_domain,
              "values",
              shapes.flat_map { |shape| Array(shape["values"]) }
            )
          end

          def reconcile_record_slot!(value_domain, slot, shapes)
            return unless value_domain.fetch(slot).include?("T.untyped")

            record_names = Array(shapes).filter_map do |shape|
              shape["name"].to_s if shape["kind"] == "record" && !shape["name"].to_s.empty?
            end
            return if record_names.empty?

            value_domain[slot] = ((value_domain.fetch(slot) - ["T.untyped"]) | record_names).sort
          end

          # The recorder stores raw shape samples per container edge.  A
          # `param_elem_shapes` record describes an element of `items`, not
          # `items` itself.  Preserve that ownership at the schema boundary:
          # FactMine's language-neutral CFG/DFG can then project `Array<T>`
          # through `each` without Ruby duplicating source-flow inference.
          def container_shapes(types: [], kinds: [], element_shapes: [], key_shapes: [], value_shapes: [])
            element_shapes = Array(element_shapes)
            key_shapes = Array(key_shapes)
            value_shapes = Array(value_shapes)
            (Array(types) + Array(kinds)).map(&:to_s).uniq.filter_map do |type|
              case type.downcase
              when "array"
                { "kind" => "array", "elements" => element_shapes } unless element_shapes.empty?
              when "set"
                { "kind" => "set", "elements" => element_shapes } unless element_shapes.empty?
              when "hash"
                if key_shapes.empty? && value_shapes.empty?
                  next
                end
                { "kind" => "hash", "keys" => key_shapes, "values" => value_shapes }
              end
            end
          end

          def key_value_shapes(value)
            values = Array(value)
            [Array(values[0]), Array(values[1])]
          end

          def strings(values)
            Array(values).map(&:to_s).reject(&:empty?).uniq.sort
          end

          def normalize_shape(shape)
            return { "kind" => "class", "name" => shape } if shape.is_a?(String)
            return unless shape.is_a?(Hash)

            kind = shape["kind"].to_s
            return { "kind" => "unknown" } if kind.empty?

            normalized = { "kind" => kind }
            normalized["name"] = shape["name"].to_s unless shape["name"].to_s.empty?
            %w[elements keys values].each do |key|
              children = Array(shape[key]).filter_map { |child| normalize_shape(child) }
              normalized[key] = children unless children.empty?
            end
            members = shape.fetch("members", {}).each_with_object({}) do |(name, child), out|
              normalized_child = normalize_shape(child)
              out[name.to_s] = normalized_child if normalized_child
            end
            normalized["members"] = members unless members.empty?
            normalized
          end

          def merge_observations(rows)
            rows.group_by do |row|
              [
                row["kind"],
                row["scope"],
                row["slot"],
                row["slot_kind"],
              ]
            end.map do |_key, duplicates|
              first = Marshal.load(Marshal.dump(duplicates.first))
              domain = first.fetch("domain")
              duplicates.drop(1).each do |row|
                %w[types singletons elements keys values shapes].each do |field|
                  domain[field] = (Array(domain[field]) | Array(row.dig("domain", field)))
                end
                first["count"] += row["count"].to_i
              end
              first
            end.sort_by do |row|
              scope = row.fetch("scope")
              [
                scope["language"], scope["path"], scope["owner"],
                scope["function"], scope["line"], row["kind"], row["slot"],
              ]
            end
          end
        end
      end
    end
  end
end
