# frozen_string_literal: true

require "prism"
require "pathname"
require "set"

require_relative "helper_config"
require_relative "method_registry"
require_relative "typed_ir"
require_relative "transpiler/call_lowerer"
require_relative "transpiler/constructor_lowerer"
require_relative "transpiler/local_analyzer"
require_relative "transpiler/metadata_collector"
require_relative "transpiler/require_resolver"
require_relative "transpiler/type_env"

module RubyToClear
  class Transpiler
    class TranspilationError < StandardError; end

    attr_reader :typed_ir

    LambdaParameters = Struct.new(
      :parameter_names,
      :scope_names,
      :scope_types,
      :setup_lines,
      :renames,
      keyword_init: true
    )

    DYNAMIC_RUBY_CALLS = {
      "send" => "dynamic dispatch; replace with a closed case/table over known method names",
      "__send__" => "dynamic dispatch; replace with a closed case/table over known method names",
      "public_send" => "dynamic dispatch; replace with a closed case/table over known method names",
      "const_get" => "dynamic constant lookup; replace with an explicit registry map",
      "const_defined?" => "dynamic constant lookup; replace with an explicit registry map",
      "instance_variable_get" => "dynamic instance state; replace with declared fields or a typed side table",
      "instance_variable_set" => "dynamic instance state; replace with declared fields or a typed side table",
      "define_method" => "dynamic method definition; generate explicit methods or a closed dispatcher",
      "method_missing" => "dynamic method definition; replace with explicit protocol methods",
      "eval" => "dynamic evaluation; refactor before translation",
      "instance_eval" => "dynamic evaluation; refactor before translation",
      "class_eval" => "dynamic evaluation; refactor before translation",
      "module_eval" => "dynamic evaluation; refactor before translation",
    }.freeze

    SCHEMA_HELPER_TYPE_PREDICATES = {
      "struct?" => "Schemas.StructSchema",
      "union?" => "Schemas.UnionSchema",
      "enum?" => "Schemas.EnumSchema",
      "resource?" => "Schemas.ResourceSchema",
      "inline_struct?" => "Schemas.InlineStructVariant",
    }.freeze

    CLEAR_KEYWORDS = %w[
      MUTABLE
      FN METHOD RETURN RETURNS USE
      IF THEN ELSE ELSE_IF END COMPTIME IS_A
      WHILE DO FOR IN BG NEXT BREAK CONTINUE
      CAST AS
      STRUCT ENUM UNION TRUE FALSE NIL Auto
      ASSERT RAISE CATCH EXIT DIE PASS PRUNE
      MOD AND OR OR_ELSE XOR BIT_AND BIT_OR
      REQUIRE
      SELECT WHERE INDEX REDUCE ORDER_BY LIMIT SKIP UNNEST DISTINCT EACH TAP FIND ANY ALL COUNT SUM AVERAGE MIN MAX CONCURRENT SHARD TAKE_WHILE WINDOW JOIN RECOVER COLLECT
      GIVE TAKES COPY MOVE CLONE SHARE LINK RESOLVE FREEZE
      WITH EXCLUSIVE RESTRICT BORROWED ON RETRY POSSIBLE_DEADLOCK POSSIBLE_LOCK_CYCLE VIEW MATERIALIZED SNAPSHOT GUARD PRE DEBUG_POST
      POLYMORPHIC SHARED SYNC POLICY
      REQUIRES
      MATCH PARTIAL START DEFAULT WHEN
      PUB PRIVATE
      EXTERN FROM ABI CALLCONV HEADER EFFECTS CLOSE
      STREAM YIELD YIELDS
      TIGHT
      TEST THAT STUB BENCHMARK SMASH PROFILE ASSERT_RAISES CAPTURES SEQUENCE
      PENDING BEFORE AFTER LET TAGS
    ].to_set.freeze

    include TypeEnv
    include LocalAnalyzer
    include RequireResolver
    include MetadataCollector
    include ConstructorLowerer
    include CallLowerer

    def initialize(source, raise_on_error: true, source_path: nil, helper_config: nil, cfg_facts_path: nil)
      @source = source
      @source_path = source_path
      @raise_on_error = raise_on_error
      @helper_config = HelperConfig.load(helper_config)
      @indent_level = 0
      @declared_locals = Set.new
      @class_variables = Set.new
      @emitted_class_storage_variables = Set.new
      @class_storage_types = {}
      @struct_fields = {}
      @aliasable_classes = Set.new
      @value_classes = Set.new
      @in_function_signature = false
      @emitted_class_structs = Set.new
      @emitted_constructor_wrappers = Set.new
      @public_class_names = Set.new
      @class_instance_field_names = Hash.new { |hash, key| hash[key] = Set.new }
      @class_instance_field_types = Hash.new { |hash, key| hash[key] = {} }
      @class_instance_method_names = Hash.new { |hash, key| hash[key] = Set.new }
      @class_class_method_names = Hash.new { |hash, key| hash[key] = Set.new }
      @class_mutating_instance_method_names = Hash.new { |hash, key| hash[key] = Set.new }
      @class_reentrant_instance_method_names = Hash.new { |hash, key| hash[key] = Set.new }
      @module_function_names = Hash.new { |hash, key| hash[key] = Set.new }
      @module_namespace_names = Set.new
      @module_aliases = {}
      @imported_class_names = Set.new
      @imported_prefixed_instance_methods = Set.new
      @imported_instance_method_names = Hash.new { |hash, key| hash[key] = Set.new }
      @collecting_imported_metadata = false
      @method_params = {}
      @method_param_types = {}
      @constructor_params = {}
      @struct_field_defaults = {}
      @loaded_metadata_files = Set.new
      @metadata_cycle_type_owners = Set.new
      @constant_metadata_candidate_cache = {}
      @metadata_source_indexes = {}
      @constant_names = {}
      @constant_literal_values = {}
      @constant_inline_nodes = {}
      @local_data_constant_names = Set.new
      @imported_data_constant_names = Set.new
      @constant_types = {}
      @static_type_arrays = {}
      @static_string_sets = {}
      @current_class = nil
      @renames = {}
      @mutable_params = nil
      @type_aliases = {}
      @type_alias_module_namespaces = Set.new
      @union_types = @helper_config.unions.to_h do |name, members|
        [name.to_s, Array(members).map(&:to_s)]
      end
      @closed_interface_unions = Set.new
      @configured_union_variants = @helper_config.union_variants.to_h do |name, variants|
        [name.to_s, variants.to_h { |type, variant| [type.to_s, variant.to_s] }]
      end
      @generated_union_defs = {}
      @union_types.each do |name, members|
        @generated_union_defs[name] = union_definition(name, members)
      end
      @imported_union_names = Set.new
      @generated_cast_helper_defs = {}
      @generated_support_helper_defs = {}
      @hash_default_specs = {}
      @hash_backed_locals = {}
      @body_union_defs = Set.new
      @regex_constants = Set.new
      @regex_constant_pattern_codes = {}
      @hoisted_regex_constants = {}
      @type_alias_union_deps = Hash.new { |hash, key| hash[key] = Set.new }
      @type_alias_context = []
      @method_return_types = {}
      @method_return_type_identities = {}
      @inherently_fallible_methods = Set.new
      @fallibility_edges = Set.new
      @emitted_type_names = {}
      @local_emitted_type_names_by_basename = {}
      @method_source_paths = Hash.new { |hash, key| hash[key] = Set.new }
      @declared_owner_source_paths = Hash.new { |hash, key| hash[key] = Set.new }
      @declared_owner_dir_indexed = Set.new
      @required_packages = Set.new
      @current_function_can_fail = false
      @inside_function = false
      @current_function_returns_value = false
      @function_statement_list_depth = 0
      @local_shapes = {}
      @local_types = {}
      @local_constant_values = {}
      @forced_untyped_locals = Set.new
      @narrowed_optional_storage_locals = Set.new
      @active_narrowed_binding_names = Set.new
      @singleton_class_depth = 0
      @current_function_type_bindings = {}
      @required_files = Set.new
      @private_method_names = Set.new
      @public_method_names = Set.new
      @private_section = false
      @current_param_names = Set.new
      @current_function_return_type = nil
      @current_function_name = nil
      @direct_return_value_depth = 0
      @generated_local_index = 0
      @constructor_placeholder_param_names = nil
      @current_instance_field_names = Set.new
      @current_instance_method_names = Set.new
      @current_mutating_instance_method_names = Set.new
      @inside_instance_method = false
      @inside_class_method = false
      @duplicate_instance_method_names = Set.new
      @mutable_parameter_function_names = Set.new
      @emitted_function_names = Set.new
      @metadata_finalized = false
      @qualified_class_resolution_cache = {}
      @class_instance_field_type_cache = {}
      @mixin_methods = Hash.new { |hash, key| hash[key] = [] }
      @mixin_includes = Hash.new { |hash, key| hash[key] = [] }
      @class_includes = Hash.new { |hash, key| hash[key] = [] }
      @mixin_fields = Hash.new { |hash, key| hash[key] = {} }
      @node_code_overrides = {}
      @structural_code_overrides = {}
      @lowering_safe_navigation = Set.new
      @scanner_scan_value_nodes = Set.new
      @branch_array_accumulators = Set.new
      @branch_array_accumulator_ends = {}
      @expected_expression_type = nil
      @inferring_safe_navigation_types = Set.new
      @data_only = @source.include?("ruby-to-clear: data-only")
      @typed_ir = TypedIR::Program.new(
        cfg_bundle: TypedIR::CfgFacts::Bundle.load(
          source: @source,
          source_path: @source_path,
          facts_path: cfg_facts_path
        )
      )

      @helper_config.struct_fields.each do |class_name, fields|
        fields.each do |field_name, type|
          @class_instance_field_names[class_name.to_s] << field_name.to_s
          @class_instance_field_types[class_name.to_s][field_name.to_s] = type.to_s
        end
      end
    end

    def transpile(program_node)
      @transpile_root = program_node
      locally_owned_classes = locally_owned_class_names(program_node)
      preload_required_metadata(program_node)
      @imported_class_names.subtract(locally_owned_classes)
      configure_local_emitted_type_names!(program_node)
      @mutable_parameter_function_names = collect_mutable_parameter_function_names(program_node)
      collect_mixin_metadata(program_node)
      @emitted_function_names = collect_emitted_function_names(program_node)
      collect_local_requires_from_node(program_node)
      collect_type_aliases_from_node(program_node)
      # Constructor signatures must be available while struct field defaults
      # are inspected; defaults may themselves call a constructor declared
      # earlier in the same source file.
      collect_method_signature_metadata_from_node(program_node)
      @method_return_types.each do |key, return_type|
        @inherently_fallible_methods << key if allocating_collection_return_type?(return_type)
      end
      propagate_transitive_fallibility!(program_node)
      collect_method_params_from_node(program_node)
      synthesize_closed_interface_union!(program_node, "Emittable")
      # AST::Locatable is the structural walker interface every AST struct
      # includes; translated walkers (each_locatable and its visitors) need
      # it closed the same way.
      synthesize_closed_interface_union!(program_node, "Locatable")
      sealed_interface_union_names(program_node).each do |interface_name|
        synthesize_closed_interface_union!(program_node, interface_name)
      end
      collect_struct_fields_from_node(program_node)
      normalize_imported_union_alias_members!
      collect_ast_node_variants_from_node(program_node)
      collect_regex_constants_from_node(program_node)
      collect_enum_variant_names_from_node(program_node)
      collect_constant_storage_names_from_node(program_node)
      collect_static_type_arrays_from_node(program_node)
      preload_class_instance_metadata(program_node)
      refine_struct_field_types_from_constructor_calls(program_node)
      @aliasable_classes.subtract(@struct_fields.keys)
      @aliasable_classes.subtract(@struct_fields.keys.map { |k| k.split("::").last })
      @aliasable_classes.subtract(@value_classes)
      normalize_value_class_field_types!
      normalize_all_union_types!
      # Recalculate duplicate instance method names globally
      classes_by_method = Hash.new { |hash, key| hash[key] = Set.new }
      @class_instance_method_names.each do |class_name, names|
        names.each { |name| classes_by_method[name] << class_name }
      end
      global_duplicates = Set.new
      classes_by_method.each do |name, classes|
        global_duplicates << name if classes.size > 1
      end
      # Class methods are emitted into CLEAR's flat function namespace. An
      # instance method with the same emitted name must therefore use its
      # receiver-qualified spelling even when both methods belong to the same
      # Ruby class (for example MIRPassState#require! and .require!).
      class_method_names_global = @class_class_method_names.values.reduce(Set.new, &:|)
      global_duplicates.merge(class_method_names_global)
      @imported_prefixed_instance_methods.clear
      @class_instance_method_names.each do |class_name, names|
        flat_class = class_name.to_s.split("::").last
        names.each do |method_name|
          if global_duplicates.include?(method_name)
            @imported_prefixed_instance_methods << [flat_class, method_name]
          end
        end
      end
      @duplicate_instance_method_names = duplicate_instance_method_names(program_node)
      @duplicate_instance_method_names.merge(class_method_names_global)
      @mixin_methods.each_value do |methods|
        methods.each { |_sig, fn| @duplicate_instance_method_names << clear_function_name(fn.name.to_s) }
      end
      @metadata_finalized = true
      @qualified_class_resolution_cache.clear
      @class_instance_field_type_cache.clear
      body = visit(program_node)
      body = normalize_reserved_field_names(body)
      requires = @required_packages.sort.map { |package| "REQUIRE \"pkg:#{package}\"" }
      requires += @required_files.map { |path| rendered_file_require(path) }
      requires += @helper_config.require_lines
      body, generated_unions = generated_union_definitions_for_body(body)
      generated_cast_helpers = @generated_cast_helper_defs.keys.sort.map { |name| @generated_cast_helper_defs.fetch(name) }
      generated_support_helpers = @generated_support_helper_defs.keys.sort.map { |name| @generated_support_helper_defs.fetch(name) }
      regex_constants = generated_regex_constant_defs
      # Hoisted regex constants use compilerRegexCompile outside the body, so the
      # prelude's usage scan must see them or their EXTERN would be dropped.
      helper_prelude = @helper_config.prelude_lines_for([body, *regex_constants].join("\n"))
      output = (requires.uniq + helper_prelude + generated_unions + regex_constants + [body] +
        generated_cast_helpers + generated_support_helpers)
        .reject(&:empty?).join("\n")
      rewrite_legacy_collection_types(output)
    end

    # Type inference deliberately retains the legacy Ruby-to-CLEAR type keys
    # (`T[]`, `HashMap<K, V>`) because they are used throughout the existing
    # semantic tables. Generated source must not retain those spellings:
    # current CLEAR gives bare `T[]` slice semantics, while Ruby Array values
    # are owned lists. Rewrite only parsed type-shaped candidates and skip
    # comments/string literals so ordinary expressions are never touched.
    def rewrite_legacy_collection_types(code)
      output = +""
      index = 0
      quote = nil
      escaped = false
      comment = false

      while index < code.length
        char = code[index]
        if comment
          output << char
          comment = false if char == "\n"
          index += 1
          next
        end
        if quote
          output << char
          if escaped
            escaped = false
          elsif char == "\\"
            escaped = true
          elsif char == quote
            quote = nil
          end
          index += 1
          next
        end
        if char == "#"
          comment = true
          output << char
          index += 1
          next
        end
        if char == '"' || char == "'"
          quote = char
          output << char
          index += 1
          next
        end

        candidate_end = legacy_type_candidate_end(code, index)
        if candidate_end
          candidate = code[index...candidate_end]
          collection_constructor = candidate.match?(/\A(?:List|Set|Pool)\[\]\z/)
          if !collection_constructor &&
             (candidate.include?("[]") || candidate.start_with?("HashMap<") || candidate.match?(/\A[?!~]\(?HashMap</))
            output << inline_collection_type(candidate)
            index = candidate_end
            next
          end
        end

        output << char
        index += 1
      end
      output
    end

    def rewrite_clear_identifier(code, source, replacement)
      output = +""
      index = 0
      quote = nil
      escaped = false
      comment = false

      while index < code.length
        char = code[index]
        if comment
          output << char
          comment = false if char == "\n"
          index += 1
          next
        end
        if quote
          # ${...} string interpolation is real CLEAR code (see Lexer#
          # read_interpolated_string - it desugars to "..." $+ (expr) $+
          # "..." before ever reaching the parser), not opaque string
          # content, even though it's lexically nested inside a quoted
          # literal here. An identifier reference inside it (e.g. self in
          # "...${self.x = ...}") needs the same rewrite as everywhere else
          # in the body, or a write through it silently keeps referring to
          # the wrong binding.
          if !escaped && char == "$" && code[index + 1] == "{" &&
             (close = interpolation_content_end(code, index + 2))
            inner = code[(index + 2)...close]
            output << "${" << rewrite_clear_identifier(inner, source, replacement) << "}"
            index = close + 1
            next
          end
          output << char
          if escaped
            escaped = false
          elsif char == "\\"
            escaped = true
          elsif char == quote
            quote = nil
          end
          index += 1
          next
        end
        if char == "#"
          comment = true
          output << char
          index += 1
          next
        end
        if char == '"' || char == "'"
          quote = char
          output << char
          index += 1
          next
        end

        before = index.zero? ? nil : code[index - 1]
        after = code[index + source.length]
        if code[index, source.length] == source &&
           !before&.match?(/[A-Za-z0-9_]/) &&
           !after&.match?(/[A-Za-z0-9_]/)
          output << replacement
          index += source.length
        else
          output << char
          index += 1
        end
      end
      output
    end

    # Finds the index of the `}` that closes a ${...} interpolation slot
    # whose content starts at start_index, tracking brace depth and skipping
    # over any quoted string literals nested inside (so a `}` inside one of
    # those doesn't prematurely close the interpolation). Returns nil if
    # unbalanced.
    def interpolation_content_end(code, start_index)
      depth = 1
      index = start_index
      quote = nil
      escaped = false
      while index < code.length
        char = code[index]
        if quote
          if escaped
            escaped = false
          elsif char == "\\"
            escaped = true
          elsif char == quote
            quote = nil
          end
          index += 1
          next
        end
        if char == '"' || char == "'"
          quote = char
        elsif char == "{"
          depth += 1
        elsif char == "}"
          depth -= 1
          return index if depth.zero?
        end
        index += 1
      end
      nil
    end

    def local_aliasable_instance_body(body, mutable:)
      view_name = "rtoc_self_view"
      rewritten = rewrite_clear_identifier(body, "self", view_name)
      nested = rewritten.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
      binding = mutable ? "MUTABLE #{view_name}" : view_name
      "#{indent}WITH POLYMORPHIC self AS #{binding} {\n#{nested}\n#{indent}}"
    end

    def legacy_type_candidate_end(code, start_index)
      return nil if start_index.positive? && code[start_index - 1]&.match?(/[A-Za-z0-9_]/)

      index = start_index
      prefix_count = 0
      while %w[? ! ~].include?(code[index])
        index += 1
        prefix_count += 1
      end
      if code[index] == "("
        return nil if prefix_count.zero?

        close = balanced_delimiter_end(code, index, "(", ")")
        return nil unless close
        index = close
      else
        return nil unless code[index]&.match?(/[A-Z]/)

        index += 1
        index += 1 while code[index]&.match?(/[A-Za-z0-9_.:]/)
        if code[index] == "<"
          close = balanced_delimiter_end(code, index, "<", ">")
          return nil unless close
          index = close
        elsif code[(start_index)...index] == "FN" && code[index] == "("
          close = balanced_delimiter_end(code, index, "(", ")")
          return nil unless close
          index = close
        end
      end

      index = consume_type_capabilities(code, index)
      loop do
        break unless code[index, 2] == "[]"

        index += 2
        index = consume_type_capabilities(code, index)
      end
      index
    end

    def balanced_delimiter_end(code, open_index, opener, closer)
      depth = 0
      index = open_index
      while index < code.length
        depth += 1 if code[index] == opener
        if code[index] == closer
          depth -= 1
          return index + 1 if depth.zero?
        end
        index += 1
      end
      nil
    end

    def consume_type_capabilities(code, start_index)
      index = start_index
      while code[index] == "@"
        index += 1
        index += 1 while code[index]&.match?(/[A-Za-z0-9_]/)
        if code[index] == "("
          close = balanced_delimiter_end(code, index, "(", ")")
          return index unless close
          index = close
        end
        while code[index] == ":"
          index += 1
          index += 1 while code[index]&.match?(/[A-Za-z0-9_]/)
        end
      end
      index
    end

    def inline_collection_type(type)
      text = type.to_s.strip
      if text.start_with?("?(") && text.end_with?(")")
        return "?#{inline_collection_type(text[2...-1])}"
      end
      if %w[? ! ~].include?(text[0]) &&
         !(text[0] == "?" && text.match?(/\[\](?:@[A-Za-z_]\w*(?:\([^)]*\))?(?::[A-Za-z_]\w*)*)*\z/))
        return "#{text[0]}#{inline_collection_type(text[1..])}"
      end

      layers = []
      while (match = text.match(/\[\]((?:@[A-Za-z_]\w*(?:\([^)]*\))?(?::[A-Za-z_]\w*)*)*)\z/))
        capabilities = match[1]
        layers << capabilities
        text = text[0...match.begin(0)]
      end
      unless layers.empty?
        item = inline_collection_type(text)
        if layers.all?(&:empty?)
          return layers.length == 1 ? "[]#{item}" : "[#{Array.new(layers.length, 'List').join(', ')}]#{item}"
        end
        return layers.reverse.reduce(item) do |inner, capabilities|
          if capabilities == "@set"
            "[Set]#{inner}"
          elsif capabilities.empty? || capabilities == "@list"
            "[]#{inner}"
          else
            "[]#{capabilities} #{inner}"
          end
        end
      end

      map_capabilities = ""
      map_text = text
      if (capability_match = text.match(/((?:@[A-Za-z_]\w*(?:\([^)]*\))?(?::[A-Za-z_]\w*)*)+)\z/))
        candidate = text[0...capability_match.begin(0)]
        if candidate.start_with?("HashMap<") && candidate.end_with?(">")
          map_text = candidate
          map_capabilities = capability_match[1]
        end
      end
      if map_text.start_with?("HashMap<") && map_text.end_with?(">")
        arguments = split_top_level_clear_list(map_text.delete_prefix("HashMap<").delete_suffix(">"))
        capability_suffix = map_capabilities.empty? ? "" : "#{map_capabilities} "
        if arguments.length == 2
          return "{#{inline_collection_type(arguments[0])}}#{capability_suffix}#{inline_collection_type(arguments[1])}"
        end
        return "{}#{capability_suffix}#{inline_collection_type(arguments.first)}" if arguments.one?
      end

      generic_open = text.index("<")
      if generic_open && text.end_with?(">")
        name = text[0...generic_open]
        arguments = split_top_level_clear_list(text[(generic_open + 1)...-1])
        return "#{name}<#{arguments.map { |argument| inline_collection_type(argument) }.join(', ')}>"
      end
      text
    end
    public :inline_collection_type

    def rendered_file_require(path)
      if @source_path && @helper_config.modular_dependencies?
        dependency_source = File.expand_path(path.sub(/\.clear\z/, ".rb"), File.dirname(@source_path))
        if (package = @helper_config.dependency_package_for(dependency_source))
          namespace = File.basename(path, ".clear").gsub(/[^a-zA-Z0-9_]/, "_").sub(/\A(\d)/, '_\\1')
          return "REQUIRE \"pkg:#{package}\" AS #{namespace}"
        end
      end

      "REQUIRE \"#{path}\""
    end

    # CLEAR currently parses `alias` as a field declaration but does not
    # retain it in the annotator's struct-field registry. Normalize the field
    # identity once, consistently across declarations, literals, and reads.
    def normalize_reserved_field_names(code)
      code.to_s
        .gsub(/\.alias\b/, ".alias_value")
        .gsub(/\balias:/, "alias_value:")
    end

    def emitted_field_identity(field)
      field.to_s == "alias" ? "alias_value" : field.to_s
    end

    def normalize_all_union_types!
      # Flatten/expand nested unions first
      @union_types.each_key do |union_name|
        members = @union_types[union_name]
        next unless members

        @union_types[union_name] = members.flat_map do |member|
          expanded = expand_non_emitted_type_alias(member).to_s.delete_prefix("?")
          nested = @union_types[expanded]
          flatten_nested = !@closed_interface_unions.include?(expanded) || expanded == "Locatable"
          nested && expanded != union_name && flatten_nested ? nested : [expanded]
        end.uniq
      end

      # Resolve capabilities using final class metadata for all union members
      @union_types.each_key do |union_name|
        @union_types[union_name] = if @closed_interface_unions.include?(union_name)
          @union_types[union_name].uniq
        else
          @union_types[union_name].map { |m| clear_type_expr(m) }.uniq
        end
      end
    end

    # Field metadata is collected while recursively walking declarations.
    # At that point a class may have been seen as reference-backed before a
    # later/imported `ruby-to-clear: value` declaration finalizes its model.
    # Remove those provisional carrier markers after the complete class set is
    # known, just as @aliasable_classes is finalized above. Otherwise an
    # emitted plain field (`type: Type`) is read semantically as
    # `Type@multiowned`, producing the invalid `COPY KEEP owner.field` pair.
    def normalize_value_class_field_types!
      value_names = @value_classes.to_a.sort_by { |name| -name.length }
      return if value_names.empty?

      @class_instance_field_types.each_value do |fields|
        fields.transform_values! do |type|
          value_names.reduce(type.to_s) do |normalized, name|
            normalized.gsub(
              /(?<![A-Za-z0-9_:])#{Regexp.escape(name)}@(?:multiowned|shared)\b/,
              name
            )
          end
        end
      end
      @class_instance_field_type_cache.clear
    end

    def normalize_imported_union_alias_members!
      @imported_union_names.each do |union_name|
        members = @union_types[union_name]
        next unless members

        @union_types[union_name] = members.flat_map do |member|
          expanded = expand_non_emitted_type_alias(member).to_s.delete_prefix("?")
          nested = @union_types[expanded]
          flatten_nested = !@closed_interface_unions.include?(expanded) || expanded == "Locatable"
          nested && expanded != union_name && flatten_nested ? nested : [expanded]
        end.uniq
      end
    end

    def collect_constant_storage_names_from_node(node)
      return unless node

      if node.is_a?(Prism::ConstantWriteNode) &&
         !struct_new_field_names(node.value) &&
         !sorbet_call?(node.value, "type_alias")
        name = node.name.to_s
        storage_name = constant_variable_name(name)
        @constant_names[name] = storage_name
        if declaration_comment?(node, "ruby-to-clear: data-api")
          @local_data_constant_names << name
        end
        value_node = node.value
        if (typed_value = sorbet_typed_value(node.value))
          @constant_types[name] = typed_value[1]
          @constant_types[storage_name] = typed_value[1]
          value_node = typed_value[0]
        end
        if value_node.is_a?(Prism::CallNode) && value_node.name.to_s == "freeze" &&
           !frozen_array_literal(value_node)
          # A frozen non-array constant is either a real module CONST (comptime
          # pure, referenced by name) or is inlined and reconstructed (owned) at
          # each use site. Either way it is not shared, so type it plain: the
          # `@multiowned` sigil an aliasable class carries is a sharing fiction
          # that would force a fallible ownership CAST when the constant feeds a
          # plain value parameter (e.g. a `= X::AFFINE` default).
          const_type = (@constant_types[name] || "").to_s.sub(/@(?:multiowned|shared)\z/, "")
          unless const_type.empty?
            @constant_types[name] = const_type
            @constant_types[storage_name] = const_type
          end
          @constant_inline_nodes[name] ||= value_node unless module_const_emittable?(storage_name, const_type)
        end
      end
      node.child_nodes.each { |child| collect_constant_storage_names_from_node(child) if child }
    end

    def collect_static_type_arrays_from_node(node)
      return unless node

      if node.is_a?(Prism::ConstantWriteNode)
        value = node.value
        value = value.arguments.arguments.first if sorbet_call?(value, "let")
        value = value.receiver if value.is_a?(Prism::CallNode) && value.name.to_s == "freeze"
        if value.is_a?(Prism::ArrayNode) && value.elements.any?
          types = value.elements.map { |element| static_type_name(element) }
          @static_type_arrays[node.name.to_s] = types if types.all?
        end
      end
      node.child_nodes.each { |child| collect_static_type_arrays_from_node(child) if child }
    end

    def collect_imported_data_constant_names_from_node(node)
      return unless node

      if node.is_a?(Prism::ConstantWriteNode) && declaration_comment?(node, "ruby-to-clear: data-api")
        @imported_data_constant_names << node.name.to_s
      end
      node.child_nodes.each { |child| collect_imported_data_constant_names_from_node(child) if child }
    end

    def generated_union_definitions_for_body(body)
      public_declarations = public_api_declarations(body)
      union_candidates = (@generated_union_defs.keys + @body_union_defs.to_a).uniq
      public_union_names = union_candidates.select do |name|
        public_declarations.any? { |declaration| type_name_referenced?(declaration, name) }
      end.to_set

      loop do
        newly_public = union_candidates.reject { |name| public_union_names.include?(name) }.select do |name|
          public_union_names.any? do |public_name|
            definition = @generated_union_defs[public_name] ||
              union_definition(public_name, @union_types.fetch(public_name))
            type_name_referenced?(definition, name)
          end
        end
        break if newly_public.empty?

        public_union_names.merge(newly_public)
      end

      public_union_names.each do |name|
        body = body.sub(/^UNION #{Regexp.escape(name)}\b/, "PUB UNION #{name}")
      end

      @generated_union_defs.each_key do |name|
        visibility = public_union_names.include?(name) ? "PUB " : ""
        @generated_union_defs[name] = union_definition(name, @union_types[name], visibility: visibility)
      end

      selected = {}

      loop do
        changed = false
        @generated_union_defs.keys.sort.each do |name|
          next if @body_union_defs.include?(name) || selected.key?(name)
          next if @imported_union_names.include?(name)
          next if name == "Node" && @required_files.any? { |path| path.end_with?("ast.clear") }

          haystacks = [body] + selected.values
          next unless haystacks.any? { |text| type_name_referenced?(text, name) }

          selected[name] = @generated_union_defs[name]
          changed = true
        end
        break unless changed
      end

      [body, selected.keys.sort.map { |name| selected[name] }]
    end

    def public_api_declarations(body)
      declarations = []
      current = nil
      brace_depth = 0

      body.each_line do |line|
        if current
          current << line
          brace_depth += line.count("{") - line.count("}")
          if brace_depth <= 0
            declarations << current
            current = nil
          end
          next
        end

        next unless line.start_with?("PUB ")

        if line.match?(/\APUB (?:STRUCT|UNION|ENUM)\b/) && line.include?("{")
          current = +line
          brace_depth = line.count("{") - line.count("}")
          if brace_depth <= 0
            declarations << current
            current = nil
          end
        else
          declarations << line
        end
      end
      declarations << current if current
      declarations
    end

    def type_name_referenced?(text, name)
      !!text.match?(/\b#{Regexp.escape(name)}\b/)
    end

    def visit(node)
      return "" unless node
      return @node_code_overrides[node.object_id] if @node_code_overrides.key?(node.object_id)
      structural_key = [node.class.name, node.location.slice]
      return @structural_code_overrides[structural_key] if @structural_code_overrides.key?(structural_key)

      node_name = node.class.name.split("::").last
      method_name = "visit_#{node_name.gsub(/(?<!^)(?=[A-Z])/, '_').downcase}"
      if respond_to?(method_name, true)
        send(method_name, node)
      else
        raise_unsupported("Unsupported node #{node_name}", node)
      end
    end

    def with_node_code_override(node, code)
      key = node.object_id
      had_previous = @node_code_overrides.key?(key)
      previous = @node_code_overrides[key]
      @node_code_overrides[key] = code
      yield
    ensure
      had_previous ? @node_code_overrides[key] = previous : @node_code_overrides.delete(key)
    end

    def with_structural_code_override(node, code)
      key = [node.class.name, node.location.slice]
      had_previous = @structural_code_overrides.key?(key)
      previous = @structural_code_overrides[key]
      @structural_code_overrides[key] = code
      yield
    ensure
      had_previous ? @structural_code_overrides[key] = previous : @structural_code_overrides.delete(key)
    end

    def with_renames(new_renames)
      old_renames = @renames.dup
      @renames.merge!(new_renames.compact)
      yield
    ensure
      @renames = old_renames
    end

    def with_block_local_scope
      old_declared = @declared_locals.dup
      old_shapes = @local_shapes.dup
      old_types = @local_types.dup
      yield
    ensure
      @declared_locals = old_declared
      @local_shapes = old_shapes
      @local_types = old_types
    end

    def with_local_types(new_types)
      old_types = @local_types.dup
      new_types.each do |name, type|
        @local_types[name] = type if type && type != "Auto" && type != "Any"
      end
      yield
    ensure
      @local_types = old_types
    end

    # Bind one local's type inside an active with_local_types scope, for
    # callers that discover types progressively (e.g. walking a block's own
    # assignments before inferring its final expression). Safe because
    # with_local_types restores the whole map on exit.
    def note_local_type(name, type)
      return if type.nil? || type == "Auto" || type == "Any"

      @local_types[name.to_s] = type
    end
    public :note_local_type

    def require_package(package)
      @required_packages << package.to_s
    end

    def mark_current_function_fallible!
      @current_function_can_fail = true
    end

    # Ruby commonly lets failed conversions become a sentinel value. CLEAR
    # keeps that failure visible: the generated boundary either handles it
    # deliberately or propagates it to the generated function contract.
    def propagate_fallible_expression(code)
      mark_current_function_fallible!
      "TRY (#{code})"
    end

    def allocating_collection_return_type?(type)
      text = type.to_s.delete_prefix("!").delete_prefix("?")
      text = text[1...-1] while text.start_with?("(") && text.end_with?(")")
      text.end_with?("[]") || text.end_with?("[]@set") || text.start_with?("HashMap<")
    end

    def known_fallible_method?(method_name, owner = nil)
      if owner
        resolved = resolve_qualified_class_name(owner) || owner.to_s
        return [resolved, resolved.to_s.split("::").last].any? do |candidate|
          @inherently_fallible_methods.include?(scoped_method_key(candidate, method_name))
        end
      end
      @inherently_fallible_methods.include?(method_name.to_s)
    end

    def propagate_known_fallible_call(code, method_name, owner = nil)
      return code unless known_fallible_method?(method_name, owner)

      mark_current_function_fallible!
      "TRY (#{code})"
    end
    public :propagate_known_fallible_call

    def function_signature_type_code(signature_code)
      helper = "rubyToClearTypeFromFunctionSignature"
      if @source_path
        param_source = @loaded_metadata_files.find { |path| path.end_with?("/ast/param.rb") }
        @required_files << clear_require_path_for_file(param_source) if param_source
      end
      @generated_cast_helper_defs[helper] ||= <<~CLEAR.chomp
        FN #{helper}(signature: FunctionSignature) RETURNS Type@multiowned ->
          function_type_from_parts(functionSignature__params(signature) |> SELECT param__type(_), functionSignature__return_type(signature), functionSignature__reentrant(signature), signature);
        END
      CLEAR
      call = "#{helper}(#{signature_code})"
      expected = @expected_expression_type.to_s
      if expected.include?("@multiowned") || expected.include?("@shared")
        call
      else
        "CAST(#{call} AS Type)"
      end
    end

    # AST.each_locatable walks every struct member via Struct reflection
    # (class.members); its CLEAR form is generated from the synthesized
    # Locatable union instead: a recursive borrow-based visit over the
    # generated children helper. Bodies stay in Ruby as the source of
    # truth for SEMANTICS (yield order, FunctionDef descent gate); the
    # generated form preserves both.
    def generated_each_locatable_definition(node)
      return nil unless node.name.to_s == "each_locatable" && node.receiver.is_a?(Prism::SelfNode)
      return nil unless @union_types.key?("Locatable")

      helper = ensure_union_children_helper("Locatable")
      return nil unless helper

      # The definition and every call site must agree under the uniform
      # singleton-prefix rule: derive the name exactly as callers do.
      fn_name = class_method_function_name(@current_class || "AST", "each_locatable")
      <<~CLEAR.chomp
        PUB FN #{fn_name}(root: Locatable, MUTABLE descend_functions: Bool, visitor: FN(Locatable) -> Void) RETURNS Void EFFECTS REENTRANT ->
          visitor(root);
          IF !(descend_functions) AND (root IS_A FunctionDef) THEN
            RETURN;
          END
          FOR rtoc_walk_child IN #{helper}(root) DO
            #{fn_name}(rtoc_walk_child, &descend_functions, visitor);
          END
        END
      CLEAR
    end

    # AST.each_child_node is the non-recursive sibling of each_locatable.
    # Its Ruby implementation uses Struct reflection, which CLEAR deliberately
    # does not expose. Generate it from the same closed Locatable-union facts
    # used by the recursive walker.
    def generated_each_child_node_definition(node)
      return nil unless node.name.to_s == "each_child_node" && node.receiver.is_a?(Prism::SelfNode)
      return nil unless @union_types.key?("Locatable")

      helper = ensure_union_children_helper("Locatable")
      return nil unless helper

      fn_name = class_method_function_name(@current_class || "AST", "each_child_node")
      <<~CLEAR.chomp
        PUB FN #{fn_name}(node: Locatable, visitor: FN(Locatable) -> Void) RETURNS Void EFFECTS REENTRANT ->
          FOR rtoc_walk_child IN #{helper}(node) DO
            visitor(rtoc_walk_child);
          END
        END
      CLEAR
    end

    # --- generated union child-walkers (each_pair struct reflection) ---
    #
    # Ruby AST/MIR walkers visit every struct member via each_pair
    # reflection. CLEAR has no reflection: generate, per union, a
    # `rtocChildren<Union>(node) RETURNS []<Union>` helper that MATCHes the
    # variants and appends each node-typed field (direct, optional, or
    # array), so the reflection sites lower to plain FOR loops.
    def ensure_union_children_helper(union)
      members = @union_types[union]
      return nil unless members

      helper = "rtocChildren#{union.gsub(/[^A-Za-z0-9]/, '')}"
      return helper if @generated_support_helper_defs.key?(helper)

      # Reserve the name first: member helpers for recursive shapes may
      # re-enter while we build.
      @generated_support_helper_defs[helper] = ""
      arms = []
      members.each do |member|
        member_text = member.to_s
        struct_name = member_text.split("@").first.to_s
        next if member_text.start_with?("[]", "{") # array/map payloads: elements are not this union
        next unless @struct_fields.key?(struct_name) || @struct_fields.key?(struct_name.split("::").last.to_s)

        appends = union_children_field_appends(union, struct_name)
        next if appends.empty?

        variant = union_variant_name(member, union)
        member_helper = "rtocChildrenOf#{union.gsub(/[^A-Za-z0-9]/, '')}#{variant}"
        @generated_support_helper_defs[member_helper] = <<~CLEAR.chomp
          FN #{member_helper}(v: #{member_text}) RETURNS []#{union} ->
            MUTABLE out: []#{union} = [];
          #{appends.map { |line| "  #{line}" }.join("\n")}
            RETURN out;
          END
        CLEAR
        arms << "    #{union}.#{variant} AS v -> RETURN #{member_helper}(v);,"
      end

      @generated_support_helper_defs[helper] = <<~CLEAR.chomp
        FN #{helper}(node: #{union}) RETURNS []#{union} ->
        #{arms.empty? ? "" : "  PARTIAL MATCH node START\n#{arms.join("\n")}\n  END\n"}  MUTABLE rtoc_no_children: []#{union} = [];
          RETURN rtoc_no_children;
        END
      CLEAR
      helper
    end
    public :ensure_union_children_helper

    # Append statements for every walkable field of `struct_name`, wrapped
    # back into `union`. Non-node fields (scalars, strings, foreign maps)
    # contribute nothing.
    def union_children_field_appends(union, struct_name)
      fields = @struct_fields[struct_name] || @struct_fields[struct_name.split("::").last.to_s] || []
      fields.filter_map do |field|
        type_text = class_instance_field_type(struct_name, field).to_s
        append_union_child_lines(union, "v.#{field}", type_text)
      end.flatten
    end

    def append_union_child_lines(union, code, type_text)
      text = type_text.delete_prefix("!")
      if text.start_with?("?")
        inner = text.delete_prefix("?")
        inner_lines = append_union_child_lines(union, "rtoc_opt_child", inner)
        return nil if inner_lines.nil?

        return ["IF #{code} EXISTS AS rtoc_opt_child THEN"] +
               inner_lines.map { |l| "  #{l}" } + ["END"]
      end
      if text.start_with?("[]")
        inner = text.delete_prefix("[]")
        inner_lines = append_union_child_lines(union, "rtoc_arr_child", inner)
        return nil if inner_lines.nil?

        return ["FOR rtoc_arr_child IN #{code} DO"] +
               inner_lines.map { |l| "  #{l}" } + ["END"]
      end

      base = text.split("@").first.to_s
      members = @union_types[union] || []
      if base == union
        ["&out.append(COPY #{code});"]
      elsif @union_types.key?(base)
        cast = union_subset_cast_code("COPY #{code}", base, union)
        cast ? ["&out.append(#{cast});"] : nil
      elsif members.any? { |m| m.to_s.split("@").first == base }
        member = members.find { |m| m.to_s.split("@").first == base }
        ["&out.append(#{union}{ #{union_variant_name(member, union)}: COPY #{code} });"]
      end
    end

    def current_class_name
      @current_class
    end

    def helper_config
      @helper_config
    end

    def scanner_scan_value_node?(node)
      @scanner_scan_value_nodes.include?(node.object_id)
    end

    def untyped_type
      @helper_config.untyped_type
    end

    def regex_literal_code(pattern_code, interpolated: false)
      if interpolated
        @helper_config.regex_interpolated_literal(pattern_code)
      else
        @helper_config.regex_literal(pattern_code)
      end
    end

    def generated_regex_constant_defs
      []
    end

    def regex_match_code(subject_code, pattern_code)
      @helper_config.call_or(:regex_match, "regexMatch?", [subject_code, pattern_code])
    end

    def regex_match_data_code(subject_code, pattern_code)
      @helper_config.call(:regex_match_data, [subject_code, pattern_code])
    end

    def regex_replace_all_code(subject_code, pattern_code, replacement_code)
      @helper_config.call_or(:regex_replace_all, "regexReplaceAll", [subject_code, pattern_code, replacement_code])
    end

    def regex_replace_first_code(subject_code, pattern_code, replacement_code)
      @helper_config.call_or(:regex_replace_first, "regexReplaceFirst", [subject_code, pattern_code, replacement_code])
    end

    def regex_gsub_block_code(node, pattern_node)
      receiver = string_conversion_code(node.receiver, method_call_receiver_expression(node.receiver))
      pattern = visit(pattern_node)
      scanner = next_generated_local("gsub_scanner")
      output = next_generated_local("gsub_output")
      matched = @helper_config.call_or(:scanner_matched, "scannerMatched", [scanner])

      previous_scanner = @active_regex_scanner
      @active_regex_scanner = scanner
      lowering = MethodRegistry.lower_literal_block(
        node,
        node.block,
        self,
        "gsub",
        min_params: 0,
        max_params: 1,
        rename: ->(names) { names.empty? ? {} : { names.first => matched } },
        local_types: ->(names) { names.empty? ? {} : { names.first => "String" } },
      )
      @active_regex_scanner = previous_scanner
      return lowering if MethodRegistry.unsupported_result?(lowering)

      scan = @helper_config.call_or(:scanner_scan, "scannerScan", [scanner, pattern])
      eos = @helper_config.call_or(:scanner_eos, "scannerEos", [scanner])
      getch = @helper_config.call_or(:scanner_getch, "scannerGetch", [scanner])
      scanner_new = @helper_config.call_or(:scanner_new, "scannerNew", [receiver])
      char = next_generated_local("gsub_char")
      "{\n" \
        "  MUTABLE rtoc_value_block_marker = 0;\n" \
        "  #{scanner} = #{scanner_new};\n" \
        "  MUTABLE #{output} = \"\";\n" \
        "  WHILE !(#{eos}) DO\n" \
        "    IF #{scan} THEN\n" \
        "      #{output} = (#{output} $+ #{lowering.value_code});\n" \
        "    ELSE\n" \
        "      IF #{getch} EXISTS AS #{char} THEN\n" \
        "        #{output} = (#{output} $+ COPY #{char});\n" \
        "      END\n" \
        "    END\n" \
        "  END\n" \
        "  #{output}\n" \
        "}"
    ensure
      @active_regex_scanner = previous_scanner if defined?(previous_scanner)
    end

    def regex_scan_block_code(node, pattern_node)
      receiver = string_conversion_code(node.receiver, method_call_receiver_expression(node.receiver))
      pattern = visit(pattern_node)
      scanner = next_generated_local("scan_scanner")

      previous_scanner = @active_regex_scanner
      @active_regex_scanner = scanner
      lowering = MethodRegistry.lower_literal_block(
        node,
        node.block,
        self,
        "scan",
        min_params: 1,
        max_params: 16,
        rename: lambda do |names|
          if names.length == 1
            capture = @helper_config.call_or(:scanner_capture, "scannerCapture", [scanner, "1"])
            { names.first => "[COPY #{capture}]" }
          else
            names.each_with_index.to_h do |name, index|
              capture = @helper_config.call_or(:scanner_capture, "scannerCapture", [scanner, (index + 1).to_s])
              [name, "COPY #{capture}"]
            end
          end
        end,
        allow_next: true,
        local_types: lambda do |names|
          names.length == 1 ? { names.first => "[]String" } : names.to_h { |name| [name, "String"] }
        end,
      )
      @active_regex_scanner = previous_scanner
      return lowering if MethodRegistry.unsupported_result?(lowering)

      scan = @helper_config.call_or(:scanner_scan, "scannerScan", [scanner, pattern])
      eos = @helper_config.call_or(:scanner_eos, "scannerEos", [scanner])
      getch = @helper_config.call_or(:scanner_getch, "scannerGetch", [scanner])
      scanner_new = @helper_config.call_or(:scanner_new, "scannerNew", [receiver])
      effect = lowering.effect_code.lines.map { |line| "      #{line.rstrip}" }.join("\n")
      "{\n" \
        "  MUTABLE rtoc_value_block_marker = 0;\n" \
        "  #{scanner} = #{scanner_new};\n" \
        "  WHILE !(#{eos}) DO\n" \
        "    IF #{scan} THEN\n" \
        "#{effect}\n" \
        "    ELSE\n" \
        "      #{getch};\n" \
        "    END\n" \
        "  END\n" \
        "  NIL\n" \
        "}"
    ensure
      @active_regex_scanner = previous_scanner if defined?(previous_scanner)
    end
    public :regex_scan_block_code

    def regex_last_match_code(node)
      return nil unless @active_regex_scanner

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length == 1

      # Scanner captures borrow storage owned by the scanner. Ruby locals keep
      # the matched String independently, so retain it at the boundary instead
      # of creating a mutable borrowed local (which CLEAR correctly requires
      # to be RESTRICT).
      "COPY #{@helper_config.call_or(:scanner_capture, "scannerCapture", [@active_regex_scanner, visit(args.first)])}"
    end
    public :regex_last_match_code

    def regex_escape_code(value_code)
      @helper_config.call_or(:regex_escape, "escapeRegex", [value_code])
    end

    def regex_capture_code(number_code)
      @helper_config.call_or(:regex_capture, "regexCapture", [number_code])
    end

    def regex_pattern_code(value_code)
      @helper_config.call(:regex_pattern, [value_code]) || value_code
    end

    def integer_conversion_code(receiver_node, receiver_code)
      receiver_type = inferred_clear_type_for_node(receiver_node)
      cast = union_payload_cast_code(receiver_code, receiver_type, "Int64")
      return cast if cast

      call = "#{method_receiver_code(receiver_code)}.toInt()"
      # Only String.toInt() can fail (bad digits); the numeric overloads are
      # total, so TRY on them is an unwrap of a non-optional Int64 and the
      # frontend rejects it.
      base = receiver_type.to_s.delete_prefix("?").split("@").first
      return call if %w[Int64 Float64 UInt64].include?(base)

      propagate_fallible_expression(call)
    end

    def string_conversion_code(receiver_node, receiver_code)
      receiver_type = inferred_clear_type_for_node(receiver_node)
      union_payload_cast_code(receiver_code, receiver_type, "String") || receiver_code
    end

    public :helper_config, :untyped_type, :function_signature_type_code, :current_class_name, :regex_literal_code, :regex_match_code, :regex_match_data_code, :regex_replace_all_code,
           :regex_replace_first_code, :regex_escape_code, :regex_capture_code, :regex_pattern_code, :integer_conversion_code, :string_conversion_code,
           :propagate_fallible_expression

    def raise_unsupported(message, node)
      loc = node.location
      source_loc = "#{@source[0...loc.start_offset].count("\n") + 1}:#{loc.start_column}"
      err_msg = "Unsupported Ruby syntax: #{message} at line #{source_loc}\nSource: #{loc.slice.strip}"
      
      if @raise_on_error
        raise TranspilationError, err_msg
      else
        unsupported_comment(node, message)
      end
    end

    def simple_block_expression?(block_node)
      body_node = block_node.body
      return false unless body_node.is_a?(Prism::StatementsNode)
      return false unless body_node.body.size == 1
      pure_expression?(body_node.body.first)
    end

    def pure_expression?(node)
      return false unless node
      case node.class.name.split("::").last
      when "CallNode", "LocalVariableReadNode", "InstanceVariableReadNode", "IntegerNode", "StringNode", "SymbolNode", "SelfNode",
           "AndNode", "OrNode", "ParenthesesNode", "NilNode", "FalseNode", "TrueNode",
           "ArrayNode", "HashNode", "RangeNode", "ConstantReadNode", "ConstantPathNode"
        true
      else
        false
      end
    end

    private

    def collection_element_type(type)
      text = type.to_s
      return text if text == "String@symbol"

      strip_top_level_capability(text)
    end

    def map_element_type(type)
      text = type.to_s
      return text if text == "String@symbol"

      strip_top_level_capability(text)
    end

    # Group-1 sync wrappers a collection element sheds. Ownership handles
    # (@multiowned/@shared) and data-shape/layout capabilities (@symbol,
    # @set, @list, @boxed, ...) are part of the element type: stripping at
    # the first unknown `@` truncated `String@symbol[]@set` to `String`,
    # collapsing set/array-valued map declarations.
    STRIPPED_ELEMENT_SYNC_CAPS = %w[@locked @writeLocked @local].freeze

    def strip_top_level_capability(text)
      depth = 0
      text.each_char.with_index do |char, index|
        depth += 1 if "<[(".include?(char)
        depth -= 1 if ">])".include?(char)
        if char == "@" && depth.zero? &&
           STRIPPED_ELEMENT_SYNC_CAPS.any? { |cap| text[index..].start_with?(cap) }
          return text[0...index]
        end
      end
      text
    end

    def indent
      "  " * @indent_level
    end

    def with_indent
      @indent_level += 1
      yield
    ensure
      @indent_level -= 1
    end

    def with_expected_expression_type(type)
      old_type = @expected_expression_type
      @expected_expression_type = type
      yield
    ensure
      @expected_expression_type = old_type
    end

    def expected_expression_type
      @expected_expression_type
    end
    public :with_expected_expression_type, :expected_expression_type

    def format_statement_code(code, force_block: false)
      if (unwrapped = unwrap_statement_value_block(code))
        code = unwrapped
      end
      unless force_block || code.end_with?(";") || block_statement_output?(code) || code.lstrip.start_with?("#")
        code = "#{code};"
      end

      code.split("\n").map { |line| line.start_with?(" ") ? line : "#{indent}#{line}" }.join("\n")
    end

    def clear_string_literal(content)
      # Always emit the escaped single-line form: a triple-quoted literal
      # would absorb the generator's indentation into the string value.
      #
      # A literal `${` cannot be spelled inside one CLEAR string (it opens
      # interpolation, and `\$` is not a CLEAR escape), so split it into a
      # concat expression: "a" $+ "$" $+ "{" $+ "b".
      segments = content.split("${", -1)
      if segments.length <= 1
        "\"#{clear_string_escape(content)}\""
      else
        pieces = []
        segments.each_with_index do |segment, index|
          pieces << "\"$\"" << "\"{\"" if index.positive?
          pieces << "\"#{clear_string_escape(segment)}\"" unless segment.empty?
        end
        "(#{pieces.join(' $+ ')})"
      end
    end

    def clear_string_escape(content)
      codepoints = content.codepoints
      codepoints.each_with_index.map do |codepoint, index|
        case codepoint
        when 0x08 then "\\b"
        when 0x09 then "\\t"
        when 0x0A then "\\n"
        when 0x0D then "\\r"
        when 0x22 then "\\\""
        when 0x5C then "\\\\"
        when 0x24
          # `${` never reaches this escaper - clear_string_literal splits
          # it into a concat - so a lone dollar is always literal.
          "$"
        else
          if codepoint < 0x20 || codepoint == 0x7F
            "\\x#{codepoint.to_s(16).upcase.rjust(2, '0')}"
          elsif codepoint > 0x7E
            "\\u{#{codepoint.to_s(16).upcase}}"
          else
            codepoint.chr(Encoding::UTF_8)
          end
        end
      end.join
    end

    def translate_rspec_call(node)
      return nil if @typed_ir.call_for(node)
      return translate_rspec_suite(node) if rspec_suite_call?(node)
      return nil unless rspec_dsl_call?(node)

      case node.name.to_s
      when "describe", "context"
        rspec_when_blocks(node).join("\n")
      when "it", "specify"
        translate_rspec_example(node)
      when "to", "not_to"
        translate_rspec_expectation(node)
      end
    end

    def rspec_suite_call?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.name.to_s == "describe"

      receiver = node.receiver
      receiver.is_a?(Prism::ConstantReadNode) && receiver.name.to_s == "RSpec"
    end

    def rspec_dsl_call?(node)
      node.is_a?(Prism::CallNode) && ["describe", "context", "it", "specify", "to", "not_to"].include?(node.name.to_s)
    end

    def translate_rspec_suite(node)
      name = test_block_name(rspec_description(node))
      body = rspec_block_statements(node)
      setup_nodes, group_nodes, example_nodes = partition_rspec_body(body)
      setup = setup_nodes.map { |stmt| format_statement_code(visit(stmt)) }.reject(&:empty?)
      whens = group_nodes.flat_map { |group| rspec_when_blocks(group) }
      if example_nodes.any?
        whens << render_rspec_when("examples", [], example_nodes)
      end

      sections = setup + whens
      inner = sections.empty? ? "" : with_indent { sections.map { |section| indent_multiline(section) }.join("\n") }
      "TEST #{name} DO\n#{inner}\nEND"
    end

    def rspec_when_blocks(node, prefix = nil, inherited_setup = [])
      desc = rspec_description(node)
      full_desc = [prefix, desc].compact.reject(&:empty?).join(" / ")
      body = rspec_block_statements(node)
      setup_nodes, group_nodes, example_nodes = partition_rspec_body(body)
      setup = inherited_setup + setup_nodes.map { |stmt| format_statement_code(visit(stmt)) }.reject(&:empty?)

      blocks = []
      blocks << render_rspec_when(full_desc, setup, example_nodes) if example_nodes.any?
      group_nodes.each do |group|
        blocks.concat(rspec_when_blocks(group, full_desc, setup))
      end
      blocks
    end

    def render_rspec_when(desc, setup, example_nodes)
      body_sections = setup + example_nodes.map { |example| translate_rspec_example(example) }
      body = with_indent { body_sections.map { |section| indent_multiline(section) }.join("\n") }
      "WHEN #{clear_string_literal(desc)} DO\n#{body}\nEND"
    end

    def translate_rspec_example(node)
      desc = rspec_description(node)
      body_code = with_indent { visit(node.block&.body) }
      "TEST THAT #{clear_string_literal(desc)} DO\n#{body_code}\nEND"
    end

    def translate_rspec_expectation(node)
      expected_positive = node.name.to_s == "to"
      expect_call = node.receiver
      return nil unless expect_call&.name.to_s == "expect"

      matcher = node.arguments&.arguments&.first
      return unsupported_expression(node, "RSpec expectation without matcher is not supported") unless matcher

      if matcher.is_a?(Prism::CallNode) && matcher.name.to_s == "raise_error"
        return translate_rspec_raise_error(expect_call, matcher)
      end

      actual_arg = expect_call.arguments&.arguments&.first
      return unsupported_expression(expect_call, "RSpec block expectations only support raise_error") unless actual_arg

      actual = visit(actual_arg)
      assertion = rspec_matcher_assertion(actual, matcher, expected_positive)
      return assertion if assertion

      unsupported_expression(matcher, "RSpec matcher #{matcher.location.slice.strip} is not supported")
    end

    def translate_rspec_raise_error(expect_call, matcher)
      block_body = expect_call.block&.body
      unless block_body.is_a?(Prism::StatementsNode) && block_body.body.length == 1
        return unsupported_expression(expect_call, "RSpec raise_error needs a single-expression block")
      end

      expr = visit(block_body.body.first).delete_suffix(";")
      args = matcher.arguments ? matcher.arguments.arguments : []
      kind = if args.first&.location&.slice&.include?("ParserError")
        "Input"
      else
        "Input"
      end
      "ASSERT_RAISES #{kind}, #{expr}"
    end

    def rspec_matcher_assertion(actual, matcher, positive)
      return nil unless matcher.is_a?(Prism::CallNode)

      args = matcher.arguments ? matcher.arguments.arguments : []
      pred = case matcher.name.to_s
      when "eq"
        return nil unless args.length == 1

        "#{actual} == #{visit(args.first)}"
      when "be"
        return nil unless args.length == 1

        "#{actual} == #{visit(args.first)}"
      when "be_nil"
        "#{actual} == NIL"
      when "be_truthy"
        actual
      when "be_falsey"
        "!(#{actual})"
      when "be_a", "be_an"
        return nil unless args.length == 1

        type_name = static_type_name(args.first)
        return nil unless type_name

        "isA?(#{actual}, #{type_name.inspect})"
      when "all"
        return nil unless args.length == 1
        nested = args.first
        return nil unless nested.is_a?(Prism::CallNode) && ["be_a", "be_an"].include?(nested.name.to_s)

        nested_args = nested.arguments ? nested.arguments.arguments : []
        return nil unless nested_args.length == 1

        type_name = static_type_name(nested_args.first)
        return nil unless type_name

        "#{actual} |> ALL isA?(_, #{type_name.inspect})"
      when "include"
        return nil if args.empty?

        args.map { |arg| "#{actual}.contains?(#{visit(arg)})" }.join(" AND ")
      end
      return nil unless pred

      pred = "!(#{pred})" unless positive
      "ASSERT #{pred}, #{clear_string_literal(rspec_assertion_message(actual, matcher, positive))}"
    end

    def rspec_assertion_message(actual, matcher, positive)
      expectation = positive ? "to" : "not_to"
      "expected #{actual} #{expectation} #{matcher.location.slice.strip}"
    end

    def static_type_name(node)
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        node.location.slice.strip
      when Prism::StringNode
        node.content
      when Prism::SymbolNode
        node.value.to_s
      end
    end

    RUBY_TYPE_TO_CLEAR_TYPE = {
      "Integer" => "Int64",
      "Float" => "Float64",
      "String" => "String",
      "StringScanner" => "Scanner",
      "Symbol" => "String@symbol",
      "NilClass" => "Void",
      "Boolean" => "Bool",
      "TrueClass" => "Bool",
      "FalseClass" => "Bool",
      "Numeric" => "Float64",
      "BasicObject" => "Any",
      "Proc" => "Any",
      "Array" => "Any[]",
      "Hash" => "HashMap<Any>",
      "Set" => "[Set]Any",
    }.freeze

    def resolve_type_with_aliasable(type_str)
      return type_str unless type_str
      return type_str if @in_function_signature
      base = type_str.to_s.delete_prefix("?").split("@").first.to_s.delete_suffix("[]")
      if @aliasable_classes&.include?(base) || base == "Any"
        apply_multiowned_sigil(type_str)
      else
        type_str
      end
    end

    def clear_type_name_for_emit(type_str)
      return type_str unless type_str
      parts = type_str.to_s.split("@")
      base = parts.first
      optional = base.start_with?("?")
      base_name = base.delete_prefix("?")
      mapped_base = @helper_config.clear_type(base_name) || clear_constant_type_name(base_name)
      mapped_base = "?#{mapped_base}" if optional
      parts[0] = mapped_base
      parts.join("@")
    end

    def clear_type_expr(ruby_type_name)
      raw = ruby_type_name.to_s
      res = @helper_config.clear_type(raw) ||
        RUBY_TYPE_TO_CLEAR_TYPE.fetch(raw) { clear_constant_type_name(raw) }
      resolve_type_with_aliasable(res)
    end

    def clear_constant_type_name(raw)
      text = raw.to_s
      optional = text.start_with?("?")
      base = text.delete_prefix("?").delete_prefix("::")
      emitted = @emitted_type_names[base]
      emitted ||= @local_emitted_type_names_by_basename[base] unless base.include?("::") || base.include?(".")
      return optional ? "?#{emitted}" : emitted if emitted
      if @type_aliases&.key?(base)
        res = camel_type_name(base)
        return optional ? "?#{res}" : res
      end
      if base.match?(/\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)+\z/)
        res = base.split("::").last
        return optional ? "?#{res}" : res
      end
      if base.match?(/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)+\z/)
        res = base.split(".").last
        return optional ? "?#{res}" : res
      end

      optional ? "?#{base}" : base
    end

    public :clear_type_expr

    def partition_rspec_body(body)
      setup = []
      groups = []
      examples = []
      body.each do |stmt|
        if rspec_group_node?(stmt)
          groups << stmt
        elsif rspec_example_node?(stmt)
          examples << stmt
        else
          setup << stmt
        end
      end
      [setup, groups, examples]
    end

    def rspec_group_node?(node)
      node.is_a?(Prism::CallNode) && ["describe", "context"].include?(node.name.to_s) && node.block
    end

    def rspec_example_node?(node)
      node.is_a?(Prism::CallNode) && ["it", "specify"].include?(node.name.to_s) && node.block
    end

    def rspec_block_statements(node)
      body = node.block&.body
      return [] unless body.is_a?(Prism::StatementsNode)

      body.body
    end

    def rspec_description(node)
      arg = node.arguments&.arguments&.first
      case arg
      when Prism::StringNode
        arg.content
      when Prism::SymbolNode
        arg.value.to_s
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        arg.location.slice.strip.split("::").last
      else
        node.name.to_s
      end
    end

    def test_block_name(description)
      words = description.to_s.scan(/[A-Za-z0-9]+/)
      name = words.map { |word| word[0].upcase + word[1..].to_s }.join
      name = "RSpec" if name.empty?
      name = "RSpec#{name}" unless name.match?(/\A[A-Z]/)
      name
    end

    def indent_multiline(code)
      code.split("\n").map { |line| line.empty? ? line : "#{indent}#{line}" }.join("\n")
    end

    def class_variable_name(name)
      name.to_s.delete_prefix("@@")
    end

    def class_storage_variable_name(name)
      base = name.to_s.delete_prefix("@")
      @emitted_function_names.include?(clear_function_name(base)) ? "#{base}_value" : base
    end

    def clear_function_name(name)
      raw = name.to_s
      return "initialize" if raw == "initialize"
      return "equals?" if raw == "=="
      return "not_equals?" if raw == "!="
      return "get_index" if raw == "[]"
      return "set_index" if raw == "[]="
      return "lte?" if raw == "<="
      return "gte?" if raw == ">="
      return "set_#{raw.delete_suffix('=')}" if raw.end_with?("=")
      return "lt?" if raw == "<"
      return "gt?" if raw == ">"
      return "#{raw.delete_suffix('!')}_mut" if raw.end_with?("!")

      raw
    end

    def clear_binary_operator(operator)
      {
        "&&" => "AND",
        "||" => "OR",
        "&" => "BIT_AND",
        "|" => "BIT_OR",
        "^" => "XOR",
        "%" => "MOD"
      }.fetch(operator.to_s, operator.to_s)
    end

    def mutable_storage_path?(code)
      code.to_s.match?(/\A(?:[a-z_]\w*|self)(?:(?:\.[A-Za-z_]\w*)|(?:\[[^\[\]\n]+\]))*\z/)
    end

    def mutable_argument_code(code)
      rendered = code.to_s
      return rendered if rendered.start_with?("&") || !mutable_storage_path?(rendered)

      "&#{rendered}"
    end

    def mutable_method_receiver_code(code)
      mutable_argument_code(method_receiver_code(code))
    end
    public :clear_binary_operator, :mutable_argument_code, :mutable_method_receiver_code

    def next_generated_local(prefix)
      @generated_local_index += 1
      "rtoc_#{prefix}_#{@generated_local_index}"
    end
    public :next_generated_local

    def static_respond_to_result(receiver_code, method_name, receiver_node = nil)
      receiver_type = clear_type_for_receiver_node(receiver_node)
      receiver_type ||= if receiver_code.nil? || receiver_code == "self"
        @current_class
      elsif receiver_code.to_s.match?(/\A[A-Za-z_]\w*\z/)
        @local_types[receiver_code.to_s]
      end

      clear_name = clear_function_name(method_name)
      # `respond_to?(:each_pair)` on a union-typed node guards struct-member
      # reflection. The generated children walker returns an empty list for
      # scalar variants, so the guard is statically TRUE.
      if method_name.to_s == "each_pair" && receiver_type
        union = receiver_type.to_s.delete_prefix("?").split("@").first.to_s
        return true if @union_types.key?(union)
      end
      unless receiver_type
        return true if unique_instance_method_owner(clear_name)

        # Unknown receiver: neither TRUE nor FALSE is provable statically.
        return nil
      end

      type_names = type_lookup_names(receiver_type)
      field_name = method_name.to_s.delete_suffix("=")
      return true if shared_union_field_type(receiver_type, field_name)
      return true if type_names.any? { |name| @class_instance_field_names[name].include?(field_name) }
      return true if type_names.any? { |name| @class_instance_method_names[name].include?(clear_name) }

      # FALSE is only provable for a class whose definition we collected;
      # any other type stays undecided so shape folding or the dynamic
      # respondsTo? helper can answer instead.
      known_class = type_names.any? do |name|
        @class_instance_field_names.fetch(name, nil)&.any? ||
          @class_instance_method_names.fetch(name, nil)&.any?
      end
      known_class ? false : nil
    end
    public :static_respond_to_result

    def mutable_parameter_function_name?(name)
      @mutable_parameter_function_names.include?(name.to_s)
    end

    def constant_variable_name(name)
      base = name.to_s.downcase
      @emitted_function_names.include?(base) || CLEAR_KEYWORDS.include?(base.upcase) ? "#{base}_value" : base
    end

    def simple_multi_target_names(param)
      return nil unless param.is_a?(Prism::MultiTargetNode)
      return nil if param.rest || param.rights.any?
      return nil unless param.lefts.all? { |left| left.respond_to?(:name) }

      param.lefts.map { |left| left.name.to_s }
    end

    def block_lambda_parameters(block_node)
      params_node = block_node.parameters&.parameters
      return LambdaParameters.new(parameter_names: [], scope_names: [], scope_types: {}, setup_lines: []) unless params_node

      if params_node.optionals.any? || params_node.rest || params_node.posts.any? ||
         params_node.keywords.any? || params_node.keyword_rest || params_node.block
        return unsupported_expression(block_node.parameters, "Block parameter shape is not supported")
      end

      parameter_names = []
      scope_names = []
      scope_types = {}
      setup_lines = []
      renames = {}
      params_node.requireds.each_with_index do |param, index|
        if param.respond_to?(:name)
          ruby_name = param.name.to_s
          clear_name = clear_lambda_parameter_name(ruby_name, index)
          closure_parameter = @typed_ir.closure_for(block_node)&.parameters&.fetch(ruby_name, nil)
          closure_parameter = closure_parameter.to_clear if closure_parameter && !closure_parameter.unresolved?
          parameter_type = @local_types[ruby_name] || @local_types[clear_name] || closure_parameter ||
            structural_block_parameter_clear_type(block_node.body, ruby_name)
          rendered_name = if parameter_type && !["", "Any", "Auto"].include?(parameter_type.to_s)
            "#{clear_name}: #{parameter_type}"
          else
            clear_name
          end
          parameter_names << rendered_name
          scope_names << clear_name
          scope_types[clear_name] = parameter_type.to_s if parameter_type && !["", "Any", "Auto"].include?(parameter_type.to_s)
          renames[ruby_name] = clear_name if clear_name != ruby_name
          next
        end

        target_names = simple_multi_target_names(param)
        return unsupported_expression(param, "Block parameter destructuring is not supported") unless target_names

        tuple_name = "tuple_param_#{index}"
        parameter_names << tuple_name
        scope_names << tuple_name
        target_names.each_with_index do |target_name, target_index|
          scope_names << target_name
          setup_lines << "MUTABLE #{target_name} = #{tuple_name}._#{target_index};"
        end
      end

      LambdaParameters.new(
        parameter_names: parameter_names,
        scope_names: scope_names,
        scope_types: scope_types,
        setup_lines: setup_lines,
        renames: renames
      )
    end

    def structural_block_parameter_clear_type(body, parameter_name)
      indexed = false
      walk = lambda do |node|
        return unless node
        return if node != body && (node.is_a?(Prism::DefNode) || node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode))

        if node.is_a?(Prism::CallNode) && node.name.to_s == "[]" &&
           node.receiver.is_a?(Prism::LocalVariableReadNode) &&
           node.receiver.name.to_s == parameter_name
          arguments = node.arguments&.arguments || []
          indexed = true if arguments.length == 1 && arguments.first.is_a?(Prism::IntegerNode)
        end
        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(body)
      "Any[]" if indexed
    end

    def clear_lambda_parameter_name(name, index)
      return "#{name}_value" if CLEAR_KEYWORDS.include?(name.upcase)
      return name unless name.start_with?("_")

      suffix = name.delete_prefix("_")
      suffix = index.to_s if suffix.empty?
      "ignored_#{suffix}"
    end
    public :clear_lambda_parameter_name

    def function_parameter_renames(param_names)
      needs_rename = lambda { |name| name.start_with?("_") || CLEAR_KEYWORDS.include?(name.upcase) }
      taken = Set.new(param_names.reject { |name| needs_rename.call(name) })

      param_names.each_with_object({}) do |ruby_name, renames|
        next unless needs_rename.call(ruby_name)

        base = if ruby_name.start_with?("_")
          suffix = ruby_name.delete_prefix("_")
          suffix = "param" if suffix.empty?
          "ignored_#{suffix}"
        else
          "#{ruby_name}_value"
        end
        clear_name = base
        index = 2
        while taken.include?(clear_name)
          clear_name = "#{base}_#{index}"
          index += 1
        end
        taken << clear_name
        renames[ruby_name] = clear_name
      end
    end

    def block_lambda_parameter_names(block_node)
      params = block_lambda_parameters(block_node)
      return params if unsupported_output?(params)

      params.parameter_names
    end

    def with_lambda_scope(parameter_names, parameter_types = {})
      old_declared = @declared_locals.dup
      old_shapes = @local_shapes.dup
      old_types = @local_types.dup
      old_lambda_depth = @lambda_depth || 0
      parameter_names.each { |name| @declared_locals << name }
      parameter_types.each { |name, type| @local_types[name] = type }
      @lambda_depth = old_lambda_depth + 1
      yield
    ensure
      @declared_locals = old_declared
      @local_shapes = old_shapes
      @local_types = old_types
      @lambda_depth = old_lambda_depth
    end

    def unsupported_output?(value)
      value.is_a?(String) && (value.include?("# [UNSUPPORTED:") || value.include?("unsupportedRuby("))
    end

# CLEAR's layout engine requires an explicit cycle-break on recursive
# type edges. A field whose type is the struct's OWN type (direct
# self-reference, e.g. IntrinsicEmit's sub-descriptor tree) gets @boxed:
# each sub-descriptor is uniquely owned by its parent.
def break_self_reference(emitted_type, struct_name)
  text = emitted_type.to_s
  return text if text.include?("@")

  base = text.delete_prefix("?")
  return text unless base == struct_name.to_s

  "#{text}@boxed"
end

    def statement_code(code)
      return "" if code.to_s.empty?
      # A mutable-receiver value block used as a STATEMENT unwraps back into
      # its plain statements (a bare `{ ... };` expression-statement is not
      # accepted by CLEAR; the block form exists for expression positions).
      if (unwrapped = unwrap_statement_value_block(code))
        return unwrapped
      end
      return code if code.end_with?(";") || block_statement_output?(code) || code.lstrip.start_with?("#")

      "#{code};"
    end
    public :statement_code

    def unwrap_statement_value_block(code)
      stripped = code.strip
      prefix = "{ MUTABLE rtoc_value_block_marker = 0;"
      return nil unless stripped.start_with?(prefix) && stripped.end_with?("}")

      inner = stripped.delete_prefix(prefix).delete_suffix("}").strip
      inner.end_with?(";") ? inner : "#{inner};"
    end

    def indent_lambda_line(code)
      code.split("\n").map { |line| line.empty? ? line : "  #{line}" }.join("\n")
    end

    def jump_statement_node?(stmt)
      stmt.is_a?(Prism::ReturnNode) || stmt.is_a?(Prism::BreakNode) || stmt.is_a?(Prism::NextNode)
    end

    def lambda_statement_node?(stmt)
      case stmt
      when Prism::LocalVariableWriteNode,
           Prism::InstanceVariableWriteNode,
           Prism::ClassVariableWriteNode,
           Prism::ConstantWriteNode,
           Prism::MultiWriteNode,
           Prism::UnlessNode
        true
      when Prism::CallNode
        name = stmt.name.to_s
        name == "[]=" || name.match?(/\A[A-Za-z_]\w*=\z/)
      else
        false
      end
    end

    def render_lambda_body(block_node, setup_lines: [])
      body = block_node.body
      return setup_lines.empty? ? "NIL" : "{\n#{setup_lines.map { |line| indent_lambda_line(line) }.join("\n")}\n}" unless body.is_a?(Prism::StatementsNode)

      statements = body.body
      if statements.last.is_a?(Prism::IfNode)
        prefix = statements[0...-1].map { |stmt| visit(stmt) }.reject(&:empty?).map { |code| statement_code(code) }
        lines = setup_lines.map { |code| indent_lambda_line(statement_code(code)) }
        lines.concat(prefix.map { |code| indent_lambda_line(code) })
        lines << indent_lambda_line(render_lambda_returning_statement(statements.last))
        lines << "  NIL"
        return "{\n#{lines.join("\n")}\n}"
      end

      rendered_pairs = statements.map { |stmt| [stmt, visit(stmt)] }.reject { |_stmt, code| code.empty? }
      rendered = rendered_pairs.map(&:last)
      if rendered.empty?
        return "NIL" if setup_lines.empty?

        lines = setup_lines.map { |code| indent_lambda_line(statement_code(code)) }
        return "{\n#{lines.join("\n")}\n}"
      end
      if setup_lines.empty? && rendered_pairs.length == 1 &&
         !block_statement_output?(rendered_pairs.first.last) &&
         !lambda_statement_node?(rendered_pairs.first.first)
        expression = rendered.first.delete_suffix(";")
        # CLEAR requires a fallible, allocation-bearing expression to be
        # hoisted before it can become a closure result. Keeping the Ruby
        # one-expression block compact would otherwise leave a TryExpr in
        # expression position and lose the owned-return transfer fact.
        if expression.match?(/\bTRY\b/)
          result_name = next_generated_local("lambda_result")
          return "{\n  #{result_name} = #{expression};\n  #{result_name}\n}"
        end
        return expression
      end

      lines = setup_lines.map { |code| indent_lambda_line(statement_code(code)) }
      lines.concat(rendered_pairs.map.with_index do |(stmt, code), index|
        final_statement = index == rendered_pairs.length - 1 &&
          (lambda_statement_node?(stmt) || stmt.is_a?(Prism::ReturnNode))
        line = if final_statement
          statement_code(code)
        elsif index == rendered_pairs.length - 1
          code.delete_suffix(";")
        else
          statement_code(code)
        end
        indent_lambda_line(line)
      end)
      if lambda_statement_node?(rendered_pairs.last.first) || block_statement_output?(rendered_pairs.last.last)
        lines << "  NIL"
      end
      "{\n#{lines.join("\n")}\n}"
    end

    def render_lambda_effect_body(block_node, setup_lines: [])
      body = block_node.body
      statements = body.is_a?(Prism::StatementsNode) ? body.body : []
      lines = setup_lines.map { |code| indent_lambda_line(statement_code(code)) }
      old_void_depth = @void_lambda_depth || 0
      @void_lambda_depth = old_void_depth + 1
      rendered = begin
        statements.filter_map do |statement|
          code = statement_node_code(statement)
          indent_lambda_line(statement_code(code)) unless code.empty?
        end
      ensure
        @void_lambda_depth = old_void_depth
      end
      lines.concat(rendered)
      @generated_support_helper_defs["rubyToClearVoid"] ||= <<~CLEAR.chomp
        FN rubyToClearVoid() RETURNS Void ->
          RETURN;
        END
      CLEAR
      lines << "  rubyToClearVoid()"
      "{\n#{lines.join("\n")}\n}"
    end

    def render_lambda_returning_statement(stmt)
      if lambda_statement_node?(stmt)
        return "#{statement_code(visit(stmt))}\nRETURN NIL;"
      end

      case stmt
      when Prism::IfNode
        render_lambda_returning_if_node(stmt)
      else
        "RETURN #{visit(stmt).delete_suffix(';')};"
      end
    end

    def render_lambda_returning_statements(statements_node)
      statements = statements_node&.body || []
      return "RETURN NIL;" if statements.empty?

      prefix = statements[0...-1].map { |stmt| visit(stmt) }.reject(&:empty?).map { |code| statement_code(code) }
      prefix << render_lambda_returning_statement(statements.last)
      prefix.join("\n")
    end

    def render_lambda_returning_if_node(node)
      pred = predicate_code(node.predicate)
      body = indent_lambda_line(render_lambda_returning_statements(node.statements))
      consequent = render_lambda_returning_consequent(node.consequent)
      "IF #{pred} THEN\n#{body}#{consequent}\nEND"
    end

    def render_lambda_returning_consequent(consequent)
      return "" unless consequent

      if consequent.is_a?(Prism::IfNode)
        pred = predicate_code(consequent.predicate)
        body = indent_lambda_line(render_lambda_returning_statements(consequent.statements))
        nested = render_lambda_returning_consequent(consequent.consequent)
        return "\nELSE_IF #{pred} THEN\n#{body}#{nested}"
      end

      body = indent_lambda_line(render_lambda_returning_statements(consequent.statements))
      "\nELSE\n#{body}"
    end

    def assignment_statement_node?(stmt)
      stmt.class.name.end_with?("WriteNode") ||
        (stmt.is_a?(Prism::CallNode) && (stmt.name.to_s == "[]=" || stmt.name.to_s.match?(/\A[A-Za-z_]\w*=\z/)))
    end

    # Ruby's assignment is expression-valued (`x = y` evaluates to `y`);
    # CLEAR's is not - a WriteNode-shaped statement (or a `obj.attr =`/
    # `arr[i] =` CallNode) only ever lowers to a standalone `lhs = rhs;`
    # line. Any construct that needs an assignment's VALUE - RETURN (x = y),
    # string interpolation #{x = y}, etc. - must emit the assignment as a
    # preceding statement and separately read the target back. Returns
    # [assignment_code_or_nil, lhs_read_code]; assignment_code is nil when
    # the write node emitted no code of its own (already handled via a
    # different mechanism) - only the read-back matters then.
    def assignment_statement_and_read_back(stmt)
      assignment_code = visit(stmt)
      name_lhs = if stmt.respond_to?(:name)
        name_str = stmt.name.to_s
        if name_str.start_with?("@@")
          class_storage_variable_name(name_str.delete_prefix("@@"))
        elsif name_str.start_with?("@")
          "self.#{name_str.delete_prefix("@")}"
        else
          name_str
        end
      else
        "NIL"
      end

      return [nil, name_lhs] if assignment_code.strip.empty?
      return [assignment_code, name_lhs] if assignment_code.start_with?("IF ") && assignment_code.end_with?("END")

      assignment_code = "#{assignment_code};" unless assignment_code.end_with?(";")
      # Extract the left-hand side of the assignment, stripping a MUTABLE
      # declaration prefix if present.
      split_lhs = assignment_code.split('=').first.to_s.strip.sub(/\AMUTABLE\s+/, '')
      [assignment_code, split_lhs]
    end

    def render_returning_statement(stmt)
      return visit(stmt) if guard_exit_statement?(stmt)

      if lambda_statement_node?(stmt)
        code = visit(stmt)
        value_node = if stmt.is_a?(Prism::CallNode)
          stmt.arguments&.arguments&.last
        elsif stmt.respond_to?(:value)
          stmt.value
        end
        if value_node
          value = expression_argument_code(value_node)
          value = wrap_argument_for_parameter_type(value, value_node, @current_function_return_type)
          # Only the WriteNode shape (`@field = T.let(@field, T)`, Sorbet's
          # type-annotation-only self-assignment idiom for a memoizing
          # getter) needs borrow materialization here - real corpus case:
          # LSP::DocumentStore's Struct.new-generated `cached_findings`
          # getter read back a borrowed, non-trivially-copyable union field
          # bare ("Cannot return borrowed value without COPY"). The CallNode
          # shape (`self[:field] = value` / `target.field = value`) returns
          # its OWN RHS argument unmodified by Ruby's assignment-expression
          # semantics (the setter-returns-its-argument idiom) and must stay
          # uncopied - two existing passing specs pin exactly that.
          value = materialize_borrowed_code(value, value_node) if stmt.respond_to?(:value)
          # The setter-returns-its-argument idiom still has to satisfy the
          # declared return OWNERSHIP: `def []=(k, v) = @map[k] = v` on a
          # Hash[String, Entry] returns @multiowned while `v` is a plain
          # borrowed param, and RETURN has no call-edge keep-analysis to
          # upgrade it after the fact.
          if (upgraded = ownership_upgrade_return_code(value, value_node))
            return [statement_code(code), upgraded].reject(&:empty?).join("\n")
          end
        else
          value = "NIL"
        end
        return [statement_code(code), "RETURN #{value};"].reject(&:empty?).join("\n")
      end

      if assignment_statement_node?(stmt)
        assignment_code, lhs = assignment_statement_and_read_back(stmt)
        lhs = wrap_argument_for_parameter_type(lhs, stmt, @current_function_return_type)
        return assignment_code ? "#{assignment_code}\nRETURN #{lhs};" : "RETURN #{lhs};"
      end

      if stmt.is_a?(Prism::WhileNode) || stmt.is_a?(Prism::UntilNode) || stmt.is_a?(Prism::ForNode) ||
         (stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name.to_s == "loop" && stmt.block) ||
         (stmt.is_a?(Prism::CallNode) && %w[each each_with_index reverse_each each_key each_value each_pair each_char each_line times upto downto].include?(stmt.name.to_s))
        loop_code = visit(stmt).rstrip
        loop_code = "#{loop_code};" unless loop_code.end_with?(";") || loop_code.end_with?("END")
        value = wrap_argument_for_parameter_type("NIL", stmt, @current_function_return_type)
        return "#{loop_code}\nRETURN #{value};"
      end

      if stmt.is_a?(Prism::OrNode) && (render_or = render_returning_or_node(stmt))
        return render_or
      end

      if stmt.is_a?(Prism::CallNode) && stmt.safe_navigation?
        return render_returning_safe_navigation(stmt)
      end

      case stmt
      when Prism::IfNode
        render_returning_if_node(stmt)
      when Prism::CaseNode
        render_returning_case_node(stmt)
      when Prism::BeginNode
        if stmt.ensure_clause && !stmt.rescue_clause
          return translate_ensure_only_begin(stmt, returning: true)
        end
        inner_stmts = stmt.statements&.body || []
        if inner_stmts.empty?
          code = wrap_argument_for_parameter_type("NIL", stmt, @current_function_return_type)
          "RETURN #{code};"
        else
          rendered = []
          inner_stmts[0...-1].each do |s|
            code = visit(s)
            unless code.empty?
              code = "#{code};" unless code.end_with?(";") || block_statement_output?(code) || code.lstrip.start_with?("#")
              rendered << code
            end
          end
          last_code = render_returning_statement(inner_stmts.last)
          rendered << last_code unless last_code.empty?
          rendered.join("\n")
        end
      else
        @direct_return_value_depth += 1
        begin
          code = with_expected_expression_type(@current_function_return_type) { visit(stmt) }.delete_suffix(';')
        ensure
          @direct_return_value_depth -= 1
        end
        if (upgraded = ownership_upgrade_return_code(code, stmt))
          return upgraded
        end
        if (multiline_return = render_multiline_expression_return(code, stmt))
          return multiline_return
        end
        code = wrap_argument_for_parameter_type(code, stmt, @current_function_return_type)
        code = contextual_array_return(code, stmt)
        code = materialize_borrowed_code(code, stmt)
        if (hoisted = hoist_tuple_pipeline_return(code))
          return hoisted
        end
        "RETURN #{code};"
      end
    end

    def render_returning_statements(statements_node)
      render_returning_statement_array(statements_node&.body || [])
    end

    def render_returning_statement_array(statements)
      return "RETURN NIL;" if statements.empty?

      prefix = []
      statements[0...-1].each_with_index do |stmt, index|
        if (accumulator = branch_array_accumulator_start(stmt, statements[index + 1]))
          @branch_array_accumulators << accumulator
          @branch_array_accumulator_ends[statements[index + 1].object_id] = accumulator
        end
        if (guard = optional_nil_exit_guard(stmt))
          prefix << format_statement_code(render_optional_nil_guard(guard, statements[(index + 1)..]))
          return prefix.join("\n")
        end

        if (guard = runtime_is_a_exit_guard(stmt))
          prefix << format_statement_code(render_runtime_is_a_guard(guard, statements[(index + 1)..]))
          return prefix.join("\n")
        end

        code = if (accumulator = @branch_array_accumulator_ends[stmt.object_id])
          branch_array_accumulator_if_code(stmt, accumulator)
        else
          visit(stmt)
        end
        prefix << format_statement_code(code) unless code.empty?
        if (accumulator = @branch_array_accumulator_ends.delete(stmt.object_id))
          @branch_array_accumulators.delete(accumulator)
        end
        if code.strip.start_with?("RETURN ") || code.strip == "RETURN;"
          return prefix.join("\n")
        end
      end

      prefix << format_statement_code(render_returning_statement(statements.last))
      prefix.join("\n")
    end

    def render_returning_nested_if(predicate, statements, consequent)
      if predicate.is_a?(Prism::AndNode) && contains_narrowing_predicate?(predicate.right)
        left = predicate.left
        right = predicate.right
        inner_if = render_returning_nested_if(right, statements, consequent)
        optional_truthy = optional_union_truthy_if_guard(left)
        pred_code = if optional_truthy
          "#{optional_truthy[:receiver_code]} EXISTS AS #{optional_truthy[:binding_name]}"
        else
          predicate_code(left)
        end
        body = with_indent do
          if optional_truthy
            with_optional_truthy_context(optional_truthy) { inner_if }
          else
            inner_if
          end
        end
        else_code = render_consequent_for_if_bind(consequent)
        return "IF #{pred_code} THEN\n#{body}#{else_code}\nEND"
      end
      render_returning_simple_if(predicate, statements, consequent)
    end

    def render_returning_simple_if(predicate, statements, consequent)
      runtime_is_a = runtime_is_a_predicate(predicate)
      optional_truthy = runtime_is_a ? nil : optional_union_truthy_if_guard(predicate)
      compound_optional_truthies = runtime_is_a || optional_truthy ? [] : optional_truthies_in_and(predicate)
      nil_receiver = nil_predicate_receiver(predicate)
      optional_nil_false = optional_union_truthy_if_guard(nil_receiver) if nil_receiver
      pred = if runtime_is_a
        "#{runtime_is_a[:receiver_code]} IS_A #{runtime_is_a[:expected_type]} AS #{runtime_is_a[:binding_name]}"
      elsif optional_truthy
        "#{optional_truthy[:receiver_code]} EXISTS AS #{optional_truthy[:binding_name]}"
      else
        predicate_code(predicate)
      end
      body = with_indent do
        if runtime_is_a
          with_narrowing_context(runtime_is_a) { render_returning_statements(statements) }
        elsif optional_truthy
          with_optional_truthy_context(optional_truthy) { render_returning_statements(statements) }
        elsif compound_optional_truthies.any?
          with_local_optionals_narrowed(compound_optional_truthies) { render_returning_statements(statements) }
        else
          render_returning_statements(statements)
        end
      end
      consequent_code = if runtime_is_a
        with_runtime_is_a_else_context(runtime_is_a) { render_consequent_for_if_bind(consequent) }
      elsif optional_nil_false
        # else-of-`x == NIL` flow-narrows `x` in place; narrow the type without
        # renaming to `x?` (which the narrowed value rejects).
        with_local_optional_narrowed(optional_nil_false[:receiver_name], optional_nil_false[:payload_type]) do
          render_consequent_for_if_bind(consequent)
        end
      elsif optional_truthy
        render_consequent_for_if_bind(consequent)
      else
        render_returning_consequent(consequent)
      end
      "IF #{pred} THEN\n#{body}#{consequent_code}\nEND"
    end

    def render_returning_if_node(node)
      render_returning_nested_if(node.predicate, node.statements, node.consequent)
    end

    def render_returning_or_node(node)
      left_type = inferred_clear_type(node.left).to_s
      return nil unless left_type.start_with?("?")
      return nil unless pure_expression?(node.left) || (node.left.is_a?(Prism::CallNode) && node.left.name.to_s == "[]")

      lhs = visit(node.left)

      left_arg = node.left
      return_type = @current_function_return_type.to_s
      directly_unwrapped = left_type == optional_clear_type(return_type)
      left_code = if directly_unwrapped && lhs.match?(/\A[A-Za-z_]\w*\z/)
        # The IF condition flow-narrows the optional binding in place. Adding
        # Ruby's `?` unwrap spelling here asks CLEAR to unwrap the already
        # narrowed local and is rejected as UNWRAP_NON_OPTIONAL. Repeated
        # expressions such as field reads are not stable flow bindings and
        # still need an explicit unwrap.
        lhs
      elsif directly_unwrapped
        optional_unwrap_code(lhs)
      else
        wrap_argument_for_parameter_type(lhs, left_arg, @current_function_return_type)
      end
      left_code = materialize_borrowed_code(left_code, left_arg) unless return_type.end_with?("@symbol")

      right_code = render_returning_statement(node.right)
      # The ELSE arm is statement position — a bare `panic(...)` fallback
      # needs its terminator.
      right_code = "#{right_code};" unless right_code.rstrip.end_with?(";", "END")
      right_code_indented = right_code.split("\n").map { |line| "  #{line}" }.join("\n")

      <<~CLEAR.chomp
        IF #{lhs} != NIL THEN
          RETURN #{left_code};
        ELSE
        #{right_code_indented}
        END
      CLEAR
    end

    def render_returning_safe_navigation(node)
      chain = []
      curr = node
      while curr.is_a?(Prism::CallNode) && curr.safe_navigation?
        chain.unshift(curr)
        curr = curr.receiver
      end
      base_code = visit(curr)
      render_safe_navigation_chain(chain, 0, base_code, curr)
    end

    def render_safe_navigation_chain(chain, index, base_code, base_node)
      link = chain[index]
      unwrapped = optional_unwrap_code(base_code)

      @lowering_safe_navigation << link.object_id
      call_code = with_node_code_override(link.receiver, unwrapped) { visit_call_node(link) }
      @lowering_safe_navigation.delete(link.object_id)

      if index == chain.length - 1
        ret_val = wrap_argument_for_parameter_type(call_code, link, @current_function_return_type)
        ret_val = materialize_borrowed_code(ret_val, link)
        ret_nil = wrap_argument_for_parameter_type("NIL", link, @current_function_return_type)
        <<~CLEAR.chomp
          IF #{base_code} != NIL THEN
            RETURN #{ret_val};
          ELSE
            RETURN #{ret_nil};
          END
        CLEAR
      else
        nested = render_safe_navigation_chain(chain, index + 1, call_code, link)
        nested_indented = nested.split("\n").map { |line| "  #{line}" }.join("\n")
        ret_nil = wrap_argument_for_parameter_type("NIL", link, @current_function_return_type)
        <<~CLEAR.chomp
          IF #{base_code} != NIL THEN
          #{nested_indented}
          ELSE
            RETURN #{ret_nil};
          END
        CLEAR
      end
    end

    def render_consequent_for_if_bind(consequent)
      return "" unless consequent

      body = with_indent do
        if consequent.is_a?(Prism::IfNode)
          render_returning_if_node(consequent)
        else
          render_returning_statements(consequent.statements)
        end
      end
      "\nELSE\n#{body}"
    end

    def render_returning_consequent(consequent)
      return "" unless consequent

      if consequent.is_a?(Prism::IfNode)
        pred = predicate_code(consequent.predicate)
        body = with_indent { render_returning_statements(consequent.statements) }
        nested = render_returning_consequent(consequent.consequent)
        return "\nELSE_IF #{pred} THEN\n#{body}#{nested}"
      end

      body = with_indent { render_returning_statements(consequent.statements) }
      "\nELSE\n#{body}"
    end

    def block_to_lambda(block_node, returns_void: false)
      if block_node.is_a?(Prism::BlockArgumentNode)
        return visit(block_node.expression)
      end

      unless block_node.is_a?(Prism::BlockNode) || block_node.is_a?(Prism::LambdaNode)
        return raise_unsupported("Unsupported block type #{block_node.class.name}", block_node)
      end

      params = block_lambda_parameters(block_node)
      return params if unsupported_output?(params)

      body = with_renames(params.renames || {}) do
        with_lambda_scope(params.scope_names, params.scope_types || {}) do
          if returns_void
            render_lambda_effect_body(block_node, setup_lines: params.setup_lines)
          else
            render_lambda_body(block_node, setup_lines: params.setup_lines)
          end
        end
      end
      captures = block_captured_parameter_names(block_node, params.scope_names)
      closure_fact = @typed_ir.closure_for(block_node)
      closure_fact&.captures&.each do |name, mode|
        next if name == "self"

        emitted_name = @renames[name] || name
        if emitted_name.match?(/\A[A-Za-z_]\w*\z/)
          rendered = mode == :borrow_mut ? "MUTABLE #{emitted_name}" : emitted_name
          if mode == :borrow_mut
            captures.delete(emitted_name)
            captures << rendered unless captures.include?(rendered)
          elsif !captures.any? { |capture_name| capture_name.delete_prefix("MUTABLE ") == emitted_name }
            captures << rendered
          end
        else
          if emitted_name.match?(/\bself\b/)
            captures.delete("self")
            captures << (mode == :borrow_mut ? "MUTABLE self" : "self") unless captures.include?("MUTABLE self")
          end
          emitted_name.scan(/\brtoc_[A-Za-z0-9_]+\b/).uniq.each do |dependency|
            captures << dependency unless captures.any? { |capture_name| capture_name.delete_prefix("MUTABLE ") == dependency }
          end
        end
      end
      self_capture = closure_fact&.captures&.fetch("self", nil)
      if @inside_instance_method && (self_capture || block_uses_instance_context?(block_node))
        mutates_self = self_capture == :borrow_mut || (!self_capture && block_mutates_instance_context?(block_node))
        captured_self = mutates_self ? "MUTABLE self" : "self"
        captures << captured_self
      end
      capture = captures.empty? ? "" : " USE(#{captures.join(', ')})"
      "%(#{params.parameter_names.join(', ')})#{capture} -> #{body}"
    end

    def block_captured_parameter_names(block_node, block_scope_names)
      captures = Set.new
      mutated = Set.new
      walk = lambda do |current|
        return unless current
        return if current.is_a?(Prism::DefNode)

        if current.is_a?(Prism::LocalVariableReadNode)
          name = current.name.to_s
          if (@current_param_names.include?(name) || @declared_locals.include?(name)) && !block_scope_names.include?(name)
            captures << name
          end
        elsif current.is_a?(Prism::LocalVariableWriteNode)
          name = current.name.to_s
          mutated << name unless block_scope_names.include?(name)
        elsif current.is_a?(Prism::CallNode)
          if current.receiver.is_a?(Prism::LocalVariableReadNode) &&
             (ruby_mutating_receiver_call?(current) ||
              @typed_ir.call_for(current)&.receiver_ownership == :borrow_mut)
            mutated << current.receiver.name.to_s
          end
          mutated.merge(mutable_call_argument_local_names(current))
        end
        current.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(block_node.body)
      captures.to_a.sort.map do |name|
        emitted_name = @renames[name] || name
        mutated.include?(name) ? "MUTABLE #{emitted_name}" : emitted_name
      end
    end

    def block_uses_instance_context?(node)
      used = false
      walk = lambda do |current|
        return unless current && !used
        return if current.is_a?(Prism::DefNode)

        if current.is_a?(Prism::SelfNode) ||
           current.is_a?(Prism::InstanceVariableReadNode) ||
           current.is_a?(Prism::InstanceVariableWriteNode) ||
           (current.is_a?(Prism::CallNode) && current.receiver.nil? &&
            @current_instance_method_names.include?(clear_function_name(current.name.to_s)))
          used = true
          return
        end
        current.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
      used
    end

    def block_mutates_instance_context?(node)
      mutates = false
      walk = lambda do |current|
        return unless current && !mutates
        return if current.is_a?(Prism::DefNode)

        if current.is_a?(Prism::InstanceVariableWriteNode) ||
           (current.is_a?(Prism::CallNode) && current.receiver.is_a?(Prism::SelfNode) &&
            (ruby_setter_method_name?(current.name.to_s) || current.name.to_s == "[]=")) ||
           (current.is_a?(Prism::CallNode) && current.receiver.nil? &&
            @current_mutating_instance_method_names.include?(clear_function_name(current.name.to_s)))
          mutates = true
          return
        end
        current.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
      mutates
    end

    def render_ruby_loop(node)
      block_node = node.block
      unless block_node.is_a?(Prism::BlockNode)
        return unsupported_expression(node, "Ruby loop requires a literal block")
      end

      params = block_lambda_parameters(block_node)
      return params if unsupported_output?(params)
      unless params.parameter_names.empty?
        return unsupported_expression(node, "Ruby loop block parameters are not supported")
      end

      body = with_indent { visit(block_node.body) }
      "WHILE TRUE DO\n#{body}\nEND"
    end

    def check_arguments!(arguments_node)
      return unless arguments_node
      arguments_node.arguments.each do |arg|
        if arg.is_a?(Prism::KeywordHashNode)
          res = raise_unsupported("Keyword arguments are not supported", arg)
          return res if res.is_a?(String) && res.include?("# [UNSUPPORTED:")
        end
      end
      nil
    end

    def check_parameters!(parameters_node)
      return unless parameters_node
      nil
    end

    def t_struct_class?(node)
      node.superclass&.location&.slice == "T::Struct"
    end

    def t_enum_class?(node)
      node.superclass&.location&.slice == "T::Enum"
    end

    def t_enum_variants(node)
      body_nodes = node.body&.body || []
      enum_call = body_nodes.find do |stmt|
        stmt.is_a?(Prism::CallNode) &&
          stmt.receiver.nil? &&
          stmt.name.to_s == "enums" &&
          stmt.block
      end
      return [] unless enum_call

      enum_call.block&.body&.body&.filter_map do |stmt|
        next unless stmt.is_a?(Prism::ConstantWriteNode)
        next unless sorbet_enum_new_call?(stmt.value)

        stmt.name.to_s
      end || []
    end

    def sorbet_enum_new_call?(node)
      node.is_a?(Prism::CallNode) &&
        node.receiver.nil? &&
        node.name.to_s == "new"
    end

    def apply_multiowned_sigil(type_str)
      return type_str if type_str.to_s.include?("@multiowned")
      "#{type_str}@multiowned"
    end

    def t_struct_field(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.receiver.nil?
      return nil unless ["const", "prop"].include?(node.name.to_s)

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length >= 2
      return nil unless args.first.is_a?(Prism::SymbolNode)

      field_name = args.first.value.to_s
      type = declaration_field_type(node, field_name) || convert_sorbet_type(args[1])
      if declaration_comment?(node, "ruby-to-clear: aliasable") || declaration_comment?(node, "@aliasable")
        type = apply_multiowned_sigil(type)
      end
      [field_name, type, t_struct_field_default(args)]
    end


    def t_struct_field_default(args)
      keyword_hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
      return nil unless keyword_hash

      assoc = keyword_hash.elements.find do |element|
        element.is_a?(Prism::AssocNode) && %w[default factory].include?(keyword_call_key(element.key))
      end
      return nil unless assoc&.value

      # Keep the source node until the constructor is emitted. Required-file
      # metadata is collected before the current file's constructor signatures,
      # so rendering here can turn a perfectly static default into an
      # unsupported placeholder merely because its callee has not been indexed
      # yet.
      value = assoc.value
      return value unless keyword_call_key(assoc.key) == "factory"

      # `factory:` wraps the default in a lambda so Ruby shares one frozen
      # instance instead of deep-cloning per node. CLEAR value semantics make
      # sharing and copying identical, so the lambda body IS the default.
      t_struct_factory_body(value)
    end

    def t_struct_factory_body(value)
      return nil unless value.is_a?(Prism::LambdaNode)

      body = value.body
      return nil unless body.is_a?(Prism::StatementsNode) && body.body.length == 1

      body.body.first
    end

    # CLEAR rejects Auto in a field outright ("Cross-callsite field inference is
    # not supported"), so an unresolved container type must not reach a struct
    # declaration. `Auto[]T` is an inferred container around a KNOWN element;
    # keep the element and let the array be the container.
    def struct_field_type(type, owner)
      text = break_self_reference(type.to_s, owner)
      return text unless text.match?(/\bAuto\b/)

      text = text.sub(/\AAuto(\[\].+)\z/, '\\1')
      text.gsub(/\bAuto\b/, "Any")
    end

    def concrete_struct_type(type)
      res = expand_non_emitted_type_alias(type.to_s.gsub(/\bAuto\b/, "Any"))
      if res.to_s.match?(/\A\??[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)+\z/)
        res = clear_type_expr(res)
      end
      resolve_type_with_aliasable(res)
    end

    def inferred_field_type_from_value(node)
      if (typed_value = sorbet_typed_value(node))
        return concrete_struct_type(typed_value[1])
      end

      if (unwrapped = sorbet_unwrapped_value(node))
        return inferred_field_type_from_value(unwrapped)
      end

      case node
      when Prism::StringNode, Prism::InterpolatedStringNode
        "String"
      when Prism::IntegerNode
        "Int64"
      when Prism::FloatNode
        "Float64"
      when Prism::TrueNode, Prism::FalseNode
        "Bool"
      when Prism::ArrayNode
        "Any[]"
      when Prism::HashNode, Prism::KeywordHashNode
        "HashMap<Any, Any>"
      when Prism::CallNode
        if constant_constructor_call?(node)
          name = constructor_output_name(node.receiver)
          return name if name && !name.empty?
        end
      end

      "Any"
    end

    def dynamic_ruby_call_reason(name)
      DYNAMIC_RUBY_CALLS[name.to_s]
    end

    def keyword_hash_argument(arguments_node)
      return nil unless arguments_node

      arguments_node.arguments.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
    end

    def constant_constructor_call?(node)
      return false unless node.name.to_s == "new"
      return true if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)

      # A receiverless `new(...)` evaluated in a class BODY (not inside an
      # instance method, where `new` would be an ordinary method call) is
      # `SelfClass.new(...)` - Ruby's implicit self there is the class. Real
      # corpus: IntrinsicContract's `EMPTY = T.let(new(template: ...), ...)`,
      # which emitted a bare `new({...})` the frontend rejected as "Undefined
      # function 'new'". The constructor helpers already resolve a nil
      # receiver to @current_class, so only this predicate needed widening.
      #
      # Gated on the constructor actually RESOLVING: when the enclosing
      # class's shape is unknown here, routing to the constructor path only
      # converts a late frontend error into an earlier translation error
      # (real regression: mir/cleanup_classifier.rb / cleanup_entry.rb,
      # whose `def self.from_bindings` calls a bare `new` whose fields do not
      # resolve at this point). Leaving those on the old path keeps them
      # exactly where they were instead of moving them backwards.
      return false unless node.receiver.nil? && @current_class && !@inside_instance_method

      !!(constructor_field_names(nil) || constructor_parameter_info(nil))
    end

    def hash_new_call?(node)
      node.is_a?(Prism::CallNode) && node.name.to_s == "new" &&
        node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name.to_s == "Hash"
    end

    def anonymous_struct_constructor(node)
      return nil unless node.is_a?(Prism::CallNode) && node.name.to_s == "new"

      struct_call = node.receiver
      return nil unless struct_call.is_a?(Prism::CallNode) && struct_call.name.to_s == "new"
      return nil unless struct_call.receiver.is_a?(Prism::ConstantReadNode) && struct_call.receiver.name.to_s == "Struct"

      fields = (struct_call.arguments&.arguments || []).filter_map do |argument|
        argument.value.to_s if argument.is_a?(Prism::SymbolNode)
      end
      values = node.arguments&.arguments || []
      return nil if fields.empty? || fields.length != values.length

      type_name = "AnonymousStructL#{node.location.start_line}C#{node.location.start_column}"
      field_types = fields.zip(values).to_h do |field, value|
        inferred = inferred_clear_type(value).to_s
        [field, ["", "Any", "Auto"].include?(inferred) ? "Any" : inferred]
      end
      @generated_support_helper_defs[type_name] ||= begin
        declarations = fields.map { |field| "  #{field}: #{field_types.fetch(field)}" }.join(",\n")
        "STRUCT #{type_name} {\n#{declarations}\n}"
      end
      pairs = fields.zip(values).map { |field, value| "#{field}: #{visit(value)}" }
      "#{type_name}{ #{pairs.join(', ')} }"
    end

    def record_hash_default(name, node)
      return @hash_default_specs.delete(name) unless hash_new_call?(node)

      arguments = node.arguments&.arguments || []
      if node.block.is_a?(Prism::BlockNode)
        params = node.block.parameters&.parameters&.requireds || []
        statement = node.block.body&.body&.last
        if params.length == 2 && statement.is_a?(Prism::CallNode) && statement.name.to_s == "[]="
          value = statement.arguments&.arguments&.last
          @hash_default_specs[name] = {
            kind: :factory,
            value: value,
            map_param: params[0].name.to_s,
            key_param: params[1].name.to_s,
          } if value
        end
      elsif arguments.length == 1
        @hash_default_specs[name] = { kind: :value, value: arguments.first }
      else
        @hash_default_specs.delete(name)
      end
    end

    def hash_default_spec_for_receiver(receiver)
      return nil unless receiver.is_a?(Prism::LocalVariableReadNode)

      name = @renames[receiver.name.to_s] || receiver.name.to_s
      @hash_default_specs[name]
    end

    def hash_default_code(spec, receiver_code, key_code)
      with_renames(spec[:map_param] => receiver_code, spec[:key_param] => key_code) do
        expression_argument_code(spec.fetch(:value))
      end
    end

    def hash_default_index_node(node)
      if sorbet_call?(node, "must")
        args = node.arguments&.arguments || []
        node = args.first if args.length == 1
      end
      return nil unless node.is_a?(Prism::CallNode) && node.name.to_s == "[]" && node.receiver

      node
    end

    def same_class_constructor_call?(node)
      node.name.to_s == "new" &&
        node.receiver.nil? &&
        @current_class &&
        @inside_class_method
    end

    def constructor_field_names(receiver)
      names = []
      names << @current_class if receiver.nil? && @current_class
      if receiver
        raw_name = receiver.location.slice.strip
        if (aliased_name = type_alias_for_path(raw_name))
          names << aliased_name.to_s
          names << aliased_name.to_s.split("::").last
        end
        names.concat(lexical_metadata_names(raw_name))
        names << raw_name
      end
      names << receiver.location.slice.strip.split("::").last if receiver.is_a?(Prism::ConstantPathNode)
      names << receiver.name.to_s if receiver.respond_to?(:name)

      names.uniq.each do |name|
        return @struct_fields[name] if @struct_fields[name]
      end

      nil
    end

    def constructor_field_defaults(receiver)
      names = []
      names << @current_class if receiver.nil? && @current_class
      if receiver
        raw_name = receiver.location.slice.strip
        if (aliased_name = type_alias_for_path(raw_name))
          names << aliased_name.to_s
          names << aliased_name.to_s.split("::").last
        end
        names.concat(lexical_metadata_names(raw_name))
        names << raw_name
      end
      names << receiver.location.slice.strip.split("::").last if receiver.is_a?(Prism::ConstantPathNode)
      names << receiver.name.to_s if receiver.respond_to?(:name)

      names.uniq.each do |name|
        return @struct_field_defaults[name] if @struct_field_defaults[name]
      end

      nil
    end

    def lexical_metadata_names(raw_name)
      raw = raw_name.to_s.delete_prefix("::")
      return [raw] if raw.include?("::") || !@current_class

      scope = @current_class.to_s.split("::")
      scope.pop if @struct_fields.key?(@current_class.to_s) || @class_instance_field_names.key?(@current_class.to_s)
      scope.length.downto(1).map { |length| (scope.first(length) + [raw]).join("::") }
    end

    def visit_program_node(node)
      visit(node.statements)
    end


    def visit_statements_node(node)
      visit_statement_list(node.body)
    end

    def visit_statement_list(statements)
      statements = expand_mixin_body_nodes(statements) if @current_class
      statements = suppress_imported_method_overrides(statements) if @current_class
      last_sig = nil
      rendered = []
      index = 0
      private_names = statements.flat_map { |stmt| private_class_method_names(stmt) }
      public_names = statements.flat_map { |stmt| declared_public_method_names(stmt) }
      old_private_method_names = @private_method_names
      old_public_method_names = @public_method_names
      old_private_section = @private_section
      old_function_statement_list_depth = @function_statement_list_depth
      top_level_function_body = @inside_function && old_function_statement_list_depth.zero?
      @function_statement_list_depth = old_function_statement_list_depth + 1
      @private_method_names = @private_method_names | private_names.to_set
      @public_method_names = @public_method_names | public_names.to_set
      while index < statements.length
        stmt = statements[index]
        if (accumulator = branch_array_accumulator_start(stmt, statements[index + 1]))
          @branch_array_accumulators << accumulator
          @branch_array_accumulator_ends[statements[index + 1].object_id] = accumulator
        end
        if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
          last_sig = stmt
          index += 1
          next
        end

        if visibility_section_call?(stmt)
          @private_section = stmt.name.to_s != "public"
          last_sig = nil
          index += 1
          next
        end

        if declaration_comment?(stmt, "ruby-to-clear: skip")
          last_sig = nil
          index += 1
          next
        end

        if @data_only && stmt.is_a?(Prism::DefNode) &&
           !declaration_comment?(stmt, "ruby-to-clear: data-api") &&
           !%w[each_locatable each_child_node].include?(stmt.name.to_s)
          # These walkers are generated from the synthesized Locatable
          # union (their Ruby bodies use Struct reflection), so a data-only
          # unit still exports them for translated walker callers.
          last_sig = nil
          index += 1
          next
        end
        if @data_only && stmt.is_a?(Prism::ConstantWriteNode) &&
           !declaration_comment?(stmt, "ruby-to-clear: data-api") &&
           !sorbet_type_alias_value(stmt.value, alias_name: stmt.name.to_s) &&
           !struct_new_field_names(stmt.value)
          last_sig = nil
          index += 1
          next
        end

        if stmt.is_a?(Prism::DefNode) || private_class_method_def_call?(stmt)
          @current_sig = last_sig
          last_sig = nil
        else
          last_sig = nil
        end

        if (guard = optional_nil_exit_guard(stmt)) && index < statements.length - 1
          code = render_optional_nil_guard(guard, statements[(index + 1)..])
          @current_sig = nil
          rendered << format_statement_code(code) unless code.empty?
          break
        end

        if (guard = runtime_is_a_exit_guard(stmt)) && index < statements.length - 1
          code = render_runtime_is_a_guard(guard, statements[(index + 1)..])
          @current_sig = nil
          rendered << format_statement_code(code) unless code.empty?
          break
        end

        code = if (accumulator = @branch_array_accumulator_ends[stmt.object_id])
          branch_array_accumulator_if_code(stmt, accumulator)
        elsif array_concat_call?(stmt)
          array_concat_statement_code(stmt)
        elsif top_level_function_body && @current_function_returns_value && index == statements.length - 1 && ternary_if_node?(stmt)
          render_returning_if_node(stmt)
        elsif top_level_function_body && @current_function_returns_value && index == statements.length - 1 && stmt.is_a?(Prism::CaseNode)
          render_returning_case_node(stmt)
        elsif stmt.is_a?(Prism::CaseNode)
          statement_node_code(stmt)
        elsif ternary_if_node?(stmt)
          visit_ternary_if_node(stmt, statement: true)
        elsif top_level_function_body && @current_function_returns_value && index == statements.length - 1 &&
              stmt.is_a?(Prism::InstanceVariableOrWriteNode) && class_storage_instance_variable?(stmt.name.to_s.delete_prefix("@"))
          field = stmt.name.to_s.delete_prefix("@")
          storage = class_storage_variable_name(field)
          "#{visit(stmt)};\n#{storage}"
        elsif top_level_function_body && @current_function_returns_value && index == statements.length - 1
          render_returning_statement(stmt)
        else
          visit(stmt)
        end
        @current_sig = nil
        force_block = stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode) ||
          stmt.is_a?(Prism::WhileNode) || stmt.is_a?(Prism::UntilNode) || stmt.is_a?(Prism::ForNode) ||
          stmt.is_a?(Prism::ClassNode) || stmt.is_a?(Prism::ModuleNode) ||
          stmt.is_a?(Prism::SingletonClassNode)
        rendered << format_statement_code(code, force_block: force_block) unless code.empty?
        if (accumulator = @branch_array_accumulator_ends.delete(stmt.object_id))
          @branch_array_accumulators.delete(accumulator)
        end
        break if code.strip.start_with?("RETURN ") || code.strip == "RETURN;"

        index += 1
      end
      @private_method_names = old_private_method_names
      @public_method_names = old_public_method_names
      @private_section = old_private_section
      @function_statement_list_depth = old_function_statement_list_depth
      rendered.join("\n")
    end

    def branch_array_accumulator_start(statement, following)
      return nil unless statement.is_a?(Prism::LocalVariableWriteNode)
      initial_value = sorbet_typed_value(statement.value)&.first || statement.value
      return nil unless initial_value.is_a?(Prism::ArrayNode) && initial_value.elements.empty?
      return nil unless following.is_a?(Prism::IfNode)

      name = statement.name.to_s
      if_branches_assign_local?(following, name) ? name : nil
    end

    def if_branches_assign_local?(node, name)
      return false unless node.is_a?(Prism::IfNode)
      then_last = node.statements&.body&.last
      return false unless then_last.is_a?(Prism::LocalVariableWriteNode) && then_last.name.to_s == name

      consequent = node.consequent
      return if_branches_assign_local?(consequent, name) if consequent.is_a?(Prism::IfNode)

      else_last = consequent&.statements&.body&.last
      else_last.is_a?(Prism::LocalVariableWriteNode) && else_last.name.to_s == name
    end

    def branch_array_accumulator_if_code(node, name)
      runtime_is_a = runtime_is_a_predicate(node.predicate)
      optional_truthy = runtime_is_a ? nil : optional_union_truthy_if_guard(node.predicate)
      predicate = if runtime_is_a
        "#{runtime_is_a[:receiver_code]} IS_A #{runtime_is_a[:expected_type]} AS #{runtime_is_a[:binding_name]}"
      elsif optional_truthy
        "#{optional_truthy[:receiver_code]} EXISTS AS #{optional_truthy[:binding_name]}"
      else
        predicate_code(node.predicate)
      end
      then_code = with_indent do
        if runtime_is_a
          with_narrowing_context(runtime_is_a) { branch_array_accumulator_statements(node.statements, name) }
        elsif optional_truthy
          with_optional_truthy_context(optional_truthy) { branch_array_accumulator_statements(node.statements, name) }
        else
          branch_array_accumulator_statements(node.statements, name)
        end
      end
      consequent = node.consequent
      else_code = if consequent.is_a?(Prism::IfNode)
        with_indent { branch_array_accumulator_if_code(consequent, name) }
      else
        with_indent { branch_array_accumulator_statements(consequent&.statements, name) }
      end
      "IF #{predicate} THEN\n#{then_code}\n#{indent}ELSE\n#{else_code}\n#{indent}END"
    end

    def branch_array_accumulator_statements(statements, name)
      body = statements&.body || []
      return "" if body.empty?

      prefix = body[0...-1].filter_map do |statement|
        code = visit(statement)
        format_statement_code(code) unless code.empty?
      end
      assignment = body.last
      value = assignment.is_a?(Prism::LocalVariableWriteNode) ? assignment.value : assignment
      prefix << branch_array_accumulator_assignment(name, value)
      prefix.join("\n")
    end

    def statement_node_code(node)
      return visit(node) unless node.is_a?(Prism::CaseNode)

      target = node.predicate ? visit(node.predicate) : nil
      render_case_as_condition_chain(node, target)
    end
    public :statement_node_code

    def runtime_is_a_exit_guard(stmt)
      return nil unless stmt.is_a?(Prism::UnlessNode)
      return nil if stmt.consequent

      predicate = stmt.predicate
      remaining_predicate = nil
      if predicate.is_a?(Prism::AndNode)
        runtime_is_a = runtime_is_a_predicate(predicate.left)
        remaining_predicate = predicate.right if runtime_is_a
      else
        runtime_is_a = runtime_is_a_predicate(predicate)
      end
      return nil unless runtime_is_a

      body = stmt.statements&.body || []
      return nil unless body.length == 1
      return nil unless guard_exit_statement?(body.first)

      runtime_is_a.merge(exit_statement: body.first, remaining_predicate: remaining_predicate)
    end

    def pipeline_guarded_narrowing_expression(statements)
      return nil unless statements.length >= 2

      guard = runtime_is_a_exit_guard(statements.first)
      return nil unless guard
      exit_statement = guard[:exit_statement]
      return nil unless exit_statement.is_a?(Prism::CallNode) && ruby_raise_call?(exit_statement)

      remainder = with_narrowing_context(guard) do
        statements.drop(1).map.with_index do |statement, index|
          code = visit(statement).delete_suffix(";")
          index == statements.length - 2 ? code : "#{code};"
        end.join("\n")
      end
      then_body = remainder.lines.map { |line| "  #{line.rstrip}" }.join("\n")
      exit_code = visit(exit_statement).delete_suffix(";")
      exit_value = "CAST(#{exit_code} AS #{guard[:expected_type]})"
      "(IF #{guard[:receiver_code]} IS_A #{guard[:expected_type]} AS #{guard[:binding_name]} THEN\n" \
        "#{then_body}\nELSE\n  #{exit_value}\nEND)"
    end
    public :pipeline_guarded_narrowing_expression

    def guard_exit_statement?(stmt)
      stmt.is_a?(Prism::ReturnNode) || stmt.is_a?(Prism::BreakNode) ||
        stmt.is_a?(Prism::NextNode) || (stmt.is_a?(Prism::CallNode) && ruby_raise_call?(stmt))
    end

    def optional_nil_exit_guard(stmt)
      if stmt.is_a?(Prism::IfNode) && !stmt.consequent
        receiver = nil_predicate_receiver(stmt.predicate)
        receiver_type = inferred_clear_type(receiver) if receiver
        body = stmt.statements&.body || []
        if receiver && receiver_type.to_s.start_with?("?") && body.any? && guard_exit_statement?(body.last)
          receiver_name = optional_receiver_name(receiver)
          return {
            receiver_name: receiver_name,
            receiver_node: receiver,
            receiver_code: visit(receiver),
            binding_name: optional_guard_binding_name(receiver_name),
            payload_type: receiver_type.to_s.delete_prefix("?"),
            remaining_predicate: nil,
            exit_statements: body,
          }
        end
      end

      if stmt.is_a?(Prism::IfNode) && !stmt.consequent && stmt.predicate.is_a?(Prism::OrNode)
        receiver = nil_predicate_receiver(stmt.predicate.left)
        receiver_type = inferred_clear_type(receiver) if receiver
        body = stmt.statements&.body || []
        if receiver && receiver_type.to_s.start_with?("?") && body.any? && guard_exit_statement?(body.last)
          receiver_code = visit(receiver)
          receiver_name = optional_receiver_name(receiver)
          return {
            receiver_name: receiver_name,
            receiver_node: receiver,
            receiver_code: receiver_code,
            binding_name: optional_guard_binding_name(receiver_name),
            payload_type: receiver_type.to_s.delete_prefix("?"),
            remaining_predicate: stmt.predicate.right,
            exit_statements: body,
          }
        end
      end

      return nil unless stmt.is_a?(Prism::UnlessNode)
      return nil if stmt.consequent

      predicate = stmt.predicate
      remaining_predicate = nil
      if predicate.is_a?(Prism::AndNode) && predicate.left.is_a?(Prism::LocalVariableReadNode)
        remaining_predicate = predicate.right
        predicate = predicate.left
      end
      return nil unless predicate.is_a?(Prism::LocalVariableReadNode)

      receiver_name = predicate.name.to_s
      receiver_type = static_clear_type_for_receiver(receiver_name)
      return nil unless receiver_type.to_s.start_with?("?")

      body = stmt.statements&.body || []
      return nil unless body.any?
      return nil unless guard_exit_statement?(body.last)

      {
        receiver_name: receiver_name,
        receiver_code: visit(predicate),
        binding_name: optional_guard_binding_name(receiver_name),
        payload_type: receiver_type.to_s.delete_prefix("?"),
        remaining_predicate: remaining_predicate,
        rest_when_remaining: !remaining_predicate.nil?,
        exit_statements: body,
      }
    end

    def render_optional_nil_guard(guard, rest_statements)
      then_body = with_indent do
        mutable_binding = mutable_runtime_narrowing_alias(guard, rest_statements)
        context = narrowing_context_with_binding(guard, mutable_binding)
        declaration = mutable_narrowing_declaration(guard, mutable_binding)
        rendered = with_optional_unwrap_context(context) do
          if guard[:remaining_predicate]
            predicate = visit(guard[:remaining_predicate])
            exit_body = with_indent do
              guard[:exit_statements].map { |stmt| format_statement_code(visit(stmt)) }.join("\n")
            end
            rest_body = with_indent { guarded_rest_statement_list(rest_statements) }
            then_body, else_body = guard[:rest_when_remaining] ? [rest_body, exit_body] : [exit_body, rest_body]
            format_statement_code("IF #{predicate} THEN\n#{then_body}\nELSE\n#{else_body}\nEND")
          else
            guarded_rest_statement_list(rest_statements)
          end
        end
        [declaration, rendered].compact.join("\n")
      end
      else_body = with_indent do
        guard[:exit_statements].map { |stmt| format_statement_code(visit(stmt)) }.join("\n")
      end
      "IF #{guard[:receiver_code]} EXISTS AS #{guard[:binding_name]} THEN\n#{then_body}\nELSE\n#{else_body}\nEND"
    end

    def render_runtime_is_a_guard(guard, rest_statements)
      pred = "#{guard[:receiver_code]} IS_A #{guard[:expected_type]} AS #{guard[:binding_name]}"
      then_body = with_indent do
        mutable_binding = mutable_runtime_narrowing_alias(guard, rest_statements)
        context = narrowing_context_with_binding(guard, mutable_binding)
        declaration = mutable_narrowing_declaration(guard, mutable_binding)
        rendered = with_narrowing_context(context) do
          if guard[:remaining_predicate]
            remaining = predicate_code(guard[:remaining_predicate])
            success = with_indent { guarded_rest_statement_list(rest_statements) }
            failure = with_indent { format_statement_code(visit(guard[:exit_statement])) }
            "IF #{remaining} THEN\n#{success}\n#{indent}ELSE\n#{failure}\n#{indent}END"
          else
            guarded_rest_statement_list(rest_statements)
          end
        end
        [declaration, rendered].compact.join("\n")
      end
      else_body = with_indent { format_statement_code(visit(guard[:exit_statement])) }
      "IF #{pred} THEN\n#{then_body}\nELSE\n#{else_body}\nEND"
    end

    def guarded_rest_statement_list(rest_statements)
      if @inside_function && @current_function_returns_value && @function_statement_list_depth == 1
        render_returning_statement_array(rest_statements)
      else
        visit_statement_list(rest_statements)
      end
    end

    def with_optional_unwrap_context(guard)
      if guard[:receiver_node] && !guard[:receiver_node].is_a?(Prism::LocalVariableReadNode)
        return with_structural_code_override(guard[:receiver_node], guard[:binding_name]) { yield }
      end

      receiver_name = guard[:receiver_name]
      payload_type = guard[:payload_type]
      binding_name = guard[:binding_name]
      old_types = @local_types.dup
      old_shapes = @local_shapes.dup
      @narrowed_optional_storage_locals ||= Set.new
      old_narrowed_optional_storage_locals = @narrowed_optional_storage_locals.dup
      @local_types[receiver_name] = payload_type
      @local_shapes[receiver_name] = clear_type_shape(payload_type)
      @local_types[binding_name] = payload_type
      @local_shapes[binding_name] = clear_type_shape(payload_type)
      @narrowed_optional_storage_locals << receiver_name if union_like_type?(payload_type)
      renames = { receiver_name => binding_name }
      with_renames(renames) { yield }
    ensure
      if old_types
        @local_types = old_types
        @local_shapes = old_shapes
        @narrowed_optional_storage_locals = old_narrowed_optional_storage_locals
      end
    end

    def optional_receiver_name(receiver)
      case receiver
      when Prism::LocalVariableReadNode
        receiver.name.to_s
      when Prism::InstanceVariableReadNode
        receiver.name.to_s.delete_prefix("@")
      else
        "optional_value"
      end
    end

    def with_narrowing_context(runtime_is_a)
      binding_name = runtime_is_a[:binding_name]
      old_types = @local_types.dup
      old_shapes = @local_shapes.dup
      @local_types[binding_name] = runtime_is_a[:expected_type]
      @local_shapes[binding_name] = clear_type_shape(runtime_is_a[:expected_type])
      with_renames(runtime_is_a[:renames]) { yield }
    ensure
      @local_types = old_types
      @local_shapes = old_shapes
    end

    def mutable_runtime_narrowing_alias(runtime_is_a, statements)
      receiver_name = runtime_is_a[:receiver_name].to_s
      return nil if receiver_name.empty?

      nodes = statements.is_a?(Array) ? statements : [statements]
      mutable = nodes.any? { |node| collect_mutated_parameter_receivers(node).include?(receiver_name) }

      unless mutable
        walk = lambda do |node|
          next unless node
          if node.is_a?(Prism::CallNode) && (fact = @typed_ir.call_for(node)) && fact.dispatch == :instance
            mutable = true if fact.receiver_ownership == :borrow_mut
          end
          mutable = true if node.is_a?(Prism::CallNode) && mutable_parameter_function_name?(node.name.to_s)
          if node.is_a?(Prism::CallNode) && node.receiver
            receiver_type = @typed_ir.value_for(node.receiver)&.type&.to_clear || inferred_clear_type(node.receiver)
            owner = instance_method_owner_type(receiver_type, clear_function_name(node.name.to_s)) if receiver_type
            mutable = true if owner && mutating_instance_method?(owner, node.name.to_s)
          end
          node.child_nodes.each { |child| walk.call(child) if child } unless mutable
        end
        nodes.each { |node| walk.call(node) unless mutable }
      end
      return nil unless mutable

      base = "#{runtime_is_a[:binding_name]}_mutable"
      candidate = base
      index = 2
      while @local_types.key?(candidate) || @current_param_names.include?(candidate)
        candidate = "#{base}_#{index}"
        index += 1
      end
      candidate
    end

    def narrowing_context_with_binding(context, binding_name)
      return context unless binding_name

      original = context[:binding_name]
      renames = context.fetch(:renames, {}).transform_values do |value|
        value == original ? binding_name : value
      end
      context.merge(binding_name: binding_name, renames: renames)
    end

    def mutable_narrowing_declaration(context, binding_name)
      return nil unless binding_name

      format_statement_code("MUTABLE #{binding_name} = COPY #{context[:binding_name]}")
    end

    def with_runtime_is_a_else_context(runtime_is_a)
      return yield unless runtime_is_a

      receiver_name = runtime_is_a[:receiver_name]
      receiver_type = static_clear_type_for_receiver(receiver_name)
      unwrap_code = optional_unwrap_code(receiver_name)
      unless @renames[receiver_name] == unwrap_code && receiver_type && !receiver_type.to_s.start_with?("?")
        return yield
      end

      old_renames = @renames.dup
      @renames.delete(receiver_name)
      yield
    ensure
      @renames = old_renames if old_renames
    end

    def optional_union_truthy_if_guard(predicate)
      return nil unless predicate.is_a?(Prism::LocalVariableReadNode) ||
        predicate.is_a?(Prism::InstanceVariableReadNode) ||
        (predicate.is_a?(Prism::CallNode) && @typed_ir.field_for(predicate))

      field_fact = @typed_ir.field_for(predicate) if predicate.is_a?(Prism::CallNode)
      receiver_name = field_fact ? field_fact.field.name : optional_receiver_name(predicate)
      receiver_type = if field_fact
        field_fact.field_type.to_clear
      elsif predicate.is_a?(Prism::LocalVariableReadNode)
        static_clear_type_for_receiver(receiver_name)
      else
        inferred_clear_type(predicate)
      end
      return nil unless receiver_type.to_s.start_with?("?")

      payload_type = receiver_type.to_s.delete_prefix("?")
      {
        receiver_name: receiver_name,
        receiver_code: visit(predicate),
        binding_name: optional_guard_binding_name(receiver_name),
        payload_type: payload_type,
        union_like: union_like_type?(payload_type),
        receiver_node: predicate,
      }
    end

    def optional_truthies_in_and(predicate)
      return [] unless predicate.is_a?(Prism::AndNode)

      guards = [
        optional_union_truthy_if_guard(predicate.left),
        *optional_truthies_in_and(predicate.left),
        optional_union_truthy_if_guard(predicate.right),
        *optional_truthies_in_and(predicate.right),
      ].compact
      guards.uniq { |guard| guard[:receiver_name] }.map do |guard|
        guard.merge(binding_name: optional_unwrap_code(guard[:receiver_code]))
      end
    end

    def with_optional_truthy_contexts(guards, &block)
      return block.call if guards.empty?

      first, *rest = guards
      with_optional_truthy_context(first) { with_optional_truthy_contexts(rest, &block) }
    end

    # Like with_optional_truthy_contexts, but for a compound `x && y && ...`
    # predicate, which lowers to `(x != NIL) AND ...` and flow-narrows each
    # local in place. Narrow the types without renaming to `x?`.
    def with_local_optionals_narrowed(guards, &block)
      return block.call if guards.empty?

      first, *rest = guards
      if first[:receiver_node].is_a?(Prism::LocalVariableReadNode)
        with_local_optional_narrowed(first[:receiver_name], first[:payload_type]) do
          with_local_optionals_narrowed(rest, &block)
        end
      else
        with_optional_truthy_context(first) { with_local_optionals_narrowed(rest, &block) }
      end
    end

    def with_optional_truthy_context(guard)
      receiver_name = guard[:receiver_name]
      payload_type = guard[:payload_type]
      binding_name = guard[:binding_name]
      old_types = @local_types.dup
      old_shapes = @local_shapes.dup
      @narrowed_optional_storage_locals ||= Set.new
      old_narrowed_optional_storage_locals = @narrowed_optional_storage_locals.dup
      old_active_narrowed_binding_names = @active_narrowed_binding_names.dup

      if binding_name && payload_type
        @local_types[binding_name] = payload_type
        @local_shapes[binding_name] = clear_type_shape(payload_type)
        @active_narrowed_binding_names << binding_name
      end

      if guard[:receiver_node] && !guard[:receiver_node].is_a?(Prism::LocalVariableReadNode)
        begin
          return with_structural_code_override(guard[:receiver_node], guard[:binding_name]) { yield }
        ensure
          @local_types = old_types
          @local_shapes = old_shapes
          @narrowed_optional_storage_locals = old_narrowed_optional_storage_locals
          @active_narrowed_binding_names = old_active_narrowed_binding_names
        end
      end

      @local_types[receiver_name] = payload_type
      @local_shapes[receiver_name] = clear_type_shape(payload_type)
      @narrowed_optional_storage_locals << receiver_name if guard[:union_like]
      with_renames(receiver_name => binding_name) { yield }
    ensure
      if old_types
        @local_types = old_types
        @local_shapes = old_shapes
        @narrowed_optional_storage_locals = old_narrowed_optional_storage_locals
        @active_narrowed_binding_names = old_active_narrowed_binding_names
      end
    end

    def optional_guard_binding_name(receiver_name)
      base = "#{receiver_name}_value"
      return base unless @local_types.key?(base) || @current_param_names.include?(base)

      index = 2
      loop do
        candidate = "#{base}_#{index}"
        return candidate unless @local_types.key?(candidate) || @current_param_names.include?(candidate)

        index += 1
      end
    end

    def union_like_type?(type)
      @union_types[type] || @generated_union_defs[type] || @type_aliases[type]
    end

    def visit_else_node(node)
      visit(node.statements)
    end

    def visit_integer_node(node)
      # CLEAR lexes unary `-` separately from the integer token. Emitting the
      # Int64 minimum directly would therefore make the lexer range-check the
      # positive magnitude (2^63) before the negation is parsed. Keep both
      # operands representable while preserving the exact value.
      return "(-9223372036854775807 - 1)" if node.value == -(2**63)

      # Bare decimal literals lex in the Int64 domain; anything above i64 max
      # is only representable through the UINT64 token.
      if node.value > 9_223_372_036_854_775_807
        if node.value <= 18_446_744_073_709_551_615
          return "#{node.value}_u64"
        end
        return unsupported_comment(node, "integer literal #{node.value} exceeds the UInt64 range")
      end

      node.value.to_s
    end

    def visit_float_node(node)
      node.value.to_s
    end

    def visit_string_node(node)
      # Prism#content is the RAW source slice (escapes unprocessed);
      # unescaped is the actual string value. Emitting content doubles
      # every escape sequence.
      clear_string_literal(node.unescaped)
    end

    def visit_symbol_node(node)
      value = node.value.to_s
      if value.match?(/\A[A-Za-z]\w*\z/) && !CLEAR_KEYWORDS.include?(value)
        return ":#{value}"
      end

      "symbol(#{value.inspect})"
    end

    def visit_interpolated_symbol_node(node)
      parts = node.parts.map { |part| interpolated_string_part_for_literal(part) }.join
      "symbol(\"#{parts}\")"
    end

    def static_send_method_name(node)
      name = case node
             when Prism::SymbolNode
               node.value.to_s
             when Prism::StringNode
               node.content
             end
      return nil unless name&.match?(/\A[A-Za-z_]\w*[!?=]?\z/)
      return nil if CLEAR_KEYWORDS.include?(name)

      name
    end

    def visit_local_variable_read_node(node)
      name = node.name.to_s
      if @constructor_placeholder_param_names&.include?(name)
        return "COPY #{name}"
      end

      @local_constant_values[name] || @renames[name] || name
    end

    def visit_self_node(node)
      "self"
    end

    def visit_local_variable_target_node(node)
      name = node.name.to_s
      @renames[name] || name
    end

    def visit_block_parameters_node(node)
      visit(node.parameters)
    end

    def visit_instance_variable_read_node(node)
      name = node.name.to_s.delete_prefix("@")
      if @singleton_class_depth.positive? || (@current_class && !@inside_function) ||
         (@inside_class_method && @class_variables.include?(name))
        return class_storage_variable_name(name)
      end

      "self.#{name}"
    end

    def visit_class_variable_read_node(node)
      class_variable_name(node.name)
    end

    def visit_class_variable_write_node(node)
      name = class_variable_name(node.name)
      val = visit(node.value)
      if @class_variables.include?(name) || @inside_function
        "#{name} = #{val}"
      else
        @class_variables << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_constant_read_node(node)
      name = node.name.to_s
      if name == "UNSET" && @current_class
        return sentinel_literal_for("#{@current_class}::UNSET") || name
      end

      literal = @constant_literal_values[name]
      return literal if literal

      if (inline_node = @constant_inline_nodes[name])
        expanded = expand_inline_constant(name, inline_node)
        return expanded if expanded
      end

      emitted = @constant_names[name]
      return name unless emitted
      if @local_data_constant_names.include?(name)
        return "ruby_constant_#{emitted}()"
      end

      type = (@constant_types[name] || @constant_types[emitted]).to_s.delete_prefix("?")
      copyable_scalar = type == "String@symbol" ||
        type.match?(/\A(?:Bool|U?Int\d*|Float\d*|Byte)\z/)
      copyable_scalar ? "COPY #{emitted}" : emitted
    end

    # Inlining a constant means visiting its VALUE expression, which may
    # itself reference constants - including, through a cycle, the one being
    # inlined. Ruby tolerates that at load time; a naive expansion here
    # recurses until the stack dies (real corpus: loading ast/parser.rb's
    # constants while transpiling one of its own partial-class files).
    # Return nil on re-entry so the caller falls through to the ordinary
    # emitted-constant-name path, which references the constant instead of
    # expanding it.
    def expand_inline_constant(key, inline_node)
      @inlining_constants ||= Set.new
      return nil if @inlining_constants.include?(key)

      @inlining_constants << key
      begin
        literal_node = if inline_node.is_a?(Prism::CallNode) && inline_node.name.to_s == "freeze"
          inline_node.receiver
        else
          inline_node
        end
        constant_type = @constant_types[key] || @constant_types[key.to_s.split("::").last]
        if (typed_hash = typed_hash_literal_code(literal_node, constant_type))
          return typed_hash
        end

        visit(inline_node)
      ensure
        @inlining_constants.delete(key)
      end
    end

    def visit_constant_path_node(node)
      path = node.location.slice.strip
      constant_name = path.split("::").last
      namespace = path.split("::")[0...-1].join("::")
      sentinel = sentinel_literal_for(path)
      return sentinel if sentinel
      return @helper_config.clear_type(path) if @helper_config.clear_type(path)
      return "symbol(#{constant_name.inspect})" if namespace == "EffectTracker"
      if (inline_node = @constant_inline_nodes[path] || @constant_inline_nodes[constant_name])
        expanded = expand_inline_constant(path, inline_node)
        return expanded if expanded
      end
      return @constant_names[path] if @constant_names[path]
      if @module_namespace_names.include?(namespace)
        return @constant_names[constant_name] || constant_variable_name(constant_name)
      end
      if @imported_data_constant_names.include?(constant_name)
        return "ruby_constant_#{constant_variable_name(constant_name)}()"
      end
      @constant_names[constant_name] || path.gsub("::", ".")
    end

    def sentinel_literal_for(path)
      sentinel = sentinel_type_for_path(path)
      "#{sentinel}{}" if sentinel
    end

    def sentinel_type_for_node(node)
      case node
      when Prism::ConstantReadNode
        return nil unless node.name.to_s == "UNSET" && @current_class

        sentinel_type_for_path("#{@current_class}::UNSET")
      when Prism::ConstantPathNode
        sentinel_type_for_path(node.location.slice.strip)
      end
    end

    def sentinel_type_for_path(path)
      case path
      when "TypeCapabilities::UNSET"
        "TypeCapabilityUnset"
      when "TypePlacement::UNSET"
        "TypePlacementUnset"
      end
    end

    def visit_arguments_node(node)
      node.arguments.map { |arg| visit(arg) }.join(", ")
    end

    def visit_implicit_node(node)
      visit(node.value)
    end

    def expression_argument_code(node)
      if node.is_a?(Prism::BeginNode) && !node.rescue_clause && !node.ensure_clause && !node.else_clause
        # A plain `begin ... end` in value position (an || fallback, an
        # argument) renders as a CLEAR value block: statements, then the
        # last expression as the block's value.
        stmts = node.statements&.body || []
        return "NIL" if stmts.empty?

        rendered = stmts[0...-1].map { |stmt| statement_code(visit(stmt)) }
        last = expression_argument_code(stmts.last)
        # A block-shaped result expression (IF/CASE) must be parenthesized
        # inside the value block or the parser reads it as a statement.
        if stmts.last.is_a?(Prism::IfNode) || stmts.last.is_a?(Prism::UnlessNode) || stmts.last.is_a?(Prism::CaseNode)
          last = "(#{last})"
        end
        return last if rendered.empty?

        return "{ MUTABLE rtoc_value_block_marker = 0; #{rendered.join("\n")}\n#{last} }"
      end
      if node.is_a?(Prism::IfNode)
        return visit_if_expression_or_placeholder(node).strip
      elsif node.is_a?(Prism::UnlessNode)
        value = case_arm_value_code(node.statements)
        return visit(node) unless value

        fallback = node.consequent ? case_arm_value_code(node.consequent.statements) : "NIL"
        return "IF !(#{predicate_code(node.predicate)}) THEN\n#{indent}  #{value}\n#{indent}ELSE\n#{indent}  #{fallback || 'NIL'}\n#{indent}END"
      elsif node.is_a?(Prism::CaseNode)
        return visit_case_expression_or_placeholder(node).strip
      elsif node.is_a?(Prism::ParenthesesNode)
        body = node.body&.body || []
        if body.length == 1 && (body.first.is_a?(Prism::IfNode) || body.first.is_a?(Prism::UnlessNode) || body.first.is_a?(Prism::CaseNode))
          return "(#{expression_argument_code(body.first)})"
        end
      end

      visit(node)
    end
    public :expression_argument_code

    def expression_if_code(node)
      if_expression_code(node)
    end
    public :expression_if_code

    def visit_local_variable_write_node(node)
      ruby_name = node.name.to_s
      renamed_name = @renames[ruby_name]
      name = renamed_name.to_s.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/) ? renamed_name : ruby_name
      original_value_node = node.value
      value_node = original_value_node
      type_annotation = nil
      forced_untyped = explicit_sorbet_untyped_value?(value_node)
      cast_value = sorbet_cast_expression(value_node) if sorbet_call?(value_node, "cast")
      if (typed_value = sorbet_typed_value(value_node))
        value_node, type_annotation = typed_value
        type_annotation = "Any" if forced_untyped
      end
      if value_node.is_a?(Prism::BeginNode) && value_node.ensure_clause &&
         value_node.rescue_clause.nil? && value_node.else_clause.nil?
        return translate_ensure_only_begin(value_node, binding: name)
      end
      if value_node.is_a?(Prism::IndexOrWriteNode)
        # `local = hash[k] ||= default` — the or-assign is a STATEMENT in
        # CLEAR; run it first, then bind the (now non-nil) slot value.
        stmt = statement_code(visit(value_node))
        read = index_or_write_lhs_code(value_node)
        assignment = if @declared_locals.include?(name)
          "#{name} = UNWRAP (#{read});"
        else
          @declared_locals << name
          "MUTABLE #{name} = UNWRAP (#{read});"
        end
        return "#{stmt}\n#{assignment}"
      end
      if indexed_enumerator_nil_return_chain?(value_node)
        result_name = next_generated_local("indexed_result")
        call = visit(value_node)
        assignment = if @declared_locals.include?(name)
          "#{name} = #{optional_unwrap_code(result_name)};"
        else
          @declared_locals << name
          "MUTABLE #{name} = #{optional_unwrap_code(result_name)};"
        end
        return "MUTABLE #{result_name} = #{call};\n" \
          "IF #{result_name} == NIL THEN\n#{indent}  RETURN NIL;\n#{indent}END\n" \
          "#{assignment}"
      end
      record_hash_default(name, value_node)
      lazy_hash_init = nil
      if (index_node = hash_default_index_node(value_node)) &&
         (spec = hash_default_spec_for_receiver(index_node.receiver)) && spec[:kind] == :factory
        receiver_code = visit(index_node.receiver)
        key_node = index_node.arguments&.arguments&.first
        if key_node
          key_code = visit(key_node)
          default_code = hash_default_code(spec, receiver_code, key_code)
          lazy_hash_init = "IF #{receiver_code}[#{key_code}] == NIL THEN\n#{indent}  #{receiver_code}[#{key_code}] = #{default_code};\n#{indent}END"
          @hash_backed_locals[name] = { receiver: receiver_code, key: key_code }
        end
      end
      if type_annotation && @declared_locals.include?(name) &&
         value_node.is_a?(Prism::LocalVariableReadNode) && value_node.name.to_s == name
        @local_types[name] = type_annotation
        @local_shapes[name] = clear_type_shape(type_annotation)
        return ""
      end
      if @declared_locals.include?(name) && sorbet_call?(value_node, "must")
        args = value_node.arguments ? value_node.arguments.arguments : []
        if args.length == 1 && args.first.is_a?(Prism::LocalVariableReadNode) && args.first.name.to_s == name
          narrowed_type = @local_types[name].to_s.delete_prefix("?")
          unless narrowed_type.empty?
            binding_name = optional_guard_binding_name(name)
            @renames[name] = binding_name
            @declared_locals << binding_name
            @local_types[binding_name] = narrowed_type
            @local_shapes[binding_name] = clear_type_shape(narrowed_type)
            return "MUTABLE #{binding_name}: #{narrowed_type} = #{optional_unwrap_code(name)}"
          end
        end
      end
      if value_node.is_a?(Prism::NilNode)
        @local_constant_values[name] = "NIL"
      else
        @local_constant_values.delete(name)
      end

      if value_node.is_a?(Prism::OrNode) && value_node.left.is_a?(Prism::CallNode) &&
         value_node.left.safe_navigation?
        safe_call = value_node.left
        receiver = visit(safe_call.receiver)
        @lowering_safe_navigation << safe_call.object_id
        # `x&.method || fallback` lowers to `IF x != NIL THEN ... x.method ... END`;
        # for a bare local x, CLEAR's own IF narrows it to its payload type in
        # place (same treatment as the truthy-guard ternary case above), so the
        # call receiver stays plain. `x?` there is UNWRAP_NON_OPTIONAL on the
        # already-narrowed local. Non-local receivers (field/method calls) have
        # no in-place narrowing and still need the renamed `?`-unwrap form.
        receiver_code = if safe_call.receiver.is_a?(Prism::LocalVariableReadNode)
          receiver
        else
          optional_unwrap_code(receiver)
        end
        present_value = with_node_code_override(safe_call.receiver, receiver_code) do
          visit_call_node(safe_call)
        end
        @lowering_safe_navigation.delete(safe_call.object_id)
        fallback = expression_argument_code(value_node.right)
        result_type = inferred_clear_type(value_node.right).to_s
        typed = ["", "Any", "Auto"].include?(result_type) ? "" : ": #{result_type}"
        declaration = if @declared_locals.include?(name)
          "#{name} = #{fallback};"
        else
          @declared_locals << name
          "MUTABLE #{name}#{typed} = #{fallback};"
        end
        unless ["", "Any", "Auto"].include?(result_type)
          @local_types[name] = result_type
          @local_shapes[name] = clear_type_shape(result_type)
        end
        present_value = "COPY #{present_value}" if affine_clear_type?(result_type)
        # A mutable-receiver call materializes prefix statements; they hoist
        # INSIDE the guard, above the assignment (embedding them in the value
        # produced `x = MUTABLE ... = ...` — invalid CLEAR).
        present_prefix = nil
        if present_value.include?("\n") && present_value.lstrip.start_with?("MUTABLE rtoc_")
          hoist_lines = present_value.lines.map(&:rstrip).reject(&:empty?)
          present_value = hoist_lines.pop.to_s
          present_prefix = hoist_lines.join("\n#{indent}  ")
        end
        inner = "#{name} = #{present_value};"
        inner = "#{present_prefix}\n#{indent}  #{inner}" if present_prefix
        return "#{declaration}\nIF #{receiver} != NIL THEN\n#{indent}  #{inner}\n#{indent}END"
      end

      if value_node.is_a?(Prism::CallNode) && value_node.safe_navigation?
        receiver_type = clear_type_for_receiver_node(value_node.receiver).to_s.delete_prefix("?")
        result_type = inferred_clear_type(value_node).to_s
        if ["", "Any", "Auto"].include?(result_type)
          result_type = method_return_type_for(value_node.name.to_s, receiver_type).to_s
        end
        payload_type = result_type.delete_prefix("?")
        if affine_clear_type?(payload_type)
          receiver = visit(value_node.receiver)
          @lowering_safe_navigation << value_node.object_id
          inner = with_node_code_override(value_node.receiver, optional_unwrap_code(receiver)) do
            visit_call_node(value_node)
          end
          @lowering_safe_navigation.delete(value_node.object_id)
          optional_type = optional_clear_type(payload_type)
          declaration = if @declared_locals.include?(name)
            "#{name} = NIL;"
          else
            @declared_locals << name
            "MUTABLE #{name}: #{optional_type} = NIL;"
          end
          @local_types[name] = optional_type
          @local_shapes[name] = clear_type_shape(payload_type)
          return "#{declaration}\nIF #{receiver} != NIL THEN\n#{indent}  #{name} = COPY #{inner};\n#{indent}END"
        end
      end

      if value_node.is_a?(Prism::IfNode) &&
         (type_annotation || struct_if_assignment_type?(value_node) ||
          inferred_if_assignment_type(value_node).to_s == "String" || !if_expression_code(value_node))
        return visit_local_variable_if_assignment(name, value_node, type_annotation)
      end

      if value_node.is_a?(Prism::CaseNode) && !@declared_locals.include?(name) &&
         case_needs_statement_assignment?(value_node, name, type_annotation)
        return visit_local_variable_case_assignment(name, value_node, type_annotation)
      end

      if value_node.is_a?(Prism::CallNode) &&
         (shared_field_assignment = shared_union_field_statement_assignment(name, value_node, type_annotation))
        return shared_field_assignment
      end

      scanner_value_node = scanner_scan_value_call(value_node)
      scanner_value = !scanner_value_node.nil?
      scanner_value_unwrapped = scanner_value && sorbet_call?(value_node, "must")
      scanner_borrowed_value = scanner_value || scanner_borrowed_value_call?(value_node)
      @scanner_scan_value_nodes << scanner_value_node.object_id if scanner_value_node
      val = if value_node.is_a?(Prism::IfNode)
        visit_if_expression_or_placeholder(value_node)
      elsif value_node.is_a?(Prism::UnlessNode)
        expression_argument_code(value_node)
      elsif value_node.is_a?(Prism::CaseNode)
        visit_case_expression_or_placeholder(value_node)
      elsif (typed_hash = typed_hash_literal_code(value_node, type_annotation))
        typed_hash
      else
        cast_value || sorbet_must_assignment_unwrap_code(value_node) || visit(value_node)
      end
      @scanner_scan_value_nodes.delete(scanner_value_node.object_id) if scanner_value_node
      storage_ownership = @typed_ir.storage_ownership_for(node)
      storage_copy = storage_ownership&.mode == :copy
      storage_retain = storage_ownership&.mode == :retain
      if storage_retain && retained_identity_source?(value_node)
        val = "KEEP #{val}" unless val.start_with?("KEEP ")
      elsif scanner_borrowed_value || storage_copy ||
            (!storage_retain && copyable_local_read_source?(value_node, type_annotation))
        val = "COPY #{val}" unless val.start_with?("COPY ")
      end
      # A mutable-receiver call materializes its receiver as prefix statements
      # (MUTABLE rtoc_mutable_receiver_N = ...). In assignment position those
      # statements must be hoisted ABOVE the assignment — embedding them in
      # the value produced `x = MUTABLE ... = ...` (invalid CLEAR).
      hoisted_value_prefix = nil
      if val.include?("\n") && val.lstrip.start_with?("MUTABLE rtoc_")
        hoist_lines = val.lines.map(&:rstrip).reject(&:empty?)
        val = hoist_lines.pop.to_s
        hoisted_value_prefix = hoist_lines.join("\n")
      end
      if @declared_locals.include?(name) && @branch_array_accumulators.include?(name)
        return branch_array_accumulator_assignment(name, value_node)
      end
      shape = scanner_value ? "string" : inferred_shape(value_node)
      inferred_type = type_annotation || if scanner_value
        scanner_value_unwrapped ? "String" : "?String"
      else
        inferred_clear_type(value_node)
      end
      if storage_retain && retainable_ruby_identity_type?(inferred_type)
        inferred_type = retained_identity_type(inferred_type)
        type_annotation = retained_identity_type(type_annotation) if type_annotation
      end
      if !type_annotation && value_node.is_a?(Prism::CallNode) && value_node.name.to_s == "[]" &&
         value_node.receiver
        receiver_type = clear_type_for_receiver_node(value_node.receiver)
        if map_value_clear_type(receiver_type)
          inferred_text = (inferred_type || "Any").to_s
          inferred_type = inferred_text.start_with?("?") ? inferred_text : "?#{inferred_text}"
        end
      end
      if @declared_locals.include?(name)
        argument_node = cast_value ? original_value_node : value_node
        val = wrap_argument_for_parameter_type(val, argument_node, @local_types[name]) unless @forced_untyped_locals.include?(name)
        @local_shapes[name] = shape
        if forced_untyped
          @forced_untyped_locals << name
          @local_types.delete(name)
        elsif @forced_untyped_locals.include?(name)
          if inferred_type && !["Auto", "Any"].include?(inferred_type.to_s)
            @forced_untyped_locals.delete(name)
            @local_types[name] = inferred_type
          else
            @local_types.delete(name)
          end
        elsif type_annotation == "Auto"
          @local_types.delete(name)
        elsif inferred_type && inferred_type != "Auto" && !@local_types.key?(name)
          @local_types[name] = inferred_type
        end
        assignment = "#{name} = #{val}"
        assignment = "#{hoisted_value_prefix}\n#{assignment}" if hoisted_value_prefix
        lazy_hash_init ? "#{lazy_hash_init}\n#{assignment};" : assignment
      else
        @declared_locals << name
        @local_shapes[name] = shape
        if type_annotation && type_annotation != "Auto"
          argument_node = cast_value ? original_value_node : value_node
          val = wrap_argument_for_parameter_type(val, argument_node, type_annotation)
        end
        if forced_untyped
          @forced_untyped_locals << name
          @local_types.delete(name)
        elsif type_annotation == "Auto"
          @local_types.delete(name)
        elsif inferred_type && inferred_type != "Auto"
          @local_types[name] = inferred_type
        end
        declaration_type = type_annotation
        declaration_type = inferred_type if !declaration_type && storage_retain
        if !declaration_type && value_node.is_a?(Prism::ArrayNode) && inferred_type.to_s.start_with?("Tuple<")
          declaration_type = inferred_type
        end
        if !declaration_type && inferred_type.to_s.include?("@multiowned[]")
          declaration_type = inferred_type
        end
        typed = if declaration_type && declaration_type != "Auto"
          ": #{declaration_type}"
        elsif inferred_type.to_s.start_with?("?")
          # CLEAR deliberately rejects inferred optional bindings. Retaining
          # the concrete payload type here is the Ruby-equivalent of assigning
          # a value that may be nil; `:?` still asks CLEAR to infer that
          # payload from an optional value, which it intentionally rejects.
          ": #{inferred_type}"
        else
          ""
        end
        declaration = "MUTABLE #{name}#{typed} = #{val}"
        declaration = "#{hoisted_value_prefix}\n#{declaration}" if hoisted_value_prefix
        lazy_hash_init ? "#{lazy_hash_init}\n#{declaration};" : declaration
      end
    end

    def branch_array_accumulator_assignment(name, value_node)
      if value_node.is_a?(Prism::ArrayNode)
        element_type = array_element_clear_type(@local_types[name])
        return value_node.elements.map do |element|
          value = expression_argument_code(element)
          value = wrap_argument_for_parameter_type(value, element, element_type) if element_type
          value = "COPY #{value}" if stored_borrowed_value?(element) && !value.start_with?("COPY ")
          "#{mutable_method_receiver_code(name)}.append(#{value});"
        end.join("\n")
      end

      source = visit(value_node)
      item = next_generated_local("array_item")
      "FOR #{item} IN #{source} DO\n#{indent}  #{mutable_method_receiver_code(name)}.append(COPY #{item});\n#{indent}END"
    end

    def scanner_scan_call?(node)
      return false unless node.is_a?(Prism::CallNode) && node.name.to_s == "scan"
      return false unless node.receiver

      registry_receiver_shape(node.receiver) == "scanner" ||
        @helper_config.scanner_receiver?(visit(node.receiver))
    end

    def scanner_scan_value_call(node)
      if sorbet_call?(node, "must")
        args = node.arguments&.arguments || []
        node = args.first if args.length == 1
      end

      node if scanner_scan_call?(node)
    end

    def scanner_getch_call?(node)
      return false unless node.is_a?(Prism::CallNode) && node.name.to_s == "getch"
      return false unless node.receiver

      registry_receiver_shape(node.receiver) == "scanner" ||
        @helper_config.scanner_receiver?(visit(node.receiver))
    end

    def scanner_borrowed_value_call?(node)
      return false unless node.is_a?(Prism::CallNode) && node.receiver
      return false unless %w[matched peek getch []].include?(node.name.to_s)

      registry_receiver_shape(node.receiver) == "scanner" ||
        @helper_config.scanner_receiver?(visit(node.receiver))
    end

    def sorbet_must_assignment_unwrap_code(node)
      return nil unless sorbet_call?(node, "must")

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length == 1
      return nil unless args.first.is_a?(Prism::LocalVariableReadNode)

      source_name = args.first.name.to_s
      return nil unless @narrowed_optional_storage_locals.include?(source_name)

      optional_unwrap_code(source_name)
    end

    def visit_local_variable_if_assignment(name, if_node, type_annotation)
      shape = inferred_shape(if_node)
      known_type = @local_types[name]
      inferred_branch_type = inferred_if_assignment_type(if_node)
      if known_type.to_s.match?(/\AHashMap<Any,\s*Any>\z/) && inferred_branch_type
        known_type = inferred_branch_type
      end
      assignment_type = type_annotation || known_type || syntactic_if_struct_type(if_node) || inferred_branch_type
      needs_branch_slot = assignment_type &&
        (struct_if_assignment_type?(if_node) || union_like_type?(assignment_type.to_s.delete_prefix("?")) ||
         affine_clear_type?(assignment_type) || %w[String String@symbol].include?(assignment_type.to_s)) &&
        default_value_for_type(assignment_type) == "NIL"
      if !@declared_locals.include?(name) && needs_branch_slot
        @declared_locals << name
        @local_shapes[name] = shape
        @local_types[name] = assignment_type
        branch_slot = "#{name}_branch_value"
        branch_code = if_assignment_code(branch_slot, if_node, assignment_type)
        branch_type = optional_clear_type(assignment_type)
        branch_value = assignment_type.to_s.start_with?("?") ? branch_slot : "#{branch_slot}?"
        return "MUTABLE #{branch_slot}: #{branch_type} = NIL;\n#{branch_code}\n" \
               "MUTABLE #{name}: #{assignment_type} = #{branch_value};"
      end

      prefix = ""
      unless @declared_locals.include?(name)
        @declared_locals << name
        @local_shapes[name] = shape
        @local_types[name] = assignment_type if assignment_type && assignment_type != "Auto"
        prefix = "#{predeclared_local_declaration(name, assignment_type)}\n"
      end

      @local_shapes[name] = shape
      @local_types[name] = assignment_type if assignment_type && assignment_type != "Auto"
      "#{prefix}#{if_assignment_code(name, if_node, assignment_type)}"
    end

    def inferred_if_assignment_type(if_node)
      types = []
      has_nil_branch = false
      current = if_node

      loop do
        types << inferred_branch_statement_type(current.statements)
        has_nil_branch ||= branch_ends_in_nil?(current.statements)
        consequent = current.consequent
        if consequent.is_a?(Prism::IfNode)
          current = consequent
          next
        elsif consequent
          types << inferred_branch_statement_type(consequent.statements)
          has_nil_branch ||= branch_ends_in_nil?(consequent.statements)
        end
        break
      end

      compact_types = types.compact
      if has_nil_branch
        value_types = compact_types.reject { |type| type.to_s == "Void" }.uniq
        return optional_clear_type(value_types.first) if value_types.one?
      end
      concrete_maps = compact_types.reject { |type| type.to_s.match?(/\AHashMap<Any,\s*Any>\z/) }.uniq
      if concrete_maps.one? && compact_types.all? { |type| type.to_s.start_with?("HashMap<") }
        return concrete_maps.first
      end
      function_return = @current_function_return_type.to_s
      if function_return.start_with?("HashMap<") && compact_types.any? &&
         compact_types.all? { |type| type.to_s.start_with?("HashMap<") }
        return function_return
      end
      if compact_types.any? && compact_types.all? { |type| type.to_s.end_with?("[]@set") }
        concrete_sets = compact_types.reject { |type| type.to_s == "Any[]@set" }.uniq
        return concrete_sets.first if concrete_sets.one?
      end
      compact_types.uniq.one? ? compact_types.first : nil
    end

    def branch_ends_in_nil?(statements_node)
      statements_node&.body&.last.is_a?(Prism::NilNode)
    end

    def struct_if_assignment_type?(if_node)
      type = inferred_if_assignment_type(if_node).to_s
      affine_clear_type?(type) || !syntactic_if_struct_type(if_node).nil?
    end

    def affine_clear_type?(type)
      text = type.to_s.delete_prefix("?")
      return false if text == "String@symbol"
      return true if text.include?("[]") || text.start_with?("HashMap<")

      base = text.split(/[<\[]/, 2).first.to_s
      known_value_types = %w[
        Any Auto Bool Boolean Byte Float32 Float64 Int8 Int16 Int32 Int64
        Number String UInt8 UInt16 UInt32 UInt64 Void
      ]
      !base.empty? && base.match?(/\A[A-Z]/) && !known_value_types.include?(base)
    end

    # CLEAR aggregates are initially frame-owned. When a value stored inside
    # an aggregate itself owns storage, crossing into a persistent container
    # requires copying the aggregate as a whole. This is queried while the
    # typed IR records the storage edge, before emission begins.
    def aggregate_storage_copy_required?(type)
      normalized = expand_clear_type_alias(type.to_s).to_s.delete_prefix("?")
      base = normalized.split("@", 2).first.to_s
      candidates = [base, resolve_qualified_class_name(base), base.split("::").last].compact.uniq
      fields = candidates.lazy.map { |name| @class_instance_field_types[name] }.find(&:any?)
      return false unless fields

      fields.values.any? { |field_type| copyable_storage_type?(field_type) }
    end

    def syntactic_if_struct_type(if_node)
      types = []
      current = if_node
      loop do
        if current.statements&.body&.last
          types << syntactic_struct_expression_type(current.statements.body.last)
        end
        consequent = current.consequent
        if consequent.is_a?(Prism::IfNode)
          current = consequent
          next
        elsif consequent&.statements&.body&.last
          types << syntactic_struct_expression_type(consequent.statements.body.last)
        end
        break
      end
      concrete = types.compact.uniq
      concrete.one? ? concrete.first : nil
    end

    def inferred_branch_statement_type(statements)
      return nil unless statements.is_a?(Prism::StatementsNode) && statements.body.any?

      expression = statements.body.last
      inferred = inferred_clear_type(expression)
      return inferred if inferred && !["Auto", "Any"].include?(inferred.to_s)

      syntactic_struct_expression_type(expression)
    end

    def syntactic_struct_expression_type(expression)
      return nil unless expression.is_a?(Prism::CallNode) && expression.receiver
      return nil unless expression.receiver.is_a?(Prism::ConstantReadNode) ||
                        expression.receiver.is_a?(Prism::ConstantPathNode)

      receiver = expression.receiver.location.slice.strip.split("::").last
      return nil unless @struct_fields.key?(receiver)
      return receiver if expression.name.to_s == "new" || expression.name.to_s.start_with?("from_")

      nil
    end

    def visit_local_variable_operator_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      op = clear_binary_operator(node.operator.to_s.delete_suffix("="))
      op = "$+" if op == "+" && @local_shapes[name] == "string"
      val = expression_argument_code(node.value)
      if @declared_locals.include?(name)
        "#{name} = (#{name} #{op} #{val})"
      else
        @declared_locals << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_instance_variable_operator_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      op = clear_binary_operator(node.operator.to_s.delete_suffix("="))
      val = expression_argument_code(node.value)
      receiver = class_storage_instance_variable?(name) ? class_storage_variable_name(name) : "self.#{name}"
      "#{receiver} = (#{receiver} #{op} #{val})"
    end

    def visit_call_operator_write_node(node)
      op = clear_binary_operator(node.operator.to_s)
      receiver = visit(node.receiver)
      name = node.read_name.to_s
      lhs = "#{receiver}.#{name}()"
      val = expression_argument_code(node.value)
      "#{receiver}.#{node.write_name}((#{lhs} #{op} #{val}))"
    end

    def visit_call_or_write_node(node)
      receiver = visit(node.receiver)
      receiver_type = clear_type_for_receiver_node(node.receiver)
      prefix = nil
      unless simple_method_receiver_code?(receiver)
        temp = next_generated_local("or_receiver")
        type_text = receiver_type.to_s
        typed = ["", "Any", "Auto"].include?(type_text) ? "" : ": #{type_text}"
        prefix = "MUTABLE #{temp}#{typed} = #{receiver};"
        receiver = temp
      end

      field = node.read_name.to_s
      field_type = class_instance_field_type(receiver_type, field)
      read = if receiver_type && (struct_field_reader?(receiver_type, field) || field_type)
        "#{receiver}.#{field}"
      else
        "#{receiver}.#{field}()"
      end
      operator = field_type.to_s == "Bool" ? "OR" : "OR_ELSE"
      if node.value.is_a?(Prism::BeginNode) && !node.value.rescue_clause &&
         node.value.statements.is_a?(Prism::StatementsNode) && node.value.statements.body.any?
        statements = node.value.statements.body
        setup = statements[0...-1].map { |statement| format_statement_code(visit(statement)) }
        value = expression_argument_code(statements.last).delete_suffix(";")
        condition = field_type.to_s == "Bool" ? "!(#{read})" : "#{read} == NIL"
        body = [*setup, "#{receiver}.#{field} = #{value};"].join("\n")
        body = body.lines.map { |line| "#{indent}  #{line}" }.join
        guarded = "IF #{condition} THEN\n#{body}#{indent}END"
        return prefix ? "#{prefix}\n#{guarded}" : guarded
      end

      assignment = "#{receiver}.#{field} = (#{read} #{operator} #{expression_argument_code(node.value)})"
      prefix ? "#{prefix}\n#{assignment}" : assignment
    end

    def visit_index_operator_write_node(node)
      args = node.arguments ? node.arguments.arguments : []
      return unsupported_expression(node, "Indexed compound write requires one index") unless args.length == 1

      receiver = visit(node.receiver)
      index = visit(args.first)
      lhs = "#{receiver}[#{index}]"
      op = clear_binary_operator(node.operator.to_s)
      val = expression_argument_code(node.value)
      spec = hash_default_spec_for_receiver(node.receiver)
      read = spec ? "(#{lhs} OR_ELSE #{hash_default_code(spec, receiver, index)})" : lhs
      "#{lhs} = (#{read} #{op} #{val})"
    end

    def visit_source_file_node(_node)
      clear_string_literal(@source_path.to_s)
    end

    def visit_instance_variable_or_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      field_type = @class_instance_field_types[@current_class][name] if @current_class
      if class_storage_instance_variable?(name)
        field_type = @class_storage_types["#{@current_class}##{name}"]
      end
      operator = field_type && field_type.to_s != "Bool" ? "OR_ELSE" : "OR"
      receiver = class_storage_instance_variable?(name) ? class_storage_variable_name(name) : "self.#{name}"
      if node.value.is_a?(Prism::BeginNode) && !node.value.rescue_clause &&
         node.value.statements.is_a?(Prism::StatementsNode) && node.value.statements.body.any?
        statements = node.value.statements.body
        setup = statements[0...-1].map { |statement| format_statement_code(visit(statement)) }
        value = expression_argument_code(statements.last).delete_suffix(";")
        condition = field_type.to_s == "Bool" ? "!(#{receiver})" : "#{receiver} == NIL"
        body = [*setup, "#{receiver} = #{value};"].join("\n")
        body = body.lines.map { |line| "#{indent}  #{line}" }.join
        return "IF #{condition} THEN\n#{body}#{indent}END"
      end

      val = expression_argument_code(node.value)
      "#{receiver} = (#{receiver} #{operator} #{val})"
    end

    def visit_index_or_write_node(node)
      lhs = index_or_write_lhs_code(node)
      return lhs if unsupported_output?(lhs)

      val = expression_argument_code(node.value)
      # A struct-field or-assign whose receiver is an INDEXED read
      # (`params[idx].symbol ||= v`) is not an lvalue chain in CLEAR:
      # indexing yields an optional element. An `EXISTS AS` capture cannot
      # carry the write either - that binding is a BORROW of the container,
      # so assigning through it (or to the container while it is live) is
      # rejected with ASSIGN_WHILE_BORROWED. Read the element into an owned
      # copy with no binding held, mutate the copy, then store it back.
      if (field_match = lhs.match(/\A(?<element>.+\])\??\.(?<field>[A-Za-z_]\w*[?!]?)\z/)) &&
         node.receiver && struct_field_index_name(node.receiver, node.arguments&.arguments&.first)
        slot = next_generated_local("field_slot")
        element = field_match[:element]
        field = field_match[:field]
        return "IF #{element} != NIL THEN\n" \
          "#{indent}  MUTABLE #{slot} = COPY UNWRAP (#{element});\n" \
          "#{indent}  #{slot}.#{field} = (#{slot}.#{field} OR_ELSE #{val});\n" \
          "#{indent}  #{element} = #{slot};\n" \
          "#{indent}END"
      end
      "#{lhs} = (#{lhs} OR_ELSE #{val})"
    end

    def index_or_write_lhs_code(node)
      args = node.arguments ? node.arguments.arguments : []
      return unsupported_expression(node, "Indexed ||= requires exactly one index") unless args.length == 1

      receiver = visit(node.receiver)
      if (field_name = struct_field_index_name(node.receiver, args.first))
        "#{method_receiver_code(receiver)}.#{field_name}"
      else
        "#{receiver}[#{visit(args.first)}]"
      end
    end

    def visit_instance_variable_and_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      val = expression_argument_code(node.value)
      receiver = class_storage_instance_variable?(name) ? class_storage_variable_name(name) : "self.#{name}"
      "#{receiver} = (#{receiver} AND #{val})"
    end

    def visit_local_variable_or_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      val = expression_argument_code(node.value)
      if @declared_locals.include?(name)
        local_type = @local_types[name].to_s
        operator = local_type.start_with?("?") && local_type != "?Bool" ? "OR_ELSE" : "OR"
        "#{name} = (#{name} #{operator} #{val})"
      else
        @declared_locals << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_local_variable_and_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      val = expression_argument_code(node.value)
      if @declared_locals.include?(name)
        "#{name} = (#{name} AND #{val})"
      else
        @declared_locals << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_instance_variable_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      value_node = node.value
      type_annotation = nil
      if (typed_value = sorbet_typed_value(value_node))
        value_node, type_annotation = typed_value
        if value_node.is_a?(Prism::InstanceVariableReadNode) && value_node.name == node.name
          return ""
        end
      end
      if value_node.is_a?(Prism::IfNode) && runtime_is_a_predicate(value_node.predicate)
        assignment_type = @class_instance_field_types[@current_class][name] || type_annotation
        return if_assignment_code("self.#{name}", value_node, assignment_type)
      end

      field_type = @class_instance_field_types[@current_class][name] if @current_class
      val = if field_type && !["Auto", "Any"].include?(field_type.to_s)
        with_expected_expression_type(field_type) { field_assignment_value(node.value) }
      else
        field_assignment_value(node.value)
      end
      storage_name = class_storage_variable_name(name)
      if @singleton_class_depth.positive?
        return "#{storage_name} = #{val}" if @declared_locals.include?(name) || @class_variables.include?(name)

        @class_variables << name
        return "MUTABLE #{storage_name} = #{val}"
      end
      if @inside_class_method && @class_variables.include?(name)
        return "#{storage_name} = #{val}"
      end
      if @current_class && !@inside_function
        @class_variables << name
        @emitted_class_storage_variables << "#{@current_class}##{name}"
        storage_type = type_annotation || inferred_clear_type(value_node)
        @class_storage_types["#{@current_class}##{name}"] = storage_type
        type_suffix = storage_type && !["Auto", "Any"].include?(storage_type.to_s) ? ": #{storage_type}" : ""
        return "MUTABLE #{storage_name}#{type_suffix} = #{val}"
      end

      "self.#{name} = #{val}"
    end

    def class_storage_instance_variable?(name)
      @singleton_class_depth.positive? || (@inside_class_method && @class_variables.include?(name))
    end

    def field_assignment_value(value_node)
      val = expression_argument_code(value_node)
      return val unless stored_borrowed_value?(value_node)

      "COPY #{val}"
    end

    def stored_borrowed_value?(node)
      return true if node.is_a?(Prism::SelfNode)

      if node.is_a?(Prism::InstanceVariableReadNode)
        name = node.name.to_s.delete_prefix("@")
        return true if class_storage_instance_variable?(name)
      end
      return true if copyable_local_read_source?(node)

      value_node = sorbet_unwrapped_value(node) || node
      if value_node != node
        semantic_value = @typed_ir.value_for(value_node)
        if semantic_value&.access == :borrowed && copyable_storage_type?(semantic_value.type.to_clear)
          return true
        end
      end
      if value_node.is_a?(Prism::CallNode) && value_node.name.to_s == "[]" && value_node.receiver
        return true
      end

      value_node.is_a?(Prism::LocalVariableReadNode) && @current_param_names.include?(value_node.name.to_s)
    end

    # Last net for the "Cannot return borrowed value without COPY" class: the
    # emitted code is a bare field read (optionally behind the CAST a T.cast
    # produced) and the function hands it out with a type CLEAR will not copy
    # implicitly. Type resolution can miss the receiver -- an alias of an alias,
    # a narrowing the emitter did not record -- but the SHAPE is unambiguous.
    def borrowed_field_read_code?(code)
      declared = @current_function_return_type.to_s
      return false if declared.empty?
      # An unresolved return type says nothing about ownership; forcing a deep
      # copy there would change programs the compiler never complained about.
      return false if %w[Auto Any Void].include?(declared)
      return false if implicitly_copyable_clear_type?(declared)

      text = code.to_s.strip
      text = text.sub(/\ACAST\((.*) AS [^)]*\)\z/, '\\1').strip
      text.match?(/\A[a-z_][A-Za-z0-9_]*(?:\.[a-z_][A-Za-z0-9_]*)+\z/)
    end

    def materialize_borrowed_code(code, node)
      return code unless stored_borrowed_value?(node) || returning_borrowed_owned_read?(node) ||
        narrowed_binding_read?(code) || borrowed_field_read_code?(code)
      semantic_type = @typed_ir.value_for(node)&.type&.to_clear
      value_type = semantic_type || inferred_clear_type(node)
      return code if value_type.to_s.delete_prefix("?").end_with?("@symbol")
      return code if code.start_with?("COPY ") || code.start_with?("CAST(COPY ")
      # A @multiowned/@shared destination needs the full ownership_upgrade_
      # return_code wrap (a fresh local declared with the destination's own
      # type, matching the compiler's exact ownership-match requirement on
      # RETURN - see that method's comment), not a bare COPY here: COPY of
      # a non-Rc source does not upgrade ownership, so `RETURN COPY code;`
      # is rejected exactly like the bare `RETURN code;` this guards
      # against is. render_returning_statement and visit_return_node both
      # check ownership_upgrade_return_code before reaching this method, so
      # by the time a @multiowned/@shared destination gets here the wrap
      # was already inapplicable - COPY would be wrong for those too.
      #
      # Unless the SOURCE already carries the same marker: then it is an Rc
      # and COPY is the retain a borrowed read needs to leave the function.
      # That is the one case ownership_upgrade_return_code deliberately
      # declines ("source already correctly owned"), and declining the COPY
      # too left a bare borrow the frontend rejects.
      if @current_function_return_type.to_s.match?(/@(?:multiowned|shared)(?:$|:)/) &&
         !value_type.to_s.match?(/@(?:multiowned|shared)(?:$|:)/)
        return code
      end

      if direct_retained_carrier_type?(value_type)
        code.start_with?("KEEP ") ? code : "KEEP #{code}"
      else
        "COPY #{code}"
      end
    end

    # RETURN requires the returned value's OWNERSHIP to match the function's
    # declared return type EXACTLY (annotator/domains/errors.rb's
    # same_return_capabilities?, checked before MIR lowering ever runs) -
    # unlike a @multiowned struct-literal FIELD, there is no call-edge keep-
    # analysis step for a bare RETURN that would upgrade a plain value's
    # ownership after the fact. A value whose own type does not already
    # carry the destination's @multiowned/@shared marker must be copied
    # into a fresh local DECLARED with that marker first; MIR lowering then
    # transfers that local's fresh strong ref out. Returns the complete
    # two-statement code (not just an expression) or nil if no upgrade is
    # needed (source already correctly owned, or destination isn't
    # multiowned/shared - the ordinary bare/COPY paths apply instead).
    # `sig { returns(T.untyped) }` over a body that only reads a field is the
    # shape a record uses when naming the field's real type would close a load
    # cycle -- ast/struct_field.rb says exactly that, and carries a
    # `ruby-to-clear: field-type` directive for the field instead. The
    # directive is the authoritative type, so the reader hands back the field's
    # type rather than an Any the getter then has to launder into the
    # destination's ownership (which CLEAR rejects as a borrowed return).
    def field_reader_return_type(node, name)
      declared_sig = parse_sig(@current_sig)[1].to_s
      return nil unless %w[Auto Any].include?(declared_sig.delete_prefix("?").sub(/@.*\z/, ""))

      owner = @current_class || @current_struct_name
      return nil unless owner

      body = node.body&.body
      return nil unless body && body.length == 1
      return nil unless bare_field_read_of?(body.first, name)

      declared = @class_instance_field_types[owner][name] ||
        @class_instance_field_types[resolve_qualified_class_name(owner)][name]
      return nil if declared.to_s.empty? || %w[Auto Any].include?(declared.to_s)

      declared
    end

    # `self[:name]`, `@name`, or `self.name` -- the three ways a record reader
    # spells "give me my own field".
    def bare_field_read_of?(stmt, name)
      case stmt
      when Prism::InstanceVariableReadNode
        stmt.name.to_s.delete_prefix("@") == name
      when Prism::CallNode
        return false unless stmt.receiver.is_a?(Prism::SelfNode)
        return stmt.name.to_s == name if stmt.arguments.nil?

        args = stmt.arguments.arguments
        stmt.name.to_s == "[]" && args.length == 1 &&
          args.first.is_a?(Prism::SymbolNode) && args.first.value.to_s == name
      else
        false
      end
    end

    def ownership_upgrade_return_code(code, node)
      return nil unless @current_function_return_type.to_s.match?(/@(?:multiowned|shared)(?:$|:)/)
      # A freshly-owned value (e.g. `item = Item.new; item`, access :owned
      # in the typed-IR facts) already satisfies the destination without
      # any wrap - only a BORROWED source (a parameter, or a binding
      # narrowed from one) needs to be copied into a freshly-owned local
      # first. self is the one exception: inside its own constructor it
      # reads as neither stored_borrowed_value? nor returning_borrowed_
      # owned_read?, but is still the bare, not-yet-owned struct value.
      return nil unless node.is_a?(Prism::SelfNode) ||
        stored_borrowed_value?(node) || returning_borrowed_owned_read?(node)

      semantic_type = @typed_ir.value_for(node)&.type&.to_clear
      value_type = (semantic_type || inferred_clear_type(node)).to_s
      return nil if value_type.match?(/@(?:multiowned|shared)(?:$|:)/)
      return nil if value_type.delete_prefix("?").end_with?("@symbol")

      owned_return = next_generated_local("owned_return")
      # The ownership-qualified destination is the retaining edge. A plain
      # borrowed Ruby object is wrapped/retained by CLEAR's keep analysis;
      # spelling COPY here asks lowering to structurally clone the Rc/Arc
      # destination type and changes Ruby object identity.
      "MUTABLE #{owned_return}: #{@current_function_return_type} = #{code};\n" \
        "RETURN #{owned_return};"
    end

    # A borrowed read of a `T::Struct` const field (`receiver.field`) must be
    # deep-copied to leave the function; the frontend rejects returning it as a
    # bare borrow. `copyable_local_read_source?` only inspects instance-variable
    # fields, so const-declared struct fields (which live in `@struct_fields`)
    # slip through — this covers them for return position.
    # A name bound by an optional guard (`x EXISTS AS x_value`) is a BORROW of
    # the payload, so handing it out of the function needs the same COPY a
    # borrowed field read needs. This was the single largest hand-fix class in
    # the parser migration ("Copy the value narrowed out of a local optional
    # before returning it").
    def narrowed_binding_read?(code)
      @active_narrowed_binding_names.include?(code)
    end

    def returning_borrowed_owned_read?(node)
      value_node = sorbet_unwrapped_value(node) || node
      return false unless value_node.is_a?(Prism::CallNode) && value_node.receiver
      return false if value_node.arguments && !value_node.arguments.arguments.empty?

      rec_type = clear_type_for_receiver_node(value_node.receiver)
      return false unless rec_type

      unless struct_field_reader?(rec_type, value_node.name.to_s)
        # A reader called on a UNION-typed receiver reads a field of whichever
        # variant the narrowing picked. The union itself declares no fields, so
        # the struct lookup misses and the read leaves the function borrowed:
        # "Cannot return borrowed value without COPY". Resolve it through the
        # variants instead.
        field_type = union_variant_field_type(rec_type, value_node.name.to_s)
        return false if field_type.to_s.empty?
        # Only the reads CLEAR actually rejects: a type it copies implicitly
        # leaves the function fine as a bare read, and wrapping it would add a
        # deep copy the Ruby never had.
        return false if implicitly_copyable_clear_type?(field_type)

        return copyable_storage_type?(field_type)
      end

      field_type = class_instance_field_type(rec_type, value_node.name.to_s)
      field_type = inferred_clear_type(value_node) if field_type.to_s.empty?
      copyable_storage_type?(field_type)
    end

    # The declared type of `field` on any variant of `union_type` that has it.
    def union_variant_field_type(union_type, field)
      base = expand_clear_type_alias(union_type.to_s).to_s.delete_prefix("?").split("@").first.to_s
      variants = @union_types[base]
      return "" unless variants

      variants.each do |variant|
        next unless struct_field_reader?(variant, field)

        found = class_instance_field_type(variant, field)
        return found unless found.to_s.empty?
      end
      ""
    end

    def copyable_local_read_source?(node, explicit_type_annotation = nil)
      semantic_value = @typed_ir.value_for(node)
      if semantic_value&.access == :borrowed
        semantic_type = semantic_value.type.to_clear
        # CFG access can be complete even when the type fact for a projection
        # is not. Keep the precise borrowed access and fill only the missing
        # type from the emitter's established inference path.
        semantic_type = inferred_clear_type(node) if semantic_value.type.unresolved?
        return true if copyable_storage_type?(semantic_type)
      end
      return false if semantic_value&.access == :owned

      value_node = node
      type_annotation = explicit_type_annotation
      if (typed_value = sorbet_typed_value(value_node))
        value_node, type_annotation = typed_value unless type_annotation
      elsif (unwrapped = sorbet_unwrapped_value(value_node))
        value_node = unwrapped
      end

      if (field_name = copyable_self_field_read_name(value_node))
        return true if class_storage_instance_variable?(field_name)

        field_type = if @current_class && @current_instance_field_names.include?(field_name)
          @class_instance_field_types[@current_class][field_name]
        end
        type = type_annotation || field_type
        return copyable_storage_type?(type)
      end

      if value_node.is_a?(Prism::CallNode)
        rec_type = clear_type_for_receiver_node(value_node.receiver)
        field = value_node.name.to_s
        if rec_type && class_instance_field_type(rec_type, field)
          type = type_annotation || inferred_clear_type(value_node)
          return copyable_storage_type?(type)
        end
      end

      return false unless value_node.is_a?(Prism::LocalVariableReadNode)

      local_name = value_node.name.to_s
      type = type_annotation || @local_types[local_name] || (@param_types && @param_types[local_name])
      copyable_storage_type?(type)
    end

    def copyable_self_field_read_name(node)
      if node.is_a?(Prism::InstanceVariableReadNode)
        return node.name.to_s.delete_prefix("@")
      end
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.name.to_s == "[]"

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length == 1
      return nil unless node.receiver.is_a?(Prism::SelfNode)

      keyword_call_key(args.first)
    end

    def copyable_storage_type?(type)
      return false if type.nil? || type == "Auto" || type == "Any" || type == "Void"

      normalized = expand_clear_type_alias(type.to_s).to_s.delete_prefix("?")
      return true if function_like_clear_type?(normalized)
      return false if normalized.include?("@raw")
      return true if normalized == "String@symbol"
      base = normalized.split("@").first.to_s
      return false if base.empty?
      # Collections need COPY regardless of where the element capability
      # sits: `String@symbol[]` puts the array marker AFTER the capability
      # and `String@symbol[]@set` tails it with the shape, so the
      # base-only check used to miss them and symbol-array/set field
      # returns escaped as bare borrows.
      return true if base.end_with?("[]") || normalized.include?("[]") ||
                     normalized.start_with?("HashMap<", "[]", "[Set]", "{")
      return true if string_like_clear_type?(normalized)
      return false if primitive_clear_storage_type?(base)

      custom_clear_storage_type?(base)
    end

    # A direct Rc/Arc carrier is distinct from an aggregate containing retained
    # elements. `[]Item@multiowned` is a plain list whose Item elements are
    # retained; only `Item@multiowned` itself can be duplicated with KEEP.
    # Types CLEAR copies implicitly, so a bare read can leave a function.
    # An OPTIONAL is never one of them, whatever it wraps.
    def implicitly_copyable_clear_type?(type)
      normalized = expand_clear_type_alias(type.to_s).to_s
      return true if normalized.delete_prefix("?") == "String@symbol"

      # An optional primitive is still a primitive: CLEAR only rejects the
      # borrowed return when the payload itself needs an owner.
      normalized.delete_prefix("?").sub(/@.*\z/, "")
                .match?(/\A(?:Bool|U?Int\d*|Float\d*|Byte\d*|Void|Nil|String)\z/)
    end

    def direct_retained_carrier_type?(type)
      normalized = expand_clear_type_alias(type.to_s).to_s.delete_prefix("?")
      return false if normalized.empty?
      return false if normalized.start_with?("[]", "[Set]", "{", "HashMap<", "Tuple<")
      return false if normalized.include?("[]")

      normalized.match?(/@(?:multiowned|shared)(?:$|:)/)
    end

    def retainable_ruby_identity_type?(type)
      normalized = expand_clear_type_alias(type.to_s).to_s.delete_prefix("?")
      return false if normalized.empty? || normalized == "Auto" || normalized == "Any"
      return true if direct_retained_carrier_type?(normalized)
      return false if normalized.start_with?("[]", "[Set]", "{", "HashMap<", "Tuple<")
      return false if normalized.include?("[]") || normalized.end_with?("@symbol")

      aliasable_identity_type?(normalized)
    end

    def aliasable_identity_type?(type)
      normalized = expand_clear_type_alias(type.to_s).to_s.delete_prefix("?")
      base = normalized.split("@").first.to_s
      return false unless custom_clear_storage_type?(base)

      candidates = [base, base.split("::").last]
      candidates.any? { |candidate| @aliasable_classes.include?(candidate) }
    end

    def retained_identity_type(type)
      text = type.to_s
      return text if text.empty? || direct_retained_carrier_type?(text)

      optional = text.start_with?("?")
      base = text.delete_prefix("?")
      "#{optional ? '?' : ''}#{base}@multiowned"
    end

    def explicit_dup_code(code, node)
      retained_identity_source?(node) ? "OWN COPY #{code}" : "COPY #{code}"
    end

    def retained_identity_source?(node)
      semantic = @typed_ir.value_for(node)
      type = if node.is_a?(Prism::LocalVariableReadNode)
        static_clear_type_for_receiver(node.name.to_s)
      end
      type ||= semantic&.type&.to_clear || inferred_clear_type(node)
      direct_retained_carrier_type?(type) ||
        (semantic&.access == :owned && aliasable_identity_type?(type))
    end

    def primitive_clear_storage_type?(type)
      type.match?(/\A(?:Bool|Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Float|Float32|Float64|String|Void|Nil)\z/)
    end

    def custom_clear_storage_type?(type)
      type.match?(/\A[A-Z][A-Za-z0-9_]*(?:<.*>)?\z/)
    end

    def explicit_sorbet_untyped_value?(node)
      return false unless sorbet_call?(node)
      return false unless ["let", "cast"].include?(node.name.to_s)

      args = node.arguments ? node.arguments.arguments : []
      args[1]&.location&.slice&.strip == "T.untyped"
    end

    def visit_constant_write_node(node)
      name = node.name.to_s
      @regex_constants << name if regex_value_node?(node.value)

      if node.value.is_a?(Prism::CallNode) && node.value.receiver.nil? &&
         %w[type_member type_template].include?(node.value.name.to_s)
        return ""
      end

      if name == "UNSET" && @current_class && sentinel_literal_for("#{@current_class}::UNSET")
        return ""
      end

      alias_context = @current_class
      alias_key = type_alias_key(name, alias_context)
      alias_name = type_alias_clear_name(name, alias_context)
      if (type_alias = sorbet_type_alias_value(node.value, alias_name: alias_name))
        if declaration_comment?(node, "ruby-to-clear: aliasable") || declaration_comment?(node, "@aliasable")
          type_alias = apply_multiowned_sigil(type_alias)
        end
        @type_aliases[alias_key] = type_alias
        union_defs = union_definitions_for_alias(alias_name, type_alias, visibility: declaration_visibility_prefix(node))
        return union_defs.join("\n") unless union_defs.empty?

        return ""
      end

      if (values = static_string_set_literal(node.value))
        clear_name = constant_variable_name(name)
        @constant_names[name] = clear_name
        @constant_types[name] = "String[]@set"
        @constant_types[clear_name] = "String[]@set"
        if static_string_set_fold_only_uses?(name)
          @static_string_sets[clear_name] = values
          return ""
        end

        items = values.map { |value| clear_string_literal(value) }.join(", ")
        return "MUTABLE #{clear_name}: String[]@set = [#{items}];"
      end

      if node.value.is_a?(Prism::CallNode) &&
         (node.value.receiver.nil? || (node.value.receiver.is_a?(Prism::ConstantReadNode) && node.value.receiver.name == :Struct)) &&
         node.value.name == :new

        fields = []
        if node.value.arguments
          node.value.arguments.arguments.each do |arg|
            fields << arg.value.to_s if arg.is_a?(Prism::SymbolNode)
          end
        end
        qualified_name = if @current_class && !name.include?("::")
          "#{@current_class}::#{name}"
        else
          name
        end
        emitted_name = @helper_config.clear_type(qualified_name) ||
          @helper_config.clear_type(name) || clear_type_name_for_emit(qualified_name)
        @constant_names[qualified_name] = emitted_name
        @constant_names[name] = emitted_name unless @constant_names.key?(name)
        metadata_name = @struct_fields.key?(qualified_name) ? qualified_name : name
        @class_instance_field_names[metadata_name].merge(fields)
        fields.each { |field| merge_class_instance_field_type(metadata_name, field, "Any") }
        all_fields = fields + (@class_instance_field_names[metadata_name].to_a - fields).sort
        @struct_fields[metadata_name] = all_fields
        @emitted_class_structs << emitted_name

        field_decls = all_fields.map do |field|
          type = @class_instance_field_types[metadata_name][field] || "Any"
          emitted_type = struct_field_type(concrete_struct_type(type), emitted_name)
          require_type_dependency(emitted_type)
          "  #{field}: #{emitted_type}"
        end.join(",\n")
        struct_code = "#{declaration_visibility_prefix(node)}STRUCT #{emitted_name} {\n#{field_decls}\n}"
        mapped_getters = if emitted_name != name
          all_fields.map do |field|
            type = concrete_struct_type(@class_instance_field_types[metadata_name][field] || "Any")
            value = if direct_retained_carrier_type?(type)
              "KEEP self.#{field}"
            elsif implicitly_copyable_clear_type?(type)
              "self.#{field}"
            else
              # A getter hands the field OUT of the struct, so a non-Copy field
              # has to leave as an owned value: CLEAR rejects
              # "Cannot return borrowed value without COPY or a lifetime
              # annotation" otherwise. The explicit-RETURN path already does
              # this; the synthesized getter used to skip it.
              "COPY self.#{field}"
            end
            getter = "#{class_function_prefix(emitted_name)}__#{emitted_field_identity(field)}"
            "PUB FN #{getter}(self: #{emitted_name}) RETURNS #{type} ->\n  #{value};\nEND"
          end.join("\n")
        else
          ""
        end
        block_code = visit_struct_new_assignment_block(metadata_name, fields, node.value.block)
        return [struct_code, mapped_getters, block_code].reject(&:empty?).join("\n\n")
      end

      clear_name = constant_variable_name(name)
      if node.value.is_a?(Prism::ConstantPathNode)
        source_target = node.value.location.slice.strip.delete_prefix("::")
        module_target = [source_target, source_target.split("::").last].find do |candidate|
          @module_function_names.key?(candidate) || @module_namespace_names.include?(candidate)
        end
        if module_target
          @module_aliases[name] = module_target
          return ""
        end

        aliased_name = visit_constant_path_node(node.value)
        same_name_alias = node.value.location.slice.strip.split("::").last == name
        nominal_alias = @type_aliases.key?(alias_key) && begin
          target = @type_aliases[alias_key].to_s
          @struct_fields.key?(target) || @struct_fields.key?(target.split("::").last) ||
            @class_instance_field_types.key?(target) || @class_instance_field_types.key?(target.split("::").last)
        end
        if aliased_name == clear_name || same_name_alias || nominal_alias
          @constant_names[name] = clear_name
          return ""
        end
      end
      @constant_names[name] = clear_name
      value_node = node.value
      type_annotation = nil
      if (typed_value = sorbet_typed_value(value_node))
        value_node, type_annotation = typed_value
      end

      if (pattern_code = static_regex_pattern_code(value_node))
        @regex_constant_pattern_codes[name] = pattern_code
      end

      scalar_constant = scalar_constant_expression_node?(value_node)
      if scalar_constant
        @constant_literal_values[name] = visit(value_node)
      end

      inferred_type = type_annotation || inferred_clear_type(value_node)
      if inferred_type && inferred_type != "Auto"
        @constant_types[name] = inferred_type
        @constant_types[clear_name] = inferred_type
      end

      if pattern_code
        # CompilerRegex is a transparent static pattern view. Like scalar Ruby
        # constants, inline its construction at use sites instead of emitting
        # unsupported module-level storage.
        @constant_literal_values[name] = visit(value_node)
        return ""
      end

      # CLEAR does not have module-level mutable storage. A Ruby scalar
      # constant is immutable and its value is already recorded above, so
      # substitute it at use sites instead of emitting an invalid global.
      return "" if scalar_constant

      declaration_type = type_annotation || inferred_type
      frozen_array = frozen_array_literal(value_node)
      if frozen_array
        surface_type = clear_type_expr(declaration_type.to_s)
        declaration_type = if surface_type.start_with?("[]")
          surface_type.sub(/\A\[\]/, "[#{frozen_array.elements.length}]")
        elsif surface_type.end_with?("[]")
          "[#{frozen_array.elements.length}]#{surface_type.delete_suffix('[]')}"
        else
          declaration_type
        end
        @constant_types[name] = declaration_type
        @constant_types[clear_name] = declaration_type
      end
      if frozen_array && frozen_array.elements.any? { |element|
        element.is_a?(Prism::HashNode) || element.is_a?(Prism::KeywordHashNode)
      }
        # CLEAR has no module initialization/cleanup lifetime. A frozen Ruby
        # array containing Hash entries cannot safely become a container-scope
        # binding: lowering the owned maps creates function-scoped cleanup
        # temporaries referenced by the global.
        # Reconstruct it at each use site, where the ordinary local ownership
        # plan can transfer every child into the aggregate.
        @constant_inline_nodes[name] = value_node
        return ""
      end
      type_suffix = declaration_type && !["Auto", "Any", "Void"].include?(declaration_type.to_s) ?
        ": #{declaration_type}" : ""
      frozen_value = value_node.is_a?(Prism::CallNode) && value_node.name.to_s == "freeze"
      if frozen_value && !frozen_array && !declaration_comment?(node, "ruby-to-clear: data-api")
        # A frozen non-array constant is an immutable value. If it is a
        # comptime-pure value (a plain value-struct or scalar type) named in
        # SCREAMING_CASE, emit a real module CONST and reference it by name -
        # sharing it directly instead of reconstructing an `@multiowned` copy at
        # every use site (which forced a fallible ownership CAST when passed to a
        # plain value parameter). Otherwise keep inlining the construction: a
        # heap-owning constant has no module lifetime in CLEAR yet (Tier 2).
        const_type = declaration_type.to_s.sub(/@(?:multiowned|shared)\z/, "")
        if module_const_emittable?(clear_name, const_type)
          @constant_types[name] = const_type
          @constant_types[clear_name] = const_type
          return "PUB CONST #{clear_name}: #{const_type} = #{visit(value_node)};"
        end
        # An inlined frozen constant is reconstructed (owned) at each use site,
        # never shared, so type it plain. The `@multiowned` sigil that
        # aliasable classes carry is a sharing fiction here; left on, it forces a
        # fallible ownership-materialization CAST when the constant feeds a plain
        # value parameter (e.g. a `= X::AFFINE` default), poisoning the callee.
        if const_type != declaration_type.to_s
          @constant_types[name] = const_type
          @constant_types[clear_name] = const_type
        end
        @constant_inline_nodes[name] = value_node
        return ""
      end
      mutable_prefix = frozen_array || frozen_value ? "" : "MUTABLE "
      declaration = "#{mutable_prefix}#{clear_name}#{type_suffix} = #{visit(value_node)}"
      data_api = declaration_comment?(node, "ruby-to-clear: data-api") && inferred_type && inferred_type != "Auto"
      return declaration unless data_api

      accessor_type = inferred_type.to_s.sub(/\A(.+)(@[A-Za-z_][A-Za-z0-9_]*)\[\]\z/, '\\1[]\\2')
      unless comptime_pure_clear_type?(declaration_type)
        factory_accessor_type = clear_type_expr(declaration_type.to_s)
        return <<~CLEAR.chomp
          PUB FN ruby_constant_#{clear_name}() RETURNS #{factory_accessor_type} ->
            RETURN CAST(#{visit(value_node)} AS #{factory_accessor_type});
          END
        CLEAR
      end
      "#{declaration};\nPUB FN ruby_constant_#{clear_name}() RETURNS #{accessor_type} ->\n  #{clear_name};\nEND"
    end

    # A frozen constant may become a real module CONST only when its name is
    # SCREAMING_CASE (the CONST surface) and its type is comptime-pure - a value
    # a container-scope Zig `const` can hold with no runtime allocation. A
    # heap-owning constant stays inlined until CLEAR grows a module lifetime.
    def module_const_emittable?(clear_name, const_type)
      clear_name.to_s.match?(/\A[A-Z][A-Z0-9_]*\z/) && comptime_pure_clear_type?(const_type)
    end

    SCALAR_COMPTIME_TYPES = %w[
      Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64 Float32 Float64
      Bool Boolean Byte Void String@symbol
    ].freeze

    def comptime_pure_clear_type?(type, seen = [])
      base = type.to_s.delete_prefix("?")
      return false if base.empty?
      return true if SCALAR_COMPTIME_TYPES.include?(base)
      # Anything pointer/collection/heap-string/owned-wrapper backed is not a
      # comptime value.
      return false if base.include?("[") || base.include?("@")
      return false if base == "String"
      return false if seen.include?(base)
      return false unless @class_instance_field_types.key?(base)

      field_types = @class_instance_field_types[base]
      return false if field_types.empty?

      field_types.values.all? { |ft| comptime_pure_clear_type?(ft.to_s, seen + [base]) }
    end

    def frozen_array_literal(node)
      return nil unless node.is_a?(Prism::CallNode) && node.name.to_s == "freeze"
      return node.receiver if node.receiver.is_a?(Prism::ArrayNode)

      nil
    end

    def scalar_constant_expression_node?(node)
      return true if node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode) ||
        node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode) ||
        node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode) ||
        node.is_a?(Prism::NilNode)

      if node.is_a?(Prism::ParenthesesNode)
        statements = node.body
        return statements.is_a?(Prism::StatementsNode) && statements.body.length == 1 &&
          scalar_constant_expression_node?(statements.body.first)
      end

      return false unless node.is_a?(Prism::CallNode) && node.receiver
      return false unless %i[+ - * / ** << >> & | ^].include?(node.name)

      args = node.arguments&.arguments || []
      scalar_constant_expression_node?(node.receiver) && args.all? { |arg| scalar_constant_expression_node?(arg) }
    end

    def static_string_set_literal(node)
      typed_value = sorbet_typed_value(node)
      value_node = typed_value&.first || node
      array_node = if value_node.is_a?(Prism::CallNode) && value_node.name.to_s == "to_set"
        value_node.receiver if value_node.receiver.is_a?(Prism::ArrayNode)
      elsif value_node.is_a?(Prism::ArrayNode) && typed_value&.last.to_s.end_with?("@set")
        value_node
      end
      return nil unless array_node

      elements = array_node.elements
      return nil unless elements.all?(Prism::StringNode)

      elements.map(&:content).uniq.freeze
    end

    # The equality-chain fold erases the constant binding, so it is only
    # legal when every reference is an include? membership test against a
    # dynamic argument. Any other use (bare reads, iteration, membership on
    # a literal the fold would degenerate to literal == literal) needs the
    # named binding materialized.
    def static_string_set_fold_only_uses?(constant_name)
      root = @transpile_root
      return true unless root

      fold_only = true
      walk = lambda do |n|
        return unless n.is_a?(Prism::Node) && fold_only

        if n.is_a?(Prism::CallNode) && n.name.to_s == "include?" &&
           n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name.to_s == constant_name
          args = n.arguments ? n.arguments.arguments : []
          fold_only = false unless args.length == 1 && !args.first.is_a?(Prism::StringNode)
          args.each { |arg| walk.call(arg) }
          return
        end

        if n.is_a?(Prism::ConstantReadNode) && n.name.to_s == constant_name
          fold_only = false
          return
        end

        n.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(root)
      fold_only
    end

    def static_string_set_include_code(receiver_code, argument_node)
      values = @static_string_sets[receiver_code.to_s]
      return nil unless values

      argument = visit(argument_node)
      return "FALSE" if values.empty?

      values.map { |value| "(#{argument} == #{clear_string_literal(value)})" }.join(" OR ")
    end
    public :static_string_set_include_code

    def visit_range_node(node)
      left = node.left ? visit(node.left) : ""
      right = node.right ? visit(node.right) : ""
      op = node.exclude_end? ? "..<" : "..="
      "#{left} #{op} #{right}"
    end

    def visit_struct_new_assignment_block(class_name, fields, block_node)
      old_class = @current_class
      old_instance_field_names = @current_instance_field_names
      old_instance_method_names = @current_instance_method_names
      old_mutating_instance_method_names = @current_mutating_instance_method_names
      body_nodes = block_node&.body&.body || []
      return "" if body_nodes.empty?

      @current_class = class_name
      @class_instance_field_names[class_name].merge(fields)
      fields.each { |field| merge_class_instance_field_type(class_name, field, "Any") }
      @class_instance_method_names[class_name].merge(collect_instance_method_names_from_body_nodes(body_nodes))
      @class_mutating_instance_method_names[class_name].merge(collect_mutating_instance_method_names_from_body_nodes(body_nodes))
      @current_instance_field_names = @class_instance_field_names[class_name].dup
      @current_instance_method_names = @class_instance_method_names[class_name].dup
      @current_mutating_instance_method_names = @class_mutating_instance_method_names[class_name].dup

      visit_statement_list(body_nodes)
    ensure
      @current_class = old_class
      @current_instance_field_names = old_instance_field_names
      @current_instance_method_names = old_instance_method_names
      @current_mutating_instance_method_names = old_mutating_instance_method_names
    end

    def visit_required_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      type = (@param_types && @param_types[node.name.to_s]) || untyped_type
      name = @renames[node.name.to_s] || node.name.to_s
      "#{prefix}#{name}: #{type}"
    end

    def visit_parameters_node(node)
      requireds = node.requireds.map { |param| visit(param) }
      optionals = node.optionals.map { |param| visit(param) }
      rest = node.rest ? [visit(node.rest)] : []
      keywords = node.keywords.map { |param| visit(param) }
      keyword_rest = node.keyword_rest ? [visit(node.keyword_rest)] : []
      block = node.block ? [visit(node.block)] : []
      (requireds + optionals + rest + keywords + keyword_rest + block).join(", ")
    end

    def visit_optional_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      type = (@param_types && @param_types[node.name.to_s]) || untyped_type
      name = @renames[node.name.to_s] || node.name.to_s
      return "#{prefix}#{name}: #{type}" unless parameter_default_supported?(node.value)

      default_val = parameter_default_code(node.value, type)
      "#{prefix}#{name}: #{type} = #{default_val}"
    end

    def visit_required_keyword_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      type = (@param_types && @param_types[node.name.to_s]) || untyped_type
      name = @renames[node.name.to_s] || node.name.to_s
      "#{prefix}#{name}: #{type}"
    end

    def visit_optional_keyword_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      type = (@param_types && @param_types[node.name.to_s]) || untyped_type
      name = @renames[node.name.to_s] || node.name.to_s
      return "#{prefix}#{name}: #{type}" unless parameter_default_supported?(node.value)

      default_val = parameter_default_code(node.value, type)
      "#{prefix}#{name}: #{type} = #{default_val}"
    end

    def parameter_default_code(value_node, type)
      value = visit(value_node)
      wrapped = wrap_argument_for_parameter_type(value, value_node, type)
      return wrapped unless wrapped == value

      sentinel_type = sentinel_type_for_node(value_node)
      union_type = sentinel_union_type_for_parameter(type, sentinel_type) if sentinel_type
      return value unless union_type

      "#{union_type}{ #{union_variant_name(sentinel_type, union_type)}: #{value} }"
    end

    def sentinel_union_type_for_parameter(type, sentinel_type)
      normalized = type.to_s.delete_prefix("?")
      return nil unless @union_types[normalized]&.include?(sentinel_type)

      normalized
    end

    def optional_sentinel_union_receiver?(receiver, sentinel_type)
      type = inferred_clear_type(receiver)
      return false unless type.to_s.start_with?("?")

      !!sentinel_union_type_for_parameter(type, sentinel_type)
    end

    def optional_unwrap_code(code)
      code.match?(/\A[A-Za-z_]\w*\z/) ? "#{code}?" : "(#{code})?"
    end
    public :optional_unwrap_code

    # Inside an `IF <code> != NIL THEN` guard CLEAR has already narrowed the
    # value, in expression position as well as statement position, and rejects
    # a further `?` as UNWRAP_NON_OPTIONAL. Safe navigation lowers to exactly
    # that guard, so its body reads the receiver directly.
    def guarded_receiver_code(code)
      code.match?(/\A[A-Za-z_][\w.]*\z/) ? code : "(#{code})"
    end
    public :guarded_receiver_code
    private

    def visit_block_parameter_node(node)
      type = (@param_types && @param_types[node.name.to_s]) || untyped_type
      return "#{node.name}: #{type}" unless type == "Auto" || type.to_s.start_with?("?")

      "#{node.name}: #{type} = NIL"
    end

    def visit_rest_parameter_node(node)
      name = node.name ? node.name.to_s : "args"
      type = rest_parameter_type(name)
      "#{name}: #{type} = []"
    end

    def visit_keyword_rest_parameter_node(node)
      name = node.name ? node.name.to_s : "kwargs"
      type = keyword_rest_parameter_type(name)
      "#{name}: #{type} = {}"
    end

    def rest_parameter_type(name)
      type = @param_types && @param_types[name]
      return "#{untyped_type}[]" if type.nil? || type == "Auto" || type == "Any"
      return type if type.end_with?("[]")

      "#{type}[]"
    end

    def keyword_rest_parameter_type(name)
      type = @param_types && @param_types[name]
      return "HashMap<String@symbol, #{untyped_type}>" if type.nil? || type == "Auto" || type == "Any"
      return type if type.start_with?("HashMap<")

      "HashMap<String@symbol, #{type}>"
    end

    def visit_array_node(node)
      if node.elements.any?(Prism::SplatNode)
        segments = []
        literal_elements = []
        flush_literals = lambda do
          unless literal_elements.empty?
            segments << "[#{literal_elements.join(', ')}]"
            literal_elements.clear
          end
        end
        node.elements.each do |element|
          if element.is_a?(Prism::SplatNode)
            flush_literals.call
            expr = element.expression
            code = expression_argument_code(expr)
            code = "(#{code})" if expr.is_a?(Prism::IfNode) || expr.is_a?(Prism::UnlessNode) || expr.is_a?(Prism::CaseNode)
            segments << code
          else
            literal_elements << match_arm_expression(expression_argument_code(element))
          end
        end
        flush_literals.call
        return segments.first if segments.length == 1

        return "(#{segments.join(' + ')})"
      end

      elements = node.elements.map { |element| match_arm_expression(expression_argument_code(element)) }.join(", ")
      literal = node.elements.empty? ? "List[]" : "[#{elements}]"
      inferred_type = array_literal_clear_type(node)
      return_element_type = @current_function_return_type.to_s
      if return_element_type.start_with?("Tuple<")
        # Handles both a bare tuple return (`RETURNS Tuple<...>`) and an
        # array-of-tuples return (`RETURNS Tuple<...>[]`). A nil tuple element
        # (e.g. `[true, nil]`) infers as Void from the literal alone -
        # array_literal_clear_type already produces a same-length Tuple<...>
        # shape in that case (a Void member doesn't collapse the "unique
        # types" check), so this can't gate on "is it already a tuple" - the
        # declared return type's per-slot type (e.g. `?ErrorType`) is simply
        # more authoritative than a literal-only inference whenever their
        # arity matches.
        tuple_type = return_element_type.end_with?("[]") ? return_element_type.delete_suffix("[]") : return_element_type
        tuple_members = split_top_level_clear_list(tuple_type.delete_prefix("Tuple<").delete_suffix(">"))
        inferred_type = tuple_type if tuple_members.length == node.elements.length
      end
      tuple_expression = inferred_type.to_s.start_with?("Tuple<") && inferred_type.to_s.end_with?(">")
      return "CAST(Tuple{#{elements}} AS #{inferred_type})" if tuple_expression

      literal
    end

    def visit_splat_node(node)
      unsupported_expression(node, "Splat arguments require an explicit call shape or generated overload")
    end

    def visit_assoc_splat_node(node)
      visit(node.value)
    end

    def visit_hash_node(node)
      visit_hash_elements(node.elements)
    end

    def visit_keyword_hash_node(node)
      visit_hash_elements(node.elements)
    end

    def typed_hash_literal_code(node, type)
      return nil unless type
      return nil unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      return nil if node.elements.any?(Prism::AssocSplatNode)

      key_type = map_key_clear_type(type)
      value_type = map_value_clear_type(type)
      return nil unless key_type && value_type

      pairs = node.elements.map do |element|
        return nil unless element.is_a?(Prism::AssocNode)

        key = if element.key.is_a?(Prism::SymbolNode)
          symbol_hash_key_code(element.key.value.to_s)
        else
          wrap_argument_for_parameter_type(visit(element.key), element.key, key_type)
        end
        value = wrap_argument_for_parameter_type(visit(element.value), element.value, value_type)
        "#{key}: #{value}"
      end
      literal = "{#{pairs.join(', ')}}"
      pairs.empty? ? literal : "CAST(#{literal} AS #{type})"
    end

    def visit_hash_elements(elements)
      return "{#{elements.map { |element| visit(element) }.join(', ')}}" unless elements.any?(Prism::AssocSplatNode)

      chunks = []
      pairs = []
      flush_pairs = lambda do
        next if pairs.empty?

        chunks << "{#{pairs.join(', ')}}"
        pairs.clear
      end
      elements.each do |element|
        if element.is_a?(Prism::AssocSplatNode)
          flush_pairs.call
          chunks << visit(element.value)
        else
          pairs << visit(element)
        end
      end
      flush_pairs.call
      return chunks.first if chunks.length == 1

      chunks.drop(1).reduce(chunks.first) { |merged, chunk| "mergeKwargs(#{merged}, #{chunk})" }
    end

    def visit_assoc_node(node)
      key = visit(node.key)
      if node.key.is_a?(Prism::SymbolNode)
        key = symbol_hash_key_code(node.key.value.to_s)
      end
      val = visit(node.value)
      "#{key}: #{val}"
    end

    def symbol_hash_key_code(raw_key)
      raw_key.match?(/\A[A-Za-z]\w*\z/) && !CLEAR_KEYWORDS.include?(raw_key) ? ":#{raw_key}" : "symbol(#{raw_key.inspect})"
    end

    def visit_and_node(node)
      if (runtime_is_a = runtime_is_a_predicate(node.left))
        lhs = "#{runtime_is_a[:receiver_code]} IS_A #{runtime_is_a[:expected_type]} AS #{runtime_is_a[:binding_name]}"
        rhs = with_narrowing_context(runtime_is_a) { visit_boolean_and_operand(node.right) }
        return "(IF #{lhs} THEN #{rhs} ELSE FALSE END)"
      end

      lhs = visit_boolean_and_operand(node.left)
      return "FALSE" if lhs == "NIL" || lhs == "FALSE"
      optional_truthy = optional_union_truthy_if_guard(node.left)
      rhs = if optional_truthy && node.left.is_a?(Prism::LocalVariableReadNode)
        # `x && rhs` becomes `(x != NIL) AND rhs`, whose left flow-narrows a
        # local `x` in place; narrow the type without renaming to `x?`.
        with_local_optional_narrowed(optional_truthy[:receiver_name], optional_truthy[:payload_type]) do
          visit_boolean_and_operand(node.right)
        end
      elsif optional_truthy
        expression_guard = optional_truthy.merge(
          binding_name: optional_unwrap_code(optional_truthy[:receiver_code])
        )
        with_optional_truthy_context(expression_guard) { visit_boolean_and_operand(node.right) }
      else
        visit_boolean_and_operand(node.right)
      end
      "(#{lhs} AND #{rhs})"
    end

    def visit_boolean_and_operand(node)
      if node.is_a?(Prism::CallNode) && node.safe_navigation?
        receiver = visit(node.receiver)
        unwrapped = optional_unwrap_code(receiver)
        @lowering_safe_navigation << node.object_id
        inner = with_node_code_override(node.receiver, unwrapped) { visit_call_node(node) }
        @lowering_safe_navigation.delete(node.object_id)
        return "((#{receiver} != NIL) AND #{inner})"
      end

      code = predicate_code(node)
      operand_type = inferred_clear_type(node).to_s
      if node.is_a?(Prism::LocalVariableReadNode)
        operand_type = @local_types.fetch(node.name.to_s, operand_type).to_s
      end
      code = "(#{code} != NIL)" if operand_type.start_with?("?")
      code = "TRUE" if statically_truthy_boolean_operand?(node, operand_type)
      code.include?("|>") ? "(#{code})" : code
    end

    def statically_truthy_boolean_operand?(node, type)
      return false if type.empty? || %w[Any Auto Bool Nil].include?(type)
      return false if type.start_with?("?")
      return false if @union_types.key?(type)

      node.is_a?(Prism::LocalVariableReadNode) ||
        node.is_a?(Prism::InstanceVariableReadNode) ||
        node.is_a?(Prism::ConstantReadNode) ||
        node.is_a?(Prism::ConstantPathNode) ||
        node.is_a?(Prism::StringNode) ||
        node.is_a?(Prism::SymbolNode) ||
        node.is_a?(Prism::IntegerNode) ||
        node.is_a?(Prism::FloatNode) ||
        node.is_a?(Prism::ArrayNode) ||
        node.is_a?(Prism::HashNode) ||
        node.is_a?(Prism::SelfNode)
    end

    def visit_or_node(node)
      lhs = visit(node.left)
      if node.left.is_a?(Prism::LocalVariableWriteNode)
        rhs = visit(node.right)
        value_node = node.left.value
        value_type = inferred_clear_type(value_node).to_s
        if value_node.is_a?(Prism::CallNode) && value_node.name.to_s == "[]" && value_node.receiver
          receiver_type = clear_type_for_receiver_node(value_node.receiver)
          value_type = map_value_clear_type(receiver_type).to_s
        end
        if node.right.is_a?(Prism::CallNode) && ruby_raise_call?(node.right) &&
           !value_type.empty? && !%w[Any Auto Bool].include?(value_type)
          rhs = "CAST(#{rhs} AS #{value_type.delete_prefix('?')})"
        end
        return "#{lhs} OR #{rhs}"
      end
      left_type = inferred_clear_type(node.left).to_s
      if node.left.is_a?(Prism::LocalVariableReadNode)
        left_type = @local_types.fetch(node.left.name.to_s, left_type).to_s
      elsif node.left.is_a?(Prism::CallNode) && node.left.receiver.nil?
        left_type = @local_types.fetch(node.left.name.to_s, left_type).to_s
      end
      if node.left.is_a?(Prism::CallNode) && node.left.name.to_s == "[]" && node.left.receiver
        receiver_type = clear_type_for_receiver_node(node.left.receiver)
        map_value_type = map_value_clear_type(receiver_type)
        left_type = optional_clear_type(map_value_type) if map_value_type
      end
      expected_type = @expected_expression_type.to_s
      expected_base = expected_type.delete_prefix("?").split("@").first
      left_base = left_type.delete_prefix("?").split("@").first
      if left_type.start_with?("?") && expected_type.include?("@multiowned") &&
         left_base == expected_base && !left_type.include?("@multiowned")
        lhs = wrap_argument_for_parameter_type(lhs, node.left, "?#{expected_base}@multiowned")
        left_type = "?#{expected_base}@multiowned"
      end
      contextual_type = @typed_ir.contextual_type_for(node)&.to_clear.to_s
      contextual_optional_left = false
      if %w[Any Auto].include?(left_type) && !contextual_type.empty? &&
         !%w[Any Auto Bool].include?(contextual_type.delete_prefix("?"))
        contextual_value_type = contextual_type.delete_prefix("?")
        lhs = "CAST(#{lhs} AS #{optional_clear_type(contextual_value_type)})"
        left_type = optional_clear_type(contextual_value_type)
        contextual_optional_left = true
      end
      if !left_type.empty? && left_type != "Any" && left_type != "Auto" &&
         left_type != "Bool" && !left_type.start_with?("?")
        return lhs
      end
      nil_receiver = nil_predicate_receiver(node.left)
      rhs = if nil_receiver && inferred_clear_type(nil_receiver).to_s.start_with?("?")
        receiver_code = visit(nil_receiver)
        with_structural_code_override(nil_receiver, optional_unwrap_code(receiver_code)) { visit(node.right) }
      else
        visit(node.right)
      end
      if left_type.start_with?("?") && @union_types.key?(left_type.delete_prefix("?"))
        rhs = wrap_argument_for_parameter_type(rhs, node.right, left_type.delete_prefix("?"))
      end
      if left_type.start_with?("?") && node.right.is_a?(Prism::CallNode) && ruby_raise_call?(node.right)
        fallback_type = left_type.delete_prefix("?")
        unless fallback_type.empty? || %w[Any Auto].include?(fallback_type)
          rhs = "CAST(#{rhs} AS #{fallback_type})"
        end
      end
      right_type = inferred_clear_type(node.right).to_s
      if left_type.start_with?("?") && (right_type == "Bool" || boolean_syntax_node?(node.right))
        return "((#{lhs} != NIL) OR #{rhs})"
      end
      right_optional = right_type.start_with?("?") ||
        (node.right.is_a?(Prism::CallNode) && node.right.safe_navigation?)
      repeatable_left = pure_expression?(node.left) ||
        (node.left.is_a?(Prism::CallNode) && node.left.name.to_s == "[]")
      if left_type.start_with?("?") && right_optional && repeatable_left
        return "(IF #{lhs} != NIL THEN #{lhs} ELSE #{rhs} END)"
      end
      lhs = "(#{lhs})" if lhs.include?("|>")
      rhs = "(#{rhs})" if rhs.include?("|>")
      left_optional = nilable_expression?(node.left) ||
        (node.left.is_a?(Prism::CallNode) && node.left.safe_navigation?) ||
        contextual_optional_left
      op = left_optional ? "OR_ELSE" : "OR"
      "(#{lhs} #{op} #{rhs})"
    end

    def boolean_syntax_node?(node)
      return true if node.is_a?(Prism::TrueNode) || node.is_a?(Prism::FalseNode) ||
        node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode)

      node.is_a?(Prism::CallNode) && %w[== != < <= > >= nil? is_a?].include?(node.name.to_s)
    end

    def nil_predicate_receiver(node)
      return nil unless node.is_a?(Prism::CallNode) && node.name.to_s == "nil?" && node.receiver
      return nil if node.arguments && node.arguments.arguments.any?

      node.receiver
    end

    def nilable_expression?(node)
      type = inferred_clear_type(node)
      type.to_s.start_with?("?")
    end

    def visit_nil_node(node)
      "NIL"
    end

    def visit_false_node(node)
      "FALSE"
    end

    def visit_true_node(node)
      "TRUE"
    end

    def visit_parentheses_node(node)
      if node.body
        if node.body.is_a?(Prism::StatementsNode) && node.body.body.length == 1
          "(#{visit(node.body.body.first).delete_suffix(";")})"
        else
          "(#{visit(node.body).delete_suffix(";")})"
        end
      else
        "()"
      end
    end

    def visit_until_node(node)
      pred = predicate_code(node.predicate)
      body = with_indent { visit(node.statements) }
      "WHILE !(#{pred}) DO\n#{body}\nEND"
    end

    def and_condition_nodes(node)
      if node.is_a?(Prism::AndNode)
        and_condition_nodes(node.left) + and_condition_nodes(node.right)
      else
        [node]
      end
    end

    def parenthesized_single_expression(node)
      return node unless node.is_a?(Prism::ParenthesesNode)
      return node unless node.body.is_a?(Prism::StatementsNode)
      return node unless node.body.body.length == 1

      node.body.body.first
    end

    def while_assignment_guard_lines(predicate)
      return nil unless contains_node_type?(predicate, Prism::LocalVariableWriteNode)

      lines = []
      and_condition_nodes(predicate).each do |condition|
        expression = parenthesized_single_expression(condition)
        if expression.is_a?(Prism::LocalVariableWriteNode)
          assignment = visit(expression).delete_suffix(";")
          name = expression.name.to_s
          lines << "#{assignment};"
          lines << "IF !(#{name}) THEN"
          lines << "  BREAK;"
          lines << "END"
        elsif contains_node_type?(expression, Prism::LocalVariableWriteNode)
          return nil
        else
          pred = visit(condition)
          lines << "IF !(#{pred}) THEN"
          lines << "  BREAK;"
          lines << "END"
        end
      end
      lines
    end

    def visit_while_node(node)
      if (guard_lines = while_assignment_guard_lines(node.predicate))
        body = with_indent do
          guard_code = guard_lines.map { |line| "#{indent}#{line}" }.join("\n")
          body_code = visit(node.statements)
          [guard_code, body_code].reject(&:empty?).join("\n")
        end
        return "WHILE TRUE DO\n#{body}\nEND"
      end

      pred = predicate_code(node.predicate)
      body = with_indent { visit(node.statements) }
      "WHILE #{pred} DO\n#{body}\nEND"
    end

    def contextual_array_return(code, node)
      return code unless node.is_a?(Prism::ArrayNode)

      return_type = @current_function_return_type.to_s
      return code unless return_type.end_with?("[]")
      return code if code.start_with?("CAST(")

      "CAST(#{code} AS #{return_type})"
    end

    def hoist_tuple_pipeline_return(code)
      return nil unless code.include?("( { MUTABLE rtoc_tuple_results =") ||
        code.include?("( { MUTABLE rtoc_map_results =")

      name = next_generated_local("tuple_return")
      "MUTABLE #{name} = #{code};\nRETURN #{name};"
    end

    def render_multiline_expression_return(code, node)
      return nil unless code.include?("\n")
      return nil unless code.lstrip.start_with?("MUTABLE rtoc_mutable_receiver_")

      lines = code.lines.map(&:rstrip).reject(&:empty?)
      value = lines.pop
      value = wrap_argument_for_parameter_type(value, node, @current_function_return_type)
      value = contextual_array_return(value, node)
      value = materialize_borrowed_code(value, node)
      [*lines, "RETURN #{value};"].join("\n")
    end

    def visit_return_node(node)
      if node.arguments
        args = node.arguments.arguments
        if args.length == 1 && args.first.is_a?(Prism::IfNode)
          return render_returning_if_node(args.first)
        end

        if args.length == 1 && args.first.is_a?(Prism::CaseNode)
          return render_returning_case_node(args.first)
        end

        if args.length == 1 && args.first.is_a?(Prism::OrNode) &&
           (render_or = render_returning_or_node(args.first))
          return render_or
        end

        if args.length == 1 && args.first.is_a?(Prism::CallNode) && args.first.safe_navigation?
          return render_returning_safe_navigation(args.first)
        end

        if args.length == 1
          @direct_return_value_depth += 1
          begin
            code = with_expected_expression_type(@current_function_return_type) { visit(args.first) }
          ensure
            @direct_return_value_depth -= 1
          end
          if (upgraded = ownership_upgrade_return_code(code, args.first))
            return upgraded
          end
          if (multiline_return = render_multiline_expression_return(code, args.first))
            return multiline_return
          end
          code = wrap_argument_for_parameter_type(code, args.first, @current_function_return_type)
          code = contextual_array_return(code, args.first)
          code = materialize_borrowed_code(code, args.first)
          if (hoisted = hoist_tuple_pipeline_return(code))
            return hoisted
          end
          return "RETURN #{code}"
        end

        "RETURN #{visit(node.arguments)}"
      else
        "RETURN"
      end
    end

    def visit_super_node(node)
      return "" if struct_initializer_super_call?
      return "" if @current_function_name.to_s == "initialize_copy"

      args = node.arguments ? visit(node.arguments) : ""
      "super(#{args})"
    end

    def visit_forwarding_super_node(_node)
      return "" if struct_initializer_super_call?
      return "" if @current_function_name.to_s == "initialize_copy"

      "super()"
    end

    def struct_initializer_super_call?
      @current_class && @current_function_name.to_s.match?(/initialize!?\z/)
    end

    def visit_yield_node(node)
      args = node.arguments ? visit(node.arguments) : ""
      callee = if @current_block_parameter_name
        @renames[@current_block_parameter_name] || @current_block_parameter_name
      else
        "yield"
      end
      "#{callee}(#{args})"
    end

    def visit_break_node(node)
      "BREAK"
    end

    def visit_next_node(node)
      if (@lambda_depth || 0) > 0
        return "RETURN" if (@void_lambda_depth || 0) > 0

        args = node.arguments&.arguments || []
        value = args.empty? ? "NIL" : visit(args.first)
        return "RETURN #{value}"
      end

      "CONTINUE"
    end

    def contains_narrowing_predicate?(node)
      return false unless node
      return true if runtime_is_a_predicate(node)
      if node.is_a?(Prism::CallNode) && node.name.to_s == "is_a?"
        argument = node.arguments&.arguments&.first
        return true if argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)
      end
      if node.is_a?(Prism::AndNode)
        return contains_narrowing_predicate?(node.left) || contains_narrowing_predicate?(node.right)
      end
      false
    end

    def render_nested_if(predicate, statements, consequent)
      if predicate.is_a?(Prism::AndNode) && contains_narrowing_predicate?(predicate.right)
        left = predicate.left
        right = predicate.right
        left_runtime_is_a = runtime_is_a_predicate(left)
        inner_if = if left_runtime_is_a
          with_narrowing_context(left_runtime_is_a) { render_nested_if(right, statements, consequent) }
        else
          render_nested_if(right, statements, consequent)
        end
        pred_prefix = ""
        pred_assignment = predicate_assignment_node(left)
        optional_truthy = pred_assignment || left_runtime_is_a ? nil : optional_union_truthy_if_guard(left)
        compound_optional_truthies = pred_assignment || optional_truthy ? [] : optional_truthies_in_and(left)
        pred_code = if left_runtime_is_a
          "#{left_runtime_is_a[:receiver_code]} IS_A #{left_runtime_is_a[:expected_type]} AS #{left_runtime_is_a[:binding_name]}"
        elsif pred_assignment
          pred_prefix = "#{visit(pred_assignment)};\n"
          receiver_name = pred_assignment.name.to_s
          receiver_code = @renames[receiver_name] || receiver_name
          receiver_type = @local_types[receiver_code].to_s
          if receiver_type.start_with?("?")
            payload_type = receiver_type.delete_prefix("?")
            optional_truthy = {
              receiver_name: receiver_name,
              receiver_code: receiver_code,
              binding_name: optional_guard_binding_name(receiver_name),
              payload_type: payload_type,
              union_like: union_like_type?(payload_type),
            }
            "#{receiver_code} EXISTS AS #{optional_truthy[:binding_name]}"
          else
            receiver_code
          end
        elsif optional_truthy
          "#{optional_truthy[:receiver_code]} EXISTS AS #{optional_truthy[:binding_name]}"
        else
          predicate_code(left)
        end
        body = with_block_local_scope do
          with_indent do
            if optional_truthy || compound_optional_truthies.any?
              guards = optional_truthy ? [optional_truthy] : compound_optional_truthies
              with_optional_truthy_contexts(guards) { inner_if }
            else
              inner_if
            end
          end
        end
        else_code = if consequent
          with_block_local_scope do
            if consequent.is_a?(Prism::IfNode)
              visit(consequent)
            elsif consequent.respond_to?(:statements)
              visit(consequent.statements)
            else
              visit(consequent)
            end
          end
        else
          ""
        end
        consequent_part = else_code.empty? ? "" : "\nELSE\n#{with_indent { else_code }}"
        return "#{pred_prefix}IF #{pred_code} THEN\n#{body}#{consequent_part}\nEND"
      end
      render_simple_if(predicate, statements, consequent)
    end

    def render_simple_if(predicate, statements, consequent)
      predicate_prefix = ""
      pred_assignment = predicate_assignment_node(predicate)
      embedded_assignment = pred_assignment ? nil : embedded_predicate_assignment_node(predicate)
      runtime_is_a = embedded_assignment ? nil : runtime_is_a_predicate(predicate)
      optional_truthy = runtime_is_a || pred_assignment || embedded_assignment ? nil : optional_union_truthy_if_guard(predicate)
      compound_optional_truthies = runtime_is_a || pred_assignment || embedded_assignment || optional_truthy ? [] : optional_truthies_in_and(predicate)
      pred = if runtime_is_a
        "#{runtime_is_a[:receiver_code]} IS_A #{runtime_is_a[:expected_type]} AS #{runtime_is_a[:binding_name]}"
      elsif pred_assignment
        predicate_prefix = "#{visit(pred_assignment)};\n"
        receiver_name = pred_assignment.name.to_s
        receiver_code = @renames[receiver_name] || receiver_name
        receiver_type = @local_types[receiver_code].to_s
        if receiver_type.start_with?("?")
          payload_type = receiver_type.delete_prefix("?")
          optional_truthy = {
            receiver_name: receiver_name,
            receiver_code: receiver_code,
            binding_name: optional_guard_binding_name(receiver_name),
            payload_type: payload_type,
            union_like: union_like_type?(payload_type),
          }
          "#{receiver_code} EXISTS AS #{optional_truthy[:binding_name]}"
        else
          receiver_code
        end
      elsif embedded_assignment
        assignment = visit(embedded_assignment)
        predicate_prefix = "#{assignment};\n"
        binding_name = @renames[embedded_assignment.name.to_s] || embedded_assignment.name.to_s
        with_node_code_override(embedded_assignment, binding_name) { predicate_code(predicate) }
      elsif optional_truthy
        "#{optional_truthy[:receiver_code]} EXISTS AS #{optional_truthy[:binding_name]}"
      else
        predicate_code(predicate)
      end
      return visit(statements) if pred == "TRUE"
      if pred == "FALSE"
        return visit(consequent) if consequent.is_a?(Prism::IfNode)
        return visit(consequent.statements) if consequent&.respond_to?(:statements)
        return ""
      end
      keyword = comptime_predicate?(pred) ? "COMPTIME IF" : "IF"
      body = with_block_local_scope do
        with_indent do
          if runtime_is_a
            mutable_binding = mutable_runtime_narrowing_alias(runtime_is_a, statements)
            context = narrowing_context_with_binding(runtime_is_a, mutable_binding)
            declaration = mutable_narrowing_declaration(runtime_is_a, mutable_binding)
            rendered = with_narrowing_context(context) { visit(statements) }
            [declaration, rendered].compact.join("\n")
          elsif optional_truthy || compound_optional_truthies.any?
            guards = optional_truthy ? [optional_truthy] : compound_optional_truthies
            if optional_truthy
              mutable_binding = mutable_runtime_narrowing_alias(optional_truthy, statements)
              guard = narrowing_context_with_binding(optional_truthy, mutable_binding)
              declaration = mutable_narrowing_declaration(optional_truthy, mutable_binding)
              rendered = with_optional_truthy_context(guard) { visit(statements) }
              [declaration, rendered].compact.join("\n")
            else
              with_local_optionals_narrowed(guards) { visit(statements) }
            end
          else
            visit(statements)
          end
        end
      end
      body = statement_code(body) unless body.empty? || body.rstrip.end_with?("END")
      consequent_code = if consequent && optional_truthy && consequent.is_a?(Prism::IfNode)
        nested = with_block_local_scope do
          with_indent { render_nested_if(consequent.predicate, consequent.statements, consequent.consequent) }
        end
        "\nELSE\n#{nested}"
      elsif consequent
        with_block_local_scope { format_consequent(consequent, runtime_is_a) }
      else
        ""
      end
      "#{predicate_prefix}#{keyword} #{pred} THEN\n#{body}#{consequent_code}\nEND"
    end

    def visit_if_node(node)
      return "" if ruby_scaffolding_conditional?(node)
      return visit_ternary_if_node(node) if ternary_if_node?(node)
      render_nested_if(node.predicate, node.statements, node.consequent)
    end

    def visit_unless_node(node)
      return "" if ruby_scaffolding_conditional?(node)
      if node.consequent.nil? && statically_truthy_predicate?(node.predicate)
        return ""
      end

      pred = predicate_code(node.predicate)
      keyword = comptime_predicate?(pred) ? "COMPTIME IF" : "IF"
      # `unless x.nil?` lowers to `IF !(x == NIL)`, which flow-narrows `x` to its
      # payload in the body; reflect that so downstream coercions don't re-add a
      # (now invalid) UNWRAP.
      narrowed = nil_check_narrowed_local(node.predicate)
      body = with_indent do
        if narrowed
          with_local_optional_narrowed(narrowed[:name], narrowed[:payload_type]) { visit(node.statements) }
        else
          visit(node.statements)
        end
      end
      consequent_code = node.consequent ? format_consequent(node.consequent) : ""
      "#{keyword} !(#{pred}) THEN\n#{body}#{consequent_code}\nEND"
    end

    def nil_check_narrowed_local(predicate)
      return nil unless predicate.is_a?(Prism::CallNode) && predicate.name.to_s == "nil?"
      receiver = predicate.receiver
      return nil unless receiver.is_a?(Prism::LocalVariableReadNode)

      name = receiver.name.to_s
      type = static_clear_type_for_receiver(name).to_s
      return nil unless type.start_with?("?")

      { name: name, payload_type: type.delete_prefix("?") }
    end

    def with_local_optional_narrowed(name, payload_type)
      old_types = @local_types.dup
      old_shapes = @local_shapes.dup
      @narrowed_optional_storage_locals ||= Set.new
      old_narrowed = @narrowed_optional_storage_locals.dup
      @local_types[name] = payload_type
      @local_shapes[name] = clear_type_shape(payload_type)
      @narrowed_optional_storage_locals << name if union_like_type?(payload_type)
      yield
    ensure
      @local_types = old_types
      @local_shapes = old_shapes
      @narrowed_optional_storage_locals = old_narrowed
    end

    def statically_truthy_predicate?(node)
      name = case node
      when Prism::LocalVariableReadNode
        node.name.to_s
      when Prism::CallNode
        return false unless node.receiver.nil? && (!node.arguments || node.arguments.arguments.empty?)
        node.name.to_s
      end
      return false unless name

      type = @local_types[name].to_s
      !type.empty? && !type.start_with?("?") && !["Any", "Auto", "Bool", "Void"].include?(type)
    end

    def comptime_predicate?(code)
      left = code.to_s.strip[/\A([A-Za-z_][A-Za-z0-9_]*)\s+IS_A\s+/, 1]
      return false unless left

      @current_function_type_bindings.value?(left)
    end

    def predicate_code(node)
      code = visit(node)
      source_type = inferred_clear_type(node).to_s
      union_type = source_type.delete_prefix("?")
      members = @union_types[union_type]
      return code unless !source_type.start_with?("?") && members&.include?("Bool")

      union_payload_cast_code(code, source_type, "Bool") || code
    end

    def union_members(union_type)
      base = union_type.to_s.delete_prefix("?").split("@").first.to_s
      @union_types[base] || []
    end

    def respond_to_is_a_predicate_info(node)
      return nil unless node.is_a?(Prism::CallNode) && node.name.to_s == "respond_to?"

      receiver = node.receiver
      return nil unless receiver.is_a?(Prism::LocalVariableReadNode)
      receiver_name = receiver.name.to_s
      receiver_type = static_clear_type_for_receiver(receiver_name)
      return nil unless receiver_type

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length == 1

      method_name = if args.first.is_a?(Prism::SymbolNode)
        args.first.value.to_s
      end
      return nil unless method_name

      union_m = union_members(receiver_type)
      return nil if union_m.empty?

      clear_name = clear_function_name(method_name)
      field_name = method_name.to_s.delete_suffix("=")

      responding_variants = union_m.select do |variant|
        @class_instance_field_types[variant]&.key?(field_name) ||
          @class_instance_method_names[variant]&.include?(clear_name)
      end

      return nil unless responding_variants.length == 1
      responding_variants.first
    end

    def runtime_is_a_predicate(node)
      if (helper_predicate = schema_helper_type_predicate(node))
        receiver_name = helper_predicate[:receiver_name]
        receiver_type = static_clear_type_for_receiver(receiver_name)
        expected_type = runtime_is_a_expected_type(receiver_type, helper_predicate[:expected_type])
        return nil unless receiver_type && runtime_union_narrowing_candidate?(receiver_type, expected_type)

        binding_name = runtime_is_a_binding_name(expected_type, receiver_name)
        receiver_code = runtime_is_a_receiver_code(
          receiver_name,
          helper_predicate[:receiver_code],
          receiver_type,
        )
        receiver_code = optional_unwrap_code(receiver_code) if receiver_type.to_s.start_with?("?")
        return {
          receiver_name: receiver_name,
          receiver_code: receiver_code,
          expected_type: expected_type,
          binding_name: binding_name,
          renames: { receiver_name => binding_name },
        }
      end

      expected_raw = type_predicate_argument(node)
      expected_raw ||= respond_to_is_a_predicate_info(node)
      return nil unless expected_raw

      receiver = node.receiver
      return nil unless receiver.is_a?(Prism::LocalVariableReadNode)

      receiver_name = receiver.name.to_s
      renamed_receiver = @renames[receiver_name]
      receiver_lookup_name = if renamed_receiver && static_clear_type_for_receiver(renamed_receiver)
        renamed_receiver
      else
        receiver_name
      end
      receiver_type = static_clear_type_for_receiver(receiver_lookup_name)
      expected_type = runtime_is_a_expected_type(receiver_type, expected_raw)
      return nil unless receiver_type && runtime_union_narrowing_candidate?(receiver_type, expected_type)

      binding_name = runtime_is_a_binding_name(expected_type, receiver_name)
      receiver_code = runtime_is_a_receiver_code(receiver_name, visit(receiver), receiver_type)
      receiver_code = optional_unwrap_code(receiver_code) if receiver_type.to_s.start_with?("?")
      {
        receiver_name: receiver_name,
        receiver_code: receiver_code,
        expected_type: expected_type,
        binding_name: binding_name,
        renames: { receiver_name => binding_name },
      }
    end

    def runtime_is_a_receiver_code(receiver_name, receiver_code, receiver_type)
      unwrap_code = optional_unwrap_code(receiver_name)
      local_receiver = !@current_param_names.include?(receiver_name)
      if local_receiver && receiver_code == unwrap_code && !receiver_type.to_s.start_with?("?")
        return receiver_name
      end

      receiver_code
    end

    def runtime_is_a_binding_name(expected_type, receiver_name)
      base = if expected_type.to_s.end_with?("[]")
        "array"
      elsif expected_type.to_s.start_with?("HashMap<")
        "hash"
      else
        expected_type.to_s.split(".").last
      end
      snake = base
        .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .downcase
        .gsub(/[^a-z0-9_]+/, "_")
        .gsub(/\A_+|_+\z/, "")
      snake = "#{receiver_name}_as_#{snake}" if snake == receiver_name
      snake.empty? ? "#{receiver_name}_payload" : snake
    end

    def visit_case_node(node)
      if node.predicate.nil?
        return render_case_as_condition_chain(node, nil)
      else
        target = visit(node.predicate)
        if statement_case_condition_chain?(node)
          return render_case_as_condition_chain(node, target)
        end

        arms = []
        node.conditions.each do |w|
          w.conditions.each do |cond|
            narrowing = union_case_narrowing(node.predicate, cond)
            if narrowing
              cond_val = narrowing[:pattern]
              stmt_code = with_block_local_scope do
                with_narrowing_context(narrowing[:context]) { visit(w.statements) }
              end
            else
              cond_val = visit(cond)
              stmt_code = with_block_local_scope { visit(w.statements) }
            end
            stmt_val = match_statement_arm_body(stmt_code)
            arms << "#{cond_val} -> #{stmt_val},"
          end
        end

        if node.consequent
          else_val = with_block_local_scope do
            match_statement_arm_body(visit(node.consequent))
          end
          arms << "DEFAULT -> #{else_val}"
        end

        arms_body = with_indent do
          arms.map { |arm| arm.split("\n").map { |l| "#{indent}#{l}" }.join("\n") }.join("\n")
        end

        "PARTIAL MATCH #{target} START\n#{arms_body}\nEND"
      end
    end

    def union_case_narrowing(predicate, condition)
      return nil unless predicate.is_a?(Prism::LocalVariableReadNode)
      return nil unless condition.is_a?(Prism::ConstantReadNode) || condition.is_a?(Prism::ConstantPathNode)

      receiver_name = predicate.name.to_s
      union_type = inferred_clear_type(predicate).to_s.delete_prefix("?")
      members = @union_types[union_type]
      return nil unless members

      condition_source = condition.location.slice.strip.delete_prefix("::")
      condition_owner = if condition_source.include?("::")
        condition_source
      else
        resolve_qualified_class_name(condition_source) || condition_source
      end
      condition_type = clear_type_expr(condition_owner)
      member = if condition_source == "Array"
        members.find do |candidate|
          expand_non_emitted_type_alias(candidate).to_s.delete_prefix("?").end_with?("[]")
        end
      else
        members.find do |candidate|
          expanded = expand_non_emitted_type_alias(candidate).to_s.delete_prefix("?")
          candidate.to_s.delete_prefix("?") == condition_type || expanded == condition_type ||
            union_member_payload_type_match?(candidate, condition_type)
        end
      end
      return nil unless member

      expected_type = expand_non_emitted_type_alias(member).to_s.delete_prefix("?")
      binding_name = runtime_is_a_binding_name(expected_type, receiver_name)
      {
        pattern: "#{union_type}.#{union_variant_name(member, union_type)} AS #{binding_name}",
        context: {
          receiver_name: receiver_name,
          expected_type: expected_type,
          binding_name: binding_name,
          renames: { receiver_name => binding_name }
        }
      }
    end

    def statement_case_condition_chain?(node)
      return true if node.conditions.any? { |w| w.conditions.any? { |cond| cond.is_a?(Prism::SplatNode) } }

      node.conditions.any? { |w| !case_value_arm?(w.statements) } ||
        (node.consequent && !case_value_arm?(node.consequent.statements))
    end

    def case_value_arm?(statements)
      return false unless statements.is_a?(Prism::StatementsNode) && statements.body.length == 1

      statement = statements.body.first
      return false if lambda_statement_node?(statement)
      if statement.is_a?(Prism::CallNode)
        name = statement.name.to_s
        return false if name == "<<" || name.end_with?("!")
        return false if statement.block && %w[each each_with_index reverse_each each_key each_value each_pair].include?(name)
      end

      true
    end

    def render_case_as_condition_chain(node, target, returning: false)
      chunks = []
      branches = node.conditions.flat_map do |when_node|
        narrowings = if target
          when_node.conditions.map { |condition| union_case_narrowing(node.predicate, condition) }
        else
          []
        end
        if narrowings.any? && narrowings.all?
          narrowings.map { |narrowing| [when_node, narrowing] }
        else
          [[when_node, nil]]
        end
      end
      branches.each_with_index do |(when_node, narrowing), index|
        keyword = index.zero? ? "IF" : "ELSE_IF"
        pred = if narrowing
          context = narrowing.fetch(:context)
          "#{target} IS_A #{context.fetch(:expected_type)} AS #{context.fetch(:binding_name)}"
        else
          case_when_predicate(target, when_node)
        end
        body = with_indent do
          render = -> do
            with_block_local_scope do
              returning ? returning_branch_statements(when_node.statements) : visit(when_node.statements)
            end
          end
          if narrowing
            context = narrowing.fetch(:context)
            mutable_binding = mutable_runtime_narrowing_alias(context, when_node.statements)
            effective_context = narrowing_context_with_binding(context, mutable_binding)
            declaration = mutable_narrowing_declaration(context, mutable_binding)
            rendered = with_narrowing_context(effective_context, &render)
            [declaration, rendered].compact.join("\n")
          else
            render.call
          end
        end
        chunks << "#{keyword} #{pred} THEN\n#{body}"
      end

      if node.consequent
        else_body = with_indent do
          with_block_local_scope do
            returning ? returning_branch_statements(node.consequent.statements) : visit(node.consequent)
          end
        end
        chunks << "ELSE\n#{else_body}"
      elsif returning
        chunks << "ELSE\n#{indent}  RETURN NIL;"
      end

      "#{chunks.join("\n")}#{chunks.empty? ? "" : "\n"}END"
    end

    def case_when_predicate(target, when_node)
      when_node.conditions.map { |cond| case_condition_predicate(target, cond) }.join(" OR ")
    end

    def case_condition_predicate(target, cond)
      return visit(cond) unless target

      if cond.is_a?(Prism::SplatNode)
        return "#{visit(cond.expression)}.contains?(#{target})"
      end

      # Ruby `case x when SomeClass` uses `SomeClass === x`, i.e. `x.is_a?(SomeClass)`.
      # A `when` naming a known CLEAR type is a type test, not value equality.
      if (type_name = case_condition_type_name(cond))
        return "(#{target} IS_A #{type_name})"
      end

      "(#{target} == #{visit(cond)})"
    end

    def case_condition_type_name(cond)
      return nil unless cond.is_a?(Prism::ConstantReadNode) || cond.is_a?(Prism::ConstantPathNode)

      name = static_type_name(cond)
      base = name&.split("::")&.last.to_s
      return nil if base.empty?
      return nil unless @emitted_type_names.key?(base) || @struct_fields.key?(base) ||
        @union_types.key?(base) || @generated_union_defs.key?(base)

      clear_type_expr(name)
    end

    def visit_regular_expression_node(node)
      regex_literal_code(clear_string_literal(node.unescaped))
    end

    def visit_interpolated_regular_expression_node(node)
      pattern = interpolated_regex_pattern_code(node)
      regex_literal_code(pattern, interpolated: true)
    end

    def visit_numbered_reference_read_node(node)
      regex_capture_code(node.number.to_s)
    end

    def visit_defined_node(node)
      value = node.value
      if value.is_a?(Prism::LocalVariableReadNode) || value.is_a?(Prism::ConstantReadNode) ||
         value.is_a?(Prism::ConstantPathNode) || value.is_a?(Prism::SelfNode) ||
         value.is_a?(Prism::InstanceVariableReadNode)
        return "TRUE"
      end

      unsupported_expression(node, "defined? requires runtime Ruby reflection for this expression")
    end

    def visit_alias_method_node(node)
      return unsupported_expression(node, "Method aliases require an enclosing static class") unless @current_class
      return unsupported_expression(node, "Method alias names must be static") unless
        node.new_name.is_a?(Prism::SymbolNode) && node.old_name.is_a?(Prism::SymbolNode)

      alias_method_code(node, node.new_name.value.to_s, node.old_name.value.to_s)
    end

    def alias_method_call_code(node)
      args = node.arguments&.arguments || []
      return unsupported_expression(node, "alias_method expects two static symbol names") unless
        args.length == 2 && args.all?(Prism::SymbolNode)

      alias_method_code(node, args[0].value.to_s, args[1].value.to_s)
    end

    def alias_method_code(node, new_name, old_name)
      return unsupported_expression(node, "Method aliases require an enclosing static class") unless @current_class

      param_infos = method_params_for(old_name, @current_class) || []
      mutating_receiver = mutating_instance_method?(@current_class, old_name)
      params = ["#{mutating_receiver ? 'MUTABLE ' : ''}self: #{clear_type_name_for_emit(@current_class)}"]
      args = [mutating_receiver ? "&self" : "self"]
      param_infos.each do |info|
        return unsupported_expression(node, "Method aliases do not support rest parameter forwarding") if
          [:rest, :keyword_rest].include?(info[:kind])

        param_name = info.fetch(:name)
        param_type = expand_non_emitted_type_alias(info[:type] || untyped_type)
        resolved_param_type = nil
        old_in_sig = @in_function_signature
        @in_function_signature = true
        begin
          resolved_param_type = clear_type_expr(param_type)
        ensure
          @in_function_signature = old_in_sig
        end
        params << "#{info[:mutable] ? 'MUTABLE ' : ''}#{param_name}: #{resolved_param_type}"
        args << (info[:mutable] ? "&#{param_name}" : param_name)
      end
      return_type = method_return_type_for(old_name, @current_class) || "Auto"
      target_name = instance_function_name(@current_class, old_name)
      alias_name = instance_function_name(@current_class, new_name)
      "FN #{alias_name}(#{params.join(', ')}) RETURNS #{return_type} ->\n" \
        "#{indent}  #{target_name}(#{args.join(', ')});\n" \
        "#{indent}END"
    end

    def visit_lambda_node(node)
      block_to_lambda(node)
    end

    def visit_interpolated_string_node(node)
      unless interpolated_parts_include_embedded?(node)
        return clear_string_literal(node.parts.map { |part| interpolated_string_part(part) }.join)
      end

      parts = node.parts.map { |part| interpolated_string_part_for_literal(part) }.join
      "\"#{parts}\""
    end

    # A line-continuation concat nests the interpolated literal one level
    # down ("a #{x}" \<newline> "b"), so embedded statements must be found
    # recursively or the rendered ${...} gets re-escaped as literal text.
    def interpolated_parts_include_embedded?(node)
      node.parts.any? do |part|
        part.is_a?(Prism::EmbeddedStatementsNode) ||
          (part.is_a?(Prism::InterpolatedStringNode) && interpolated_parts_include_embedded?(part))
      end
    end

    def visit_embedded_statements_node(node)
      "${#{embedded_statement_expression(node)}}"
    end

    def interpolated_string_part(part)
      case part
      when Prism::StringNode
        part.unescaped
      when Prism::EmbeddedStatementsNode
        "${#{embedded_statement_expression(part)}}"
      when Prism::InterpolatedStringNode
        part.parts.map { |nested_part| interpolated_string_part(nested_part) }.join
      else
        visit(part).delete_suffix(";")
      end
    end

    def interpolated_string_part_for_literal(part)
      case part
      when Prism::StringNode
        clear_string_escape(part.unescaped)
      when Prism::EmbeddedStatementsNode
        "${#{embedded_statement_expression(part)}}"
      when Prism::InterpolatedStringNode
        part.parts.map { |nested_part| interpolated_string_part_for_literal(nested_part) }.join
      else
        clear_string_escape(visit(part).delete_suffix(";"))
      end
    end

    def embedded_statement_expression(node)
      statements = node.statements
      return "" unless statements

      unless statements.body.length == 1
        return raise_unsupported("String interpolation must contain a single expression", node)
      end

      expression = statements.body.first
      return embedded_assignment_expression(expression) if assignment_statement_node?(expression)

      code = visit(expression).delete_suffix(";")
      string_embeddable_code(code, inferred_clear_type(expression))
    end

    # `x?` -> `UNWRAP (x)`: same unwrap, but one a method call can be applied to.
    def unwrapped_receiver_code(code)
      text = code.to_s.strip
      inner = text.sub(/\A\((.*)\)\z/m, '\\1').strip
      return method_receiver_code(text) unless inner.end_with?("?")

      "UNWRAP (#{inner.delete_suffix('?')})"
    end

    def string_embeddable_code(code, source_type)
      cast = union_payload_cast_code(code, source_type, "String")
      return cast if cast
      return code if source_type && string_like_clear_type?(source_type.to_s)
      if source_type.to_s == "Bool"
        return "(IF #{code} THEN \"true\" ELSE \"false\" END)"
      end
      # An OPTIONAL primitive still has to reach the interpolation as a String.
      # CLEAR narrows bindings, not field paths, so a guarded `x.y` read is
      # still optional here and needs the unwrap spelled out.
      if source_type.to_s.match?(/\A\?(?:U?Int\d*|Byte\d*|Float\d*)\z/)
        return "#{code}.toString()" if narrowed_binding_read?(code)

        return "UNWRAP (#{code.to_s.strip.delete_suffix('?')}).toString()"
      end
      if source_type.to_s.match?(/\A(?:U?Int\d*|Byte\d*|Float\d*)\z/)
        # `x?` is CLEAR's postfix unwrap, but a call on it -- even
        # parenthesized as `(x?).m()` -- still types as SAFE NAVIGATION and
        # hands back an optional, which the interpolation rejects ("$+
        # requires String operands, got ?String"). UNWRAP binds to the
        # parenthesized operand and leaves a definite value to call.
        return "#{unwrapped_receiver_code(code)}.toString()"
      end

      code
    end

    # Ruby's assignment is expression-valued (`x = y` evaluates to `y`), but
    # string interpolation's ${...} slot is lexed as a genuine parenthesized
    # sub-expression (Lexer#read_interpolated_string desugars "...${e}..."
    # to "..." $+ (e) $+ "..."), so it cannot contain a bare assignment
    # statement - CLEAR's assignment has no expression form at all (matches
    # the language's "immutable by default" design; there is no dedicated
    # AssignExpr node anywhere in the parser). Hoist the assignment into a
    # value block: emit it as a preceding statement, then interpolate the
    # value it just assigned - the same "MUTABLE rtoc_value_block_marker"
    # leading-statement idiom used for every other statement-before-
    # trailing-result value block in this file.
    def embedded_assignment_expression(stmt)
      assignment_code, lhs = assignment_statement_and_read_back(stmt)
      value_node = stmt.respond_to?(:value) ? stmt.value : nil
      value = string_embeddable_code(lhs, value_node && inferred_clear_type(value_node))
      return value unless assignment_code

      "{ MUTABLE rtoc_value_block_marker = 0; #{assignment_code} #{value} }"
    end

    def interpolated_regex_pattern_code(node)
      if node.parts.none? { |part| part.is_a?(Prism::EmbeddedStatementsNode) }
        return clear_string_literal(node.parts.map { |part| interpolated_regex_part(part) }.join)
      end

      parts = node.parts.map { |part| interpolated_regex_part_for_literal(part) }.join
      "\"#{parts}\""
    end

    def interpolated_regex_part(part)
      case part
      when Prism::StringNode
        part.unescaped
      when Prism::EmbeddedStatementsNode
        "${#{embedded_regex_pattern_expression(part)}}"
      else
        visit(part).delete_suffix(";")
      end
    end

    def interpolated_regex_part_for_literal(part)
      case part
      when Prism::StringNode
        clear_string_escape(part.unescaped)
      when Prism::EmbeddedStatementsNode
        "${#{embedded_regex_pattern_expression(part)}}"
      else
        clear_string_escape(visit(part).delete_suffix(";"))
      end
    end

    def embedded_regex_pattern_expression(node)
      statements = node.statements
      return "" unless statements

      unless statements.body.length == 1
        return raise_unsupported("Regex interpolation must contain a single expression", node)
      end

      expression = statements.body.first
      if expression.is_a?(Prism::ConstantReadNode)
        static_pattern = @regex_constant_pattern_codes[expression.name.to_s]
        return static_pattern if static_pattern
      end
      code = regex_constant_read?(expression) ? constant_variable_name(expression.name.to_s) : visit(expression).delete_suffix(";")
      regex_pattern_expression?(expression) ? regex_pattern_code(code) : code
    end

    def static_regex_pattern_code(node)
      unwrapped = sorbet_unwrapped_value(node)
      return static_regex_pattern_code(unwrapped) if unwrapped && !unwrapped.equal?(node)

      if node.is_a?(Prism::CallNode) && node.name.to_s == "freeze" &&
         (!node.arguments || node.arguments.arguments.empty?)
        return static_regex_pattern_code(node.receiver)
      end

      return clear_string_literal(node.unescaped) if node.is_a?(Prism::RegularExpressionNode)

      nil
    end

    def regex_pattern_expression?(node)
      return true if regex_value_node?(node)
      return true if regex_constant_read?(node)

      false
    end
    public :regex_pattern_expression?

    def regex_constant_read?(node)
      node.is_a?(Prism::ConstantReadNode) && @regex_constants.include?(node.name.to_s)
    end

    def regex_value_node?(node)
      return false unless node

      unwrapped = sorbet_unwrapped_value(node)
      return regex_value_node?(unwrapped) if unwrapped && !unwrapped.equal?(node)

      return true if node.is_a?(Prism::RegularExpressionNode) || node.is_a?(Prism::InterpolatedRegularExpressionNode)

      node.is_a?(Prism::CallNode) &&
        node.name.to_s == "freeze" &&
        (!node.arguments || node.arguments.arguments.empty?) &&
        regex_value_node?(node.receiver)
    end

    def visit_module_node(node)
      raw_name = node.constant_path.location.slice.strip
      old_class = @current_class
      name = if old_class && !raw_name.include?("::")
        "#{old_class}::#{raw_name}"
      else
        raw_name
      end
      @module_namespace_names << name
      @module_function_names[name].merge(collect_class_method_names(node))
      body_nodes = node.body&.body || []
      emit_module_methods = declaration_comment?(node, "ruby-to-clear: emit-module-methods")
      @current_class = emit_module_methods ? nil : name
      emitted_body_nodes = if emit_module_methods
        body_nodes.reject { |stmt| included_module_name(stmt) }
      else
        module_static_body_nodes(body_nodes)
      end
      body_code = visit_statement_list(hoist_late_module_constants(emitted_body_nodes))
      @current_class = old_class

      if body_code.empty?
        "# Ruby module #{name}"
      else
        "# Ruby module #{name}\n#{body_code}\n# End Ruby module #{name}"
      end
    ensure
      @current_class = old_class if defined?(old_class)
    end

    def hoist_late_module_constants(body_nodes)
      first_method = body_nodes.index { |stmt| stmt.is_a?(Prism::DefNode) }
      return body_nodes unless first_method

      insertion_point = first_method
      while insertion_point.positive?
        previous = body_nodes[insertion_point - 1]
        break unless previous.is_a?(Prism::CallNode) && previous.name.to_s == "sig"

        insertion_point -= 1
      end

      prefix = body_nodes[0...insertion_point]
      remainder = body_nodes[insertion_point..]
      late_constants, methods_and_statements = remainder.partition do |stmt|
        stmt.is_a?(Prism::ConstantWriteNode)
      end
      prefix + late_constants + methods_and_statements
    end

    def visit_singleton_class_node(node)
      @singleton_class_depth += 1
      visit(node.body)
    ensure
      @singleton_class_depth -= 1
    end

    def visit_class_node(node)
      old_class = @current_class
      raw_class_name = node.constant_path.location.slice.strip
      qualified_class_name = if old_class && !raw_class_name.include?("::")
        "#{old_class}::#{raw_class_name}"
      else
        raw_class_name
      end
      class_name = @helper_config.clear_type(qualified_class_name) ||
        clear_type_name_for_emit(qualified_class_name)
      @constant_names[qualified_class_name] = class_name
      @current_class = qualified_class_name
      @class_reentrant_instance_method_names[qualified_class_name].merge(collect_reentrant_instance_method_names(node))
      @public_class_names << qualified_class_name if declaration_comment?(node, "ruby-to-clear: pub")

      if t_enum_class?(node)
        variants = t_enum_variants(node)
        variants.each do |variant|
          @constant_names["#{class_name}::#{variant}"] = "#{class_name}.#{variant}"
        end
        @current_class = old_class
        # Ruby constants are public unless explicitly hidden with
        # `private_constant`. Enum types therefore need to cross generated
        # CLEAR package boundaries just like the signatures that reference
        # them. Keeping them package-private loses a type that resolution had
        # already found in the required Ruby file.
        return "PUB ENUM #{class_name} { #{variants.join(', ')} }"
      end

      if t_struct_class?(node)
        body_nodes = node.body&.body || []
        fields = body_nodes.filter_map { |stmt| t_struct_field(stmt) }
        mixin_fields = included_mixin_fields(body_nodes, qualified_class_name)
        local_field_types = fields.to_h do |field, type, _default|
          [field, concrete_struct_type(type)]
        end
        all_field_types = mixin_fields.merge(local_field_types)
        register_constructor_fields([], @current_class, all_field_types.keys, {}, all_field_types)
        field_decls = all_field_types.map do |field, type|
          "  #{field}: #{struct_field_type(type, class_name)}"
        end.join(",\n")
        body_without_fields = body_nodes.reject { |stmt| t_struct_field(stmt) }
        old_instance_field_names = @current_instance_field_names
        old_instance_method_names = @current_instance_method_names
        old_mutating_instance_method_names = @current_mutating_instance_method_names
        all_field_types.each { |field, type| merge_class_instance_field_type(qualified_class_name, field, type) }
        @class_instance_field_names[qualified_class_name].merge(all_field_types.keys)
        @class_instance_method_names[qualified_class_name].merge(collect_instance_method_names(node))
        @class_class_method_names[qualified_class_name].merge(collect_class_method_names(node))
        @class_mutating_instance_method_names[qualified_class_name].merge(collect_mutating_instance_method_names(node))
        @current_instance_field_names = @class_instance_field_names[qualified_class_name].dup
        @current_instance_method_names = @class_instance_method_names[qualified_class_name].dup
        @current_mutating_instance_method_names = @class_mutating_instance_method_names[qualified_class_name].dup
        body_code = visit_statement_list(body_without_fields)
        @current_instance_field_names = old_instance_field_names
        @current_instance_method_names = old_instance_method_names
        @current_mutating_instance_method_names = old_mutating_instance_method_names
        @current_class = old_class
        return body_code if @emitted_class_structs.include?(class_name)

        @emitted_class_structs << class_name
        struct_code = "#{declaration_visibility_prefix(node)}STRUCT #{class_name} {\n#{field_decls}\n}"
        return body_code.empty? ? struct_code : "#{struct_code}\n\n#{body_code}"
      end

      if struct_new_superclass?(node.superclass)
        fields = struct_new_field_names(node.superclass)
        register_constructor_fields([], @current_class, fields)
        old_instance_field_names = @current_instance_field_names
        old_instance_method_names = @current_instance_method_names
        old_mutating_instance_method_names = @current_mutating_instance_method_names
        fields.each { |field| merge_class_instance_field_type(qualified_class_name, field, "Any") }
        @class_instance_field_names[qualified_class_name].merge(fields)
        @class_instance_method_names[qualified_class_name].merge(collect_instance_method_names(node))
        @class_class_method_names[qualified_class_name].merge(collect_class_method_names(node))
        @class_mutating_instance_method_names[qualified_class_name].merge(collect_mutating_instance_method_names(node))
        @current_instance_field_names = @class_instance_field_names[qualified_class_name].dup
        @current_instance_method_names = @class_instance_method_names[qualified_class_name].dup
        @current_mutating_instance_method_names = @class_mutating_instance_method_names[qualified_class_name].dup
        body_code = visit(node.body)
        @current_instance_field_names = old_instance_field_names
        @current_instance_method_names = old_instance_method_names
        @current_mutating_instance_method_names = old_mutating_instance_method_names
        @current_class = old_class
        return body_code if @emitted_class_structs.include?(class_name)

        @emitted_class_structs << class_name
        field_decls = fields.map { |field| "  #{field}: Any" }.join(",\n")
        struct_code = "#{declaration_visibility_prefix(node)}STRUCT #{class_name} {\n#{field_decls}\n}"
        return body_code.empty? ? struct_code : "#{struct_code}\n\n#{body_code}"
      end

      instance_fields = collect_instance_fields(node)
      old_instance_field_names = @current_instance_field_names
      old_instance_method_names = @current_instance_method_names
      old_mutating_instance_method_names = @current_mutating_instance_method_names
      instance_fields.each { |field, type| merge_class_instance_field_type(qualified_class_name, field, type) }
      @class_instance_field_names[qualified_class_name].merge(instance_fields.keys)
      @class_instance_method_names[qualified_class_name].merge(collect_instance_method_names(node))
      @class_class_method_names[qualified_class_name].merge(collect_class_method_names(node))
      @class_mutating_instance_method_names[qualified_class_name].merge(collect_mutating_instance_method_names(node))
      @current_instance_field_names = @class_instance_field_names[qualified_class_name].dup
      @current_instance_method_names = @class_instance_method_names[qualified_class_name].dup
      @current_mutating_instance_method_names = @class_mutating_instance_method_names[qualified_class_name].dup
      body_nodes = node.body&.body || []
      body_code = visit_statement_list(hoist_late_module_constants(body_nodes))
      constructor_wrapper = constructor_wrapper_for_class(node, qualified_class_name, instance_fields)
      body_code = [body_code, constructor_wrapper].compact.reject(&:empty?).join("\n")
      @current_instance_field_names = old_instance_field_names
      @current_instance_method_names = old_instance_method_names
      @current_mutating_instance_method_names = old_mutating_instance_method_names

      @current_class = old_class

      return body_code if @emitted_class_structs.include?(class_name)
      return body_code if namespace_only_class?(node, instance_fields)
      return body_code if imported_class_extension?(class_name, instance_fields)

      @emitted_class_structs << class_name
      struct_fields = instance_fields.map { |name, type| "  #{name}: #{break_self_reference(type, class_name)}" }.join(",\n")
      struct_code = "#{declaration_visibility_prefix(node)}STRUCT #{class_name} {\n#{struct_fields}\n}"
      "#{struct_code}\n\n#{body_code}"
    end

    def constructor_wrapper_for_class(class_node, class_name, instance_fields)
      return nil if @emitted_constructor_wrappers.include?(class_name)

      initialize_def = class_initializer_def(class_node)
      return nil unless initialize_def
      return nil if @data_only && !declaration_comment?(initialize_def, "ruby-to-clear: data-api")

      @emitted_constructor_wrappers << class_name

      param_types, type_params = constructor_wrapper_type_context(class_node, initialize_def)
      params = with_constructor_parameter_context(param_types) do
        initialize_def.parameters ? visit(initialize_def.parameters) : ""
      end
      defaults = with_constructor_parameter_context(param_types) do
        initializer_field_defaults(initialize_def, instance_fields)
      end
      pairs = instance_fields.map do |field, type|
        value = defaults.fetch(field) { default_value_for_type(type) }
        "#{field}: #{value}"
      end
      literal_class = clear_type_name_for_emit(class_name)
      literal = pairs.empty? ? "#{literal_class}{}" : "#{literal_class}{ #{pairs.join(', ')} }"
      mutable_initializer_params = collect_mutated_parameter_receivers(initialize_def.body)
      args = method_parameter_info(initialize_def.parameters).map do |info|
        mutable_initializer_params.include?(info[:name]) ? "&#{info[:name]}" : info[:name]
      end
      init_name = instance_function_name(class_name, "initialize")
      type_param_suffix = type_params.empty? ? "" : "<#{type_params.join(', ')}>"
      lines = []
      visibility = if @helper_config.export_declarations? ||
          declaration_comment?(class_node, "ruby-to-clear: pub") || @public_class_names.include?(class_name)
        "PUB "
      else
        ""
      end
      returns_type = clear_type_name_for_emit(resolve_type_with_aliasable(class_name))
      initializer_can_fail = known_fallible_method?("initialize", class_name)
      returns_type = fallible_return_type(returns_type) if initializer_can_fail
      return_capability = returns_type.to_s[/@.+\z/]
      constructor_effects = function_effects_suffix(initialize_def)
      return_stmt = if return_capability
        # `self` is freshly owned by this factory. Wrapping it transfers that
        # owner into the requested reference-counted representation; COPY is
        # both unnecessary and illegal for resource-bearing structs.
        "  RETURN self #{return_capability};"
      else
        "  RETURN self;"
      end
      lines << "#{visibility}FN #{constructor_function_name(class_name)}#{type_param_suffix}(#{params}) RETURNS #{returns_type}#{constructor_effects} ->"
      lines << "  MUTABLE self = #{literal};"
      initializer_call = "#{init_name}(#{['&self', *args].join(', ')})"
      lines << "  #{initializer_can_fail ? "TRY (#{initializer_call})" : initializer_call};"
      lines << return_stmt
      lines << "END"
      lines.join("\n")
    end

    def class_initializer_def(class_node)
      body_nodes = class_node.body&.body || []
      body_nodes.find { |stmt| stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && stmt.name.to_s == "initialize" }
    end

    def signature_for_def_in_class(class_node, def_node)
      last_sig = nil
      (class_node.body&.body || []).each do |stmt|
        if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
          last_sig = stmt
          next
        end

        return last_sig if stmt.equal?(def_node)

        last_sig = nil unless stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
      end
      nil
    end

    def constructor_wrapper_type_context(class_node, initialize_def)
      sig_node = signature_for_def_in_class(class_node, initialize_def)
      param_types, _return_type, sig_type_params = parse_sig(sig_node)
      param_names = extract_parameter_names(initialize_def)
      type_bindings = infer_function_type_bindings(initialize_def.body, param_names, param_types, sig_type_params)
      param_types = param_types.merge(type_bindings)
      type_params = (sig_type_params + type_bindings.values).uniq

      [param_types, type_params]
    end

    def with_constructor_parameter_context(param_types)
      old_param_types = @param_types
      old_mutable_params = @mutable_params

      @param_types = param_types
      @mutable_params = Set.new
      yield
    ensure
      @param_types = old_param_types
      @mutable_params = old_mutable_params
    end

    def with_constructor_placeholder_params(param_names)
      old_placeholder_param_names = @constructor_placeholder_param_names
      @constructor_placeholder_param_names = param_names
      yield
    ensure
      @constructor_placeholder_param_names = old_placeholder_param_names
    end

    def initializer_field_defaults(initialize_def, instance_fields)
      param_names = extract_parameter_names(initialize_def)
      defaults = {}
      walk = lambda do |node|
        return unless node
        return if node.is_a?(Prism::DefNode) || node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)

        if node.is_a?(Prism::InstanceVariableWriteNode)
          field = node.name.to_s.delete_prefix("@")
          if instance_fields.key?(field) && !defaults.key?(field)
            value = constructor_initial_field_value(node.value, param_names, instance_fields[field])
            defaults[field] = value if value
          end
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(initialize_def.body)
      defaults
    end

    def constructor_initial_field_value(value_node, param_names, field_type = nil)
      if (typed_value = sorbet_typed_value(value_node))
        return constructor_initial_field_value(typed_value.first, param_names, field_type)
      end

      if (unwrapped = sorbet_unwrapped_value(value_node))
        return constructor_initial_field_value(unwrapped, param_names, field_type)
      end

      case value_node
      when Prism::LocalVariableReadNode
        return nil unless param_names.include?(value_node.name.to_s)

        code = visit(value_node)
        copyable_storage_type?(field_type) ? "COPY #{code}" : code
      when Prism::OrNode
        # Initializers commonly normalize an optional dependency once:
        # `@budget = budget || Budget.new`. The constructor's placeholder
        # must use that total expression; seeding a non-optional field with
        # NIL creates invalid CLEAR before initialize can repair it.
        # Retained identity v4: an @multiowned field is a keep edge - emit
        # the plain `param OR_ELSE default`; the compiler derives the edge
        # op, and a written COPY would force an identity fork.
        if field_type.to_s.include?("@multiowned")
          visit(value_node)
        else
          with_constructor_placeholder_params(param_names) { visit(value_node) }
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::StringNode,
           Prism::InterpolatedStringNode, Prism::SymbolNode, Prism::IntegerNode,
           Prism::FloatNode, Prism::TrueNode, Prism::FalseNode, Prism::NilNode,
           Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode
        visit(value_node)
      when Prism::CallNode
        if value_node.name.to_s == "dup" &&
           value_node.receiver.is_a?(Prism::LocalVariableReadNode) &&
           param_names.include?(value_node.receiver.name.to_s)
          return "COPY #{visit(value_node.receiver)}"
        end

        if constant_constructor_call?(value_node)
          with_constructor_placeholder_params(param_names) { visit(value_node) }
        end
      end
    end

    def declaration_visibility_prefix(node)
      if @helper_config.export_declarations? || declaration_comment?(node, "ruby-to-clear: pub")
        "PUB "
      else
        ""
      end
    end

    # `# ruby-to-clear: field-type <name>=<type>` on a T::Struct const/prop.
    # Struct.new and attr_* classes already honour the directive through the
    # class-body scan in instance_field_types; a T::Struct's fields come from
    # its `const`/`prop` calls, which that scan never sees, so the directive
    # was silently ignored on exactly the declarations whose Ruby type is
    # deliberately loose (T.nilable(BasicObject) to dodge a load cycle).
    def declaration_field_type(node, field_name)
      return nil unless node&.location

      lines = @current_metadata_source_lines || @source.lines
      cursor = node.location.start_line - 2
      while cursor >= 0
        line = lines.fetch(cursor, "").to_s.strip
        break unless line.start_with?("#")

        match = line.match(/#\s*ruby-to-clear:\s*field-type\s+([A-Za-z_]\w*)\s*=\s*([^\s#]+)/)
        return match[2] if match && match[1] == field_name

        cursor -= 1
      end
      nil
    end

    def declaration_comment?(node, marker)
      return false unless node&.location

      loc = if node.respond_to?(:def_keyword_loc) && node.def_keyword_loc
        node.def_keyword_loc
      else
        node.location
      end
      lines = @current_metadata_source_lines || @source.lines
      line_index = loc.start_line - 1
      same_line = lines.fetch(line_index, "").to_s
      return true if same_line.include?(marker)

      same_line_prefix = same_line[0...loc.start_column].to_s
      return true if same_line_prefix.include?(marker)

      cursor = line_index - 1
      loop do
        return false if cursor.negative?

        line = lines.fetch(cursor, "").to_s.strip
        return false if line.empty?
        if line.start_with?("sig ")
          cursor -= 1
          next
        end
        return true if line.include?(marker)
        return false unless line.start_with?("#")

        cursor -= 1
      end
    end

    def namespace_only_class?(node, instance_fields)
      return false unless instance_fields.empty?

      body_nodes = node.body&.body || []
      body_nodes.none? { |stmt| class_body_instance_member?(stmt) }
    end

    def imported_class_extension?(class_name, _instance_fields)
      @imported_class_names.include?(class_name)
    end

    def class_body_instance_member?(stmt)
      case stmt
      when Prism::DefNode
        stmt.receiver.nil?
      when Prism::CallNode
        stmt.receiver.nil? && %w[attr_reader attr_accessor attr_writer].include?(stmt.name.to_s)
      else
        false
      end
    end

    def visit_def_node(node)
      return "" if closed_attribute_macro_definition?(node)
      if (walker = generated_each_locatable_definition(node))
        return walker
      end
      if (walker = generated_each_child_node_definition(node))
        return walker
      end

      chk = check_parameters!(node.parameters)
      return chk if chk.is_a?(String) && chk.include?("# [UNSUPPORTED:")
      
      name = node.name.to_s
      class_storage_declarations = class_method_storage_declarations(node)
      param_types, sig_return_type, sig_type_params = parse_sig(@current_sig)
      sig_return_type = field_reader_return_type(node, name) || sig_return_type
      param_names = extract_parameter_names(node)
      param_renames = function_parameter_renames(param_names)
      type_bindings = infer_function_type_bindings(node.body, param_names, param_types, sig_type_params)
      param_types = param_types.merge(type_bindings)
      @param_types = param_types
      written_vars = collect_written_variables(node.body, param_names)
      local_var_types = collect_local_variable_type_annotations(node.body)
      reassigned_params = param_names & collect_reassigned_variables(node.body)
      written_params = param_names & collect_mutated_parameter_receivers(node.body, param_types)
      
      @mutable_params = written_params

      @typed_ir.analyze_function(
        self,
        node,
        owner: @current_class || "Object",
        parameter_types: param_types,
        local_types: local_var_types.compact
      )
      
      params = []
      singleton_static = @singleton_class_depth.positive? && @current_class
      mutates_self = @current_class && !node.receiver && !singleton_static && mutates_instance_state?(node.body, name)
      if @current_class && !node.receiver && !singleton_static
        self_prefix = mutates_self ? "MUTABLE " : ""
        params << "#{self_prefix}self: #{clear_type_name_for_emit(@current_class)}"
      end

      if node.parameters
        input_param_renames = reassigned_params.each_with_object(param_renames.dup) do |ruby_name, renames|
          clear_name = param_renames.fetch(ruby_name, ruby_name)
          renames[ruby_name] = "#{clear_name}_input"
        end
        params_str = with_renames(input_param_renames) { visit(node.parameters) }
        params << params_str unless params_str.empty?
      end

      old_declared = @declared_locals
      old_function_can_fail = @current_function_can_fail
      old_local_shapes = @local_shapes
      old_local_types = @local_types
      old_local_constant_values = @local_constant_values
      old_inside_function = @inside_function
      old_inside_instance_method = @inside_instance_method
      old_inside_class_method = @inside_class_method
      old_function_returns_value = @current_function_returns_value
      old_function_statement_list_depth = @function_statement_list_depth
      old_function_type_bindings = @current_function_type_bindings
      old_current_param_names = @current_param_names
      old_current_function_return_type = @current_function_return_type
      old_current_function_name = @current_function_name
      old_current_block_parameter_name = @current_block_parameter_name
      old_forced_untyped_locals = @forced_untyped_locals
      old_hash_default_specs = @hash_default_specs
      old_hash_backed_locals = @hash_backed_locals
      @declared_locals = Set.new(param_names)
      @current_function_can_fail = false
      @local_shapes = {}
      @local_types = param_types.reject { |_param, type| type == "Auto" || type == "Any" }
        .merge(local_var_types.compact)
      @local_constant_values = {}
      @forced_untyped_locals = Set.new
      @hash_default_specs = {}
      @hash_backed_locals = {}
      @inside_function = true
      @inside_instance_method = !!(@current_class && !node.receiver && !singleton_static)
      @inside_class_method = !!(@current_class && (node.receiver.is_a?(Prism::SelfNode) || singleton_static))
      @current_function_returns_value = name != "initialize" && sig_return_type != "Void"
      @function_statement_list_depth = 0
      @current_function_type_bindings = type_bindings
      @current_param_names = param_names.dup
      @current_function_return_type = sig_return_type
      @current_function_name = name
      block_parameter = node.parameters&.block
      @current_block_parameter_name = block_parameter&.respond_to?(:name) ? block_parameter.name.to_s : nil

      local_vars_to_declare = collect_predeclared_local_variables(node.body, param_names)
        .select { |var| predeclare_local_variable?(local_var_types[var]) }
        .to_a
        .sort
      local_vars_to_declare.each { |var| @declared_locals << var }

      rescue_plan = function_rescue_plan(node.body)
      rescue_arms_code = nil
      body_code = with_renames(param_renames) do
        if rescue_plan
          main_code = with_indent { render_rescue_plan_nodes(rescue_plan.fetch(:body)) }
          ensure_code = rescue_plan[:ensure] ? with_indent { render_rescue_plan_nodes(rescue_plan.fetch(:ensure)) } : ""
          main_code = [main_code, ensure_code].reject(&:empty?).join("\n")
          clauses = rescue_plan[:clauses] || [
            { catch_all: true, types: [], fallback: rescue_plan.fetch(:fallback) },
          ]
          arms = clauses.map do |clause|
            fallback_code = with_indent { render_rescue_plan_nodes(clause.fetch(:fallback)) }
            fallback_code = [fallback_code, ensure_code].reject(&:empty?).join("\n")
            fallback_code = "#{indent}  RETURN;" if fallback_code.empty?
            header = if clause.fetch(:catch_all)
              "CATCH Transient, Input, System, NotFound, Permission, Canceled"
            else
              # A typed rescue catches its classes as CLEAR error TYPES (the
              # RAISE translation registers the same last-segment names).
              "CATCH #{clause.fetch(:types).join(', ')}"
            end
            "#{header}\n#{fallback_code}"
          end
          # CATCH is a function-body-level construct (the parser only
          # recognizes it as a body terminator, alongside END) - it must
          # stay out of body_code here so it lands OUTSIDE any WITH
          # POLYMORPHIC self wrapper applied below, not nested inside that
          # block's braces where the parser does not expect it.
          rescue_arms_code = arms.join("\n")
          main_code
        else
          with_indent { visit(node.body) }
        end
      end
      
      param_copy_code = reassigned_params.to_a.sort.map do |ruby_name|
        clear_name = param_renames.fetch(ruby_name, ruby_name)
        "#{indent}  MUTABLE #{clear_name} = COPY #{clear_name}_input;"
      end.join("\n")

      decls_code = local_vars_to_declare.map do |var|
        "#{indent}  #{predeclared_local_declaration(var, local_var_types[var])}"
      end.join("\n")
      decls_code = [param_copy_code, decls_code].reject(&:empty?).join("\n")

      full_body = if decls_code.empty?
        body_code
      elsif body_code.empty?
        decls_code
      else
        "#{decls_code}\n#{body_code}"
      end

      local_aliasable_instance = @inside_instance_method && @aliasable_classes.include?(@current_class.to_s)
      full_body = local_aliasable_instance_body(full_body, mutable: !!mutates_self) if local_aliasable_instance
      full_body = "#{full_body}\n#{rescue_arms_code}" if rescue_arms_code

      function_can_fail = @current_function_can_fail ||
        allocating_collection_return_type?(sig_return_type) ||
        declaration_comment?(node, "ruby-to-clear: fallible")
      @declared_locals = old_declared
      @current_function_can_fail = old_function_can_fail
      @local_shapes = old_local_shapes
      @local_types = old_local_types
      @local_constant_values = old_local_constant_values
      @inside_function = old_inside_function
      @inside_instance_method = old_inside_instance_method
      @inside_class_method = old_inside_class_method
      @current_function_returns_value = old_function_returns_value
      @function_statement_list_depth = old_function_statement_list_depth
      @current_function_type_bindings = old_function_type_bindings
      @current_param_names = old_current_param_names
      @current_function_return_type = old_current_function_return_type
      @current_function_name = old_current_function_name
      @current_block_parameter_name = old_current_block_parameter_name
      @forced_untyped_locals = old_forced_untyped_locals
      @hash_default_specs = old_hash_default_specs
      @hash_backed_locals = old_hash_backed_locals
      @mutable_params = nil
      @param_types = nil

      ret_type = if name == "initialize"
        function_can_fail ? "!Void" : "Void"
      elsif sig_return_type != "Auto"
        sig_return_type
      else
        "Auto"
      end
      ret_type = fallible_return_type(ret_type) if function_can_fail
      sig_name = if @current_class && !node.receiver && !singleton_static
        instance_function_name(@current_class, name)
      elsif @current_class && (node.receiver || singleton_static)
        class_method_function_name(@current_class, name)
      else
        clear_function_name(name)
      end
      type_params = (sig_type_params + type_bindings.values).uniq
      type_param_suffix = type_params.empty? ? "" : "<#{type_params.join(', ')}>"

      explicitly_public = @public_method_names.include?(name)
      visibility = if !explicitly_public && (@private_section || @private_method_names.include?(name) || declaration_comment?(node, "ruby-to-clear: private"))
        "PRIVATE "
      elsif @helper_config.export_declarations? || declaration_comment?(node, "ruby-to-clear: pub") || (@current_class && @public_class_names.include?(@current_class))
        "PUB "
      else
        ""
      end
      effects = function_effects_suffix(node)
      if local_aliasable_instance
        # CLEAR parses capability requirements before EFFECTS. Keep each
        # clause on its own header line so a reentrant instance method cannot
        # be mistaken for the legacy post-EFFECTS reentrance-only grammar.
        contract = "\n  REQUIRES self: LOCAL"
        effect_clause = effects.empty? ? "" : "\n  #{effects.strip}"
        header_end = "\n"
      else
        contract = ""
        effect_clause = effects
        header_end = " "
      end
      function_code = "#{visibility}FN #{sig_name}#{type_param_suffix}(#{params.join(', ')}) RETURNS #{ret_type}#{contract}#{effect_clause}#{header_end}->\n#{full_body}\nEND"
      class_storage_declarations.empty? ? function_code : "#{class_storage_declarations.join("\n")}\n#{function_code}"
    end

    def class_method_storage_declarations(node)
      return [] unless @current_class && node.receiver.is_a?(Prism::SelfNode)

      types = {}
      walk = lambda do |child|
        return unless child.is_a?(Prism::Node)
        return if child != node.body && child.is_a?(Prism::DefNode)

        if child.is_a?(Prism::InstanceVariableWriteNode)
          field = child.name.to_s.delete_prefix("@")
          if (typed_value = sorbet_typed_value(child.value))
            types[field] = typed_value[1]
          else
            inferred = inferred_clear_type(child.value)
            types[field] ||= inferred unless [nil, "Auto", "Any"].include?(inferred)
          end
        end
        child.child_nodes.each { |nested| walk.call(nested) if nested }
      end
      walk.call(node.body)

      types.filter_map do |field, type|
        @class_variables << field
        key = "#{@current_class}##{field}"
        next if @emitted_class_storage_variables.include?(key)

        @emitted_class_storage_variables << key
        declared_type = type.to_s
        declared_type = "?Any" if declared_type.empty? || declared_type == "Auto" || declared_type == "Any"
        @class_storage_types[key] = declared_type
        "MUTABLE #{class_storage_variable_name(field)}: #{declared_type} = #{default_value_for_type(declared_type)};"
      end
    end

    def closed_attribute_macro_definition?(node)
      return false unless %w[lifecycle_attr flow_attr].include?(node.name.to_s)

      found = false
      walk = lambda do |child|
        return unless child.is_a?(Prism::Node)
        found = true if child.is_a?(Prism::CallNode) && child.name.to_s == "define_method"
        child.child_nodes.each { |nested| walk.call(nested) if nested } unless found
      end
      walk.call(node.body)
      found
    end

    def closed_attribute_macro_call(node)
      macro = node.name.to_s
      if macro == "undef_method"
        args = node.arguments&.arguments || []
        return nil unless args.length == 1 && args.first.is_a?(Prism::SymbolNode)
        return "" if %w[lifecycle_attr flow_attr].include?(args.first.value.to_s)
      end
      return nil unless @current_class == "SymbolEntry"
      return nil unless %w[lifecycle_attr flow_attr].include?(macro)

      args = node.arguments&.arguments || []
      return unsupported_expression(node, "#{macro} requires one literal symbol") unless
        args.length == 1 && args.first.is_a?(Prism::SymbolNode)

      field = args.first.value.to_s
      facts_type = macro == "lifecycle_attr" ? "BindingLifecycleFacts" : "BindingFlowFacts"
      storage_field = macro == "lifecycle_attr" ? "lifecycle" : "flow"
      field_type = @class_instance_field_types[facts_type][field] || untyped_type
      @class_instance_method_names[@current_class] << clear_function_name(field)
      @current_instance_method_names << clear_function_name(field)
      getter_name = instance_function_name(@current_class, field)
      getter_value = if direct_retained_carrier_type?(field_type)
        "KEEP self.#{storage_field}.#{field}"
      else
        "self.#{storage_field}.#{field}"
      end
      getter = "PUB FN #{getter_name}(self: SymbolEntry) RETURNS #{field_type} ->\n" \
        "  #{getter_value};\nEND"
      return getter if macro == "flow_attr"
      return getter if field == "type"

      @class_instance_method_names[@current_class] << clear_function_name("#{field}=")
      @current_instance_method_names << clear_function_name("#{field}=")
      setter_value = if direct_retained_carrier_type?(field_type)
        "KEEP value"
      elsif copyable_storage_type?(field_type)
        "COPY value"
      else
        "value"
      end
      setter_name = instance_function_name(@current_class, "#{field}=")
      setter = "PUB FN #{setter_name}(MUTABLE self: SymbolEntry, value: #{field_type}) RETURNS #{field_type} ->\n" \
        "  self.#{storage_field}.#{field} = #{setter_value};\n  #{setter_value};\nEND"
      "#{getter}\n#{setter}"
    end

    def function_rescue_plan(body_node)
      return nil unless body_node.is_a?(Prism::BeginNode)
      unless body_node.rescue_clause
        body = body_node.statements&.body || []
        nested = body.last
        return nil unless nested.is_a?(Prism::BeginNode) && nested.rescue_clause
        return nil if nested.ensure_clause || nested.else_clause

        plan = rescue_plan_for_begin(nested)
        return nil unless plan

        plan[:body] = body[0...-1] + Array(plan[:body])
        outer_ensure = body_node.ensure_clause&.statements&.body || []
        plan[:ensure] = Array(plan[:ensure]) + outer_ensure
        return plan
      end

      rescue_plan_for_begin(body_node)
    end

    def rescue_plan_for_begin(body_node)
      return nil if body_node.else_clause

      clauses = []
      clause = body_node.rescue_clause
      while clause
        exceptions = clause.exceptions || []
        catch_all = exceptions.empty? || exceptions.all? { |exception| static_exception_name?(exception) }
        typed_names = exceptions.filter_map { |exception| rescue_exception_type_name(exception) }
        return nil unless catch_all || typed_names.length == exceptions.length

        binding = clause.reference.name.to_s if clause.reference&.respond_to?(:name)
        # An error binding is only supported when the handler never reads it:
        # CLEAR CATCH arms carry kind/type/message filters, not a bound error
        # value. Handlers that inspect the exception object stay unsupported.
        return nil if binding && statements_reference_local?(clause.statements, binding)

        clauses << {
          catch_all: catch_all,
          types: catch_all ? [] : typed_names,
          fallback: clause.statements&.body || [],
        }
        clause = clause.subsequent
      end
      return nil if clauses.empty?

      {
        body: body_node.statements&.body || [],
        clauses: clauses,
        # Legacy single-clause fields, still consumed by trailing-begin OR_ELSE paths.
        fallback: clauses.fetch(0).fetch(:fallback),
        binding: nil,
        ensure: body_node.ensure_clause&.statements&.body || [],
      }
    end

    # A rescued exception class maps to a CLEAR error TYPE by its last
    # name segment (the RAISE translation registers the same name).
    def rescue_exception_type_name(node)
      return nil unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      name = node.location.slice.strip.split("::").last.to_s
      return nil if name.empty? || %w[StandardError Exception].include?(name)

      name
    end

    def statements_reference_local?(statements_node, name)
      found = false
      walk = lambda do |current|
        return if found || !current.is_a?(Prism::Node)

        found = true if current.is_a?(Prism::LocalVariableReadNode) && current.name.to_s == name
        current.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(statements_node)
      found
    end

    def render_rescue_plan_nodes(nodes)
      visit_statement_list(Array(nodes))
    end

    # Only exception classes that mean "any error" may lower to CLEAR's
    # full CATCH taxonomy. A typed rescue (rescue ParseError) carries a
    # dispatch filter that the catch-all would silently widen away.
    def static_exception_name?(node)
      return false unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      %w[StandardError Exception].include?(node.location.slice.strip.split("::").last)
    end

    def function_effects_suffix(node)
      if declaration_comment?(node, "ruby-to-clear: effects reentrant-tail-call")
        return " EFFECTS REENTRANT:TAIL_CALL"
      end
      return " EFFECTS REENTRANT" if declaration_comment?(node, "ruby-to-clear: effects reentrant")
      if @current_class && @class_reentrant_instance_method_names[@current_class].include?(node.name.to_s)
        return " EFFECTS REENTRANT"
      end
      return " EFFECTS REENTRANT" if recursive_method_call?(node.body, node.name.to_s)

      ""
    end

    def fallible_return_type(ret_type)
      return ret_type if ret_type.start_with?("!")
      return ret_type if ret_type == "Auto"

      "!#{ret_type}"
    end

    def visit_block_argument_node(node)
      "&#{visit(node.expression)}"
    end

    def visit_multi_write_node(node)
      target_names = validated_multi_write_target_names(node)
      return target_names if target_names.is_a?(String)

      assign_multi_write_target_types!(target_names, node.value)
      first_new_target = multi_write_first_new_target?(target_names)
      target_code = multi_write_target_codes(target_names, first_new_target)
      prefix = first_new_target ? "MUTABLE " : ""
      "#{prefix}#{target_code.join(', ')} = #{visit(node.value)}"
    end

    def validated_multi_write_target_names(node)
      if node.respond_to?(:rest) && node.rest
        return raise_unsupported("Destructuring rest targets are not supported", node)
      end

      if node.respond_to?(:rights) && node.rights.any?
        return raise_unsupported("Destructuring post targets are not supported", node)
      end

      if node.value.is_a?(Prism::ArrayNode) && node.value.elements.any? { |element| element.is_a?(Prism::SplatNode) }
        return raise_unsupported("Destructuring splat values are not supported", node)
      end

      if node.value.is_a?(Prism::ArrayNode) && node.lefts.length != node.value.elements.length
        return raise_unsupported("Multi-write left and right side lengths must match", node)
      end

      target_names = multi_write_target_names(node)
      unless target_names
        return raise_unsupported("Destructuring targets must be local variables or _", node)
      end

      target_names
    end

    # Destructuring `a, b = tuple_value` must give each target the tuple's
    # element type; otherwise downstream inference (e.g. `b || default`) sees an
    # untyped local and picks the wrong lowering (boolean OR vs OR_ELSE).
    def assign_multi_write_target_types!(target_names, value_node)
      value_type = inferred_clear_type(value_node).to_s.delete_prefix("?")
      return unless value_type.start_with?("Tuple<") && value_type.end_with?(">")

      element_types = split_top_level_clear_list(value_type.delete_prefix("Tuple<").delete_suffix(">"))
      return unless element_types.length == target_names.length

      target_names.each_with_index do |name, index|
        next if name == "_" || @declared_locals.include?(name)

        element_type = element_types[index].to_s.strip
        @local_types[name] = element_type unless element_type.empty? || %w[Any Auto].include?(element_type)
      end
    end

    def multi_write_target_codes(target_names, first_new_target)
      target_names.each_with_index.map do |name, index|
        multi_write_target_code(name, index, first_new_target)
      end
    end

    def multi_write_target_code(name, index, first_new_target)
      return "_" if name == "_"

      if @declared_locals.include?(name)
        name
      else
        @declared_locals << name
        @local_shapes[name] = nil
        index.zero? || first_new_target ? name : "MUTABLE #{name}"
      end
    end

    def multi_write_first_new_target?(target_names)
      target_names.first != "_" && !@declared_locals.include?(target_names.first)
    end

    def multi_write_target_names(node)
      target_names = node.lefts.map { |target| multi_write_target_name(target) }
      return nil if target_names.any?(&:nil?)

      target_names
    end

    def multi_write_target_name(target)
      return target.name.to_s if target.is_a?(Prism::LocalVariableTargetNode)

      nil
    end

    def visit_rescue_node(node)
      return unsupported_expression(node, "multiple rescue clauses are not supported") if node.subsequent

      node.statements ? visit(node.statements) : "NIL"
    end

    # `begin BODY ensure CLEANUP end` (and the method-level `def m ... ensure`
    # form, which Prism also parses as a BeginNode) maps to CLEAR's DEFER:
    # the cleanup runs at scope exit on BOTH the success and error paths,
    # exactly Ruby's ensure contract. Placement: the DEFER is inserted after
    # the last body statement that ASSIGNS a local the cleanup reads (the
    # save/set/call/restore idiom binds `prev` first), so the deferred
    # restore never references an unbound name.
    def translate_ensure_only_begin(node, returning: false, binding: nil)
      body_stmts = node.statements&.body || []
      ensure_stmts = node.ensure_clause.statements&.body || []
      referenced = ensure_referenced_local_names(ensure_stmts)
      split = 0
      body_stmts.each_with_index do |stmt, i|
        split = i + 1 if stmt.is_a?(Prism::LocalVariableWriteNode) && referenced.include?(stmt.name.to_s)
      end

      pieces = []
      body_stmts.first(split).each { |stmt| pieces << statement_code(visit(stmt)) }
      # Cleanup expressions are always statements, even when the surrounding
      # Ruby method returns a value. Without the nested statement-list depth,
      # a final IF/call in an ensure clause can be rendered as RETURN inside
      # CLEAR's DEFER body, which is both semantically wrong and rejected by
      # the parser.
      old_function_statement_list_depth = @function_statement_list_depth
      @function_statement_list_depth = old_function_statement_list_depth + 1
      begin
        deferred = ensure_stmts.map { |stmt| statement_code(visit(stmt)) }.reject(&:empty?)
      ensure
        @function_statement_list_depth = old_function_statement_list_depth
      end
      pieces << if deferred.length == 1
        "DEFER #{deferred.first}"
      else
        "DEFER {\n#{deferred.join("\n")}\n}"
      end
      rest = body_stmts.drop(split)
      if returning
        rest[0...-1].to_a.each { |stmt| pieces << statement_code(visit(stmt)) }
        last = rest.last
        pieces << if last
          render_returning_statement(last)
        else
          "RETURN #{wrap_argument_for_parameter_type("NIL", node, @current_function_return_type)};"
        end
      elsif binding
        # `x = begin ... ensure cleanup end`: the DEFER covers the body,
        # and the body's value expression binds to the local.
        rest[0...-1].to_a.each { |stmt| pieces << statement_code(visit(stmt)) }
        value = rest.last ? visit(rest.last) : "NIL"
        pieces << if @declared_locals.include?(binding)
          "#{binding} = #{value};"
        else
          @declared_locals << binding
          "MUTABLE #{binding} = #{value};"
        end
      else
        rest.each { |stmt| pieces << statement_code(visit(stmt)) }
      end
      pieces.reject(&:empty?).join("\n")
    end

    def ensure_referenced_local_names(ensure_stmts)
      names = Set.new
      walk = lambda do |current|
        return unless current.is_a?(Prism::Node)

        names << current.name.to_s if current.is_a?(Prism::LocalVariableReadNode)
        current.child_nodes.each { |child| walk.call(child) if child }
      end
      ensure_stmts.each { |stmt| walk.call(stmt) }
      names
    end

    def visit_rescue_modifier_node(node)
      if sorbet_call?(node.expression, "bind")
        return ""
      end

      # Ruby's modifier form (`value rescue fallback`) is the common
      # expression-level recovery idiom. CLEAR's OR_ELSE operator has the same
      # value semantics and preserves the error for the surrounding function.
      expression = visit(node.expression)
      fallback = visit(node.rescue_expression)
      "(#{expression} OR_ELSE #{fallback})"
    end

    def visit_begin_node(node)
      if node.ensure_clause && !node.rescue_clause
        # A def-level `... ensure ...` body arrives here as the function's
        # whole body node, bypassing visit_statement_list's implicit-return
        # handling — apply the same trigger for the last body statement.
        returning = @inside_function && @function_statement_list_depth.to_i.zero? &&
                    @current_function_returns_value
        return translate_ensure_only_begin(node, returning: !!returning)
      end

      if node.rescue_clause
        clause = node.rescue_clause
        exceptions = clause.exceptions || []
        catch_all = exceptions.empty? || exceptions.all? { |exception| static_exception_name?(exception) }
        if catch_all && clause.reference.nil? && clause.subsequent.nil? &&
           node.ensure_clause.nil? && node.else_clause.nil?
          body = case_arm_value_code(node.statements) || "NIL"
          fallback = case_arm_value_code(clause.statements) || "NIL"
          return "(#{body} OR_ELSE #{fallback})"
        end
        if catch_all && clause.reference.nil? && clause.subsequent.nil? &&
           node.ensure_clause.nil? && node.else_clause.nil? &&
           (clause.statements.nil? || clause.statements.body.empty?)
          return visit(node.statements)
        end
        return raise_unsupported("Complex exception handling (rescue) is not supported", node)
      else
        visit(node.statements)
      end
    end

    def format_consequent(consequent_node, else_context = nil)
      if else_context
        return with_runtime_is_a_else_context(else_context) do
          format_consequent(consequent_node)
        end
      end

      if consequent_node.is_a?(Prism::IfNode)
        runtime_is_a = runtime_is_a_predicate(consequent_node.predicate)
        pred = if runtime_is_a
          "#{runtime_is_a[:receiver_code]} IS_A #{runtime_is_a[:expected_type]} AS #{runtime_is_a[:binding_name]}"
        else
          predicate_code(consequent_node.predicate)
        end
        body = with_indent do
          if runtime_is_a
            with_narrowing_context(runtime_is_a) { visit(consequent_node.statements) }
          else
            visit(consequent_node.statements)
          end
        end
        body = statement_code(body) unless body.empty? || body.rstrip.end_with?("END")
        nested = consequent_node.consequent ? format_consequent(consequent_node.consequent, runtime_is_a) : ""
        "\nELSE_IF #{pred} THEN\n#{body}#{nested}"
      else
        body = with_indent { visit(consequent_node) }
        "\nELSE\n#{body}"
      end
    end

    def collect_instance_fields(node)
      fields = {}
      root_node = node
      method_param_types = {}
      last_sig = nil
      (node.body&.body || []).each do |stmt|
        if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
          last_sig = stmt
          next
        end
        if stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && last_sig
          method_param_types[stmt.object_id] = parse_sig(last_sig).first
        end
        last_sig = nil
      end

      walk = ->(n, in_instance_method = false, param_types = {}) do
        next unless n

        if n.is_a?(Prism::SingletonClassNode)
          next
        elsif n != root_node && (n.is_a?(Prism::ClassNode) || n.is_a?(Prism::ModuleNode))
          next
        elsif n != root_node && n.is_a?(Prism::ConstantWriteNode) && struct_new_field_names(n.value)
          next
        elsif n.is_a?(Prism::DefNode)
          next if n.receiver

          n.child_nodes.each { |child| walk.call(child, true, method_param_types.fetch(n.object_id, {})) if child }
          next
        elsif in_instance_method && n.is_a?(Prism::InstanceVariableReadNode)
          fields[n.name.to_s.delete_prefix("@")] ||= "Any"
        elsif in_instance_method && n.is_a?(Prism::InstanceVariableWriteNode)
          name = n.name.to_s.delete_prefix("@")
          inferred_type = inferred_field_type_from_value(n.value)
          if inferred_type == "Any" && n.value.is_a?(Prism::LocalVariableReadNode)
            inferred_type = param_types[n.value.name.to_s] || inferred_type
          end
          existing_type = fields[name]
          fields[name] = if inferred_type == "Any"
            existing_type || "Any"
          elsif inferred_type == "Set" && existing_type.to_s.end_with?("[]@set")
            existing_type
          elsif existing_type
            unify_field_types(existing_type, inferred_type)
          else
            inferred_type
          end
        elsif !in_instance_method && n.is_a?(Prism::CallNode) && n.receiver.nil? &&
              %w[attr_reader attr_accessor attr_writer].include?(n.name.to_s)
          (n.arguments&.arguments || []).each do |argument|
            fields[argument.value.to_s] ||= "Any" if argument.is_a?(Prism::SymbolNode)
          end
        end
        n.child_nodes.each { |child| walk.call(child, in_instance_method, param_types) if child }
      end
      walk.call(node)
      if node.respond_to?(:location) && node.location
        node.location.slice.scan(
          /#\s*ruby-to-clear:\s*field-type\s+([A-Za-z_]\w*)\s*=\s*([^\s#]+)/
        ).each do |field, type|
          fields[field] = type if fields.key?(field)
        end
      end
      fields.sort.to_h
    end

    def unify_field_types(t1, t2)
      return t1 if t2.to_s == "Any"
      return t2 if t1.to_s == "Any"

      strip_cap = ->(t) {
        return t.to_s if t.to_s.end_with?("@symbol")
        depth = 0
        t.to_s.each_char.with_index do |char, index|
          depth += 1 if "<[(".include?(char)
          depth -= 1 if ">])".include?(char)
          return t[0...index] if char == "@" && depth.zero?
        end
        t.to_s
      }

      b1 = strip_cap.call(t1.to_s.delete_prefix("?"))
      b2 = strip_cap.call(t2.to_s.delete_prefix("?"))

      if b1 == b2
        optional = t1.to_s.start_with?("?") || t2.to_s.start_with?("?")
        cap = [t1.to_s, t2.to_s].find { |t| t.include?("@") }
        suffix = cap ? "@" + cap.split("@", 2).last : ""
        res = b1
        res += suffix unless b1.end_with?(suffix)
        optional ? "?#{res}" : res
      else
        t2
      end
    end

    def collect_instance_method_names(node)
      collect_instance_method_names_from_body_nodes(node.body&.body || [])
    end

    def collect_instance_method_names_from_body_nodes(body_nodes)
      body_nodes.each_with_object(Set.new) do |stmt, names|
        if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? &&
           %w[lifecycle_attr flow_attr].include?(stmt.name.to_s)
          arg = stmt.arguments&.arguments&.first
          if arg.is_a?(Prism::SymbolNode)
            field = arg.value.to_s
            names << clear_function_name(field)
            names << clear_function_name("#{field}=") if stmt.name.to_s == "lifecycle_attr"
          end
          next
        end
        next unless stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?

        names << clear_function_name(stmt.name.to_s)
      end
    end

    def collect_mutating_instance_method_names(node)
      collect_mutating_instance_method_names_from_body_nodes(node.body&.body || [])
    end

    def collect_mutating_instance_method_names_from_body_nodes(body_nodes)
      method_bodies = body_nodes.each_with_object({}) do |stmt, methods|
        next unless stmt.is_a?(Prism::DefNode)
        next if stmt.receiver

        methods[stmt.name.to_s] = stmt.body
      end

      mutating = method_bodies.each_with_object(Set.new) do |(name, body), names|
        names << name if name == "initialize" || directly_mutates_instance_state?(body)
      end

      changed = true
      while changed
        changed = false
        method_bodies.each do |name, body|
          next if mutating.include?(name)
          next unless calls_mutating_instance_method?(body, mutating)

          mutating << name
          changed = true
        end
      end

      mutating
    end

    def collect_class_method_names(node)
      body_nodes = node.body&.body || []
      body_nodes.each_with_object(Set.new) do |stmt, names|
        if stmt.is_a?(Prism::DefNode) && stmt.receiver.is_a?(Prism::SelfNode)
          names << clear_function_name(stmt.name.to_s)
        elsif stmt.is_a?(Prism::SingletonClassNode) && stmt.expression.is_a?(Prism::SelfNode)
          (stmt.body&.body || []).each do |singleton_stmt|
            next unless singleton_stmt.is_a?(Prism::DefNode) && singleton_stmt.receiver.nil?

            names << clear_function_name(singleton_stmt.name.to_s)
          end
        end
      end
    end

    def preload_class_instance_metadata(node, current_class = nil)
      return unless node

      if node.is_a?(Prism::ModuleNode)
        raw_module_name = node.constant_path.location.slice.strip
        module_name = if current_class && !raw_module_name.include?("::")
          "#{current_class}::#{raw_module_name}"
        else
          raw_module_name
        end
        @module_function_names[module_name].merge(collect_class_method_names(node))
        node.child_nodes.each { |child| preload_class_instance_metadata(child, module_name) if child }
        return
      end

      if node.is_a?(Prism::ClassNode)
        raw_class_name = node.constant_path.location.slice.strip
        class_name = if current_class && !raw_class_name.include?("::")
          "#{current_class}::#{raw_class_name}"
        else
          raw_class_name
        end
        body_nodes = node.body&.body || []
        fields = if t_struct_class?(node)
          body_nodes.filter_map { |stmt| t_struct_field(stmt) }.to_h { |field, type, _default| [field, concrete_struct_type(type)] }
        elsif struct_new_superclass?(node.superclass)
          struct_new_field_names(node.superclass).to_h { |field| [field, "Any"] }
        else
          with_current_class(class_name) { collect_instance_fields(node) }
        end

        fields.each do |field, type|
          @class_instance_field_names[class_name] << field
          merge_class_instance_field_type(class_name, field, type)
        end
        @class_instance_method_names[class_name].merge(collect_instance_method_names(node))
        @class_class_method_names[class_name].merge(collect_class_method_names(node))
        @class_mutating_instance_method_names[class_name].merge(collect_mutating_instance_method_names(node))

        node.child_nodes.each { |child| preload_class_instance_metadata(child, class_name) if child }
        return
      end

      node.child_nodes.each { |child| preload_class_instance_metadata(child, current_class) if child }
    end

    def duplicate_instance_method_names(node)
      classes_by_method = Hash.new { |hash, key| hash[key] = Set.new }
      @class_instance_method_names.each do |class_name, names|
        names.each { |name| classes_by_method[name] << class_name }
      end

      walk = ->(n, current_class = nil) do
        next unless n

        if n.is_a?(Prism::ClassNode)
          class_name = n.constant_path.location.slice.strip
          n.child_nodes.each { |child| walk.call(child, class_name) if child }
          next
        end

        if n.is_a?(Prism::ConstantWriteNode) && struct_new_field_names(n.value)
          class_name = n.name.to_s
          body_nodes = n.value.block&.body&.body || []
          collect_instance_method_names_from_body_nodes(body_nodes).each do |method_name|
            classes_by_method[method_name] << class_name
          end
          next
        end

        if current_class && n.is_a?(Prism::DefNode) && !n.receiver
          clear_name = clear_function_name(n.name.to_s)
          classes_by_method[clear_name] << current_class
          next
        end

        n.child_nodes.each { |child| walk.call(child, current_class) if child }
      end
      walk.call(node)
      classes_by_method.each_with_object(Set.new) do |(name, classes), duplicates|
        duplicates << name if classes.size > 1
      end
    end

    def class_function_prefix(class_name)
      flat_name = class_name.to_s.split("::").last
      prefix = flat_name.gsub(/[^A-Za-z0-9_]/, "_")
      prefix[0] = prefix[0].downcase if prefix[0]
      prefix
    end

    def class_method_function_name(class_name, method_name)
      clear_name = clear_function_name(method_name)
      prefix = class_function_prefix(class_name)
      instance_names = @class_instance_method_names[class_name.to_s]
      if instance_names&.include?(clear_name)
        "#{prefix}__class_#{clear_name}"
      else
        "#{prefix}__#{clear_name}"
      end
    end

    def instance_function_name(class_name, method_name)
      class_name = resolve_qualified_class_name(class_name) || class_name
      raw_name = method_name.to_s
      clear_name = clear_function_name(raw_name)
      "#{class_function_prefix(class_name)}__#{clear_name}"
    end

    def registry_receiver_kind(receiver)
      case receiver
      when nil then "implicit"
      when Prism::SelfNode then "self"
      when Prism::LocalVariableReadNode then "local"
      when Prism::InstanceVariableReadNode then "ivar"
      when Prism::ClassVariableReadNode then "class_var"
      when Prism::GlobalVariableReadNode then "global"
      when Prism::ConstantReadNode then "constant"
      when Prism::ConstantPathNode then "constant_path"
      when Prism::CallNode then "call_result"
      when Prism::ParenthesesNode then "parenthesized"
      when Prism::StringNode, Prism::InterpolatedStringNode then "string_literal"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "symbol_literal"
      when Prism::IntegerNode, Prism::FloatNode then "numeric_literal"
      when Prism::ArrayNode then "array_literal"
      when Prism::HashNode then "hash_literal"
      when Prism::NilNode then "nil_literal"
      when Prism::TrueNode, Prism::FalseNode then "bool_literal"
      else receiver.class.name.split("::").last
      end
    end

    def typed_instance_method_call(receiver_type, method_name, receiver_code)
      owner = instance_method_owner_type(receiver_type, clear_function_name(method_name))
      return nil unless owner

      receiver_code = mutable_argument_code(receiver_code) if mutating_instance_method?(owner, method_name)
      "#{instance_function_name(owner, method_name)}(#{receiver_code})"
    end
    public :typed_instance_method_call

    def unique_instance_method_owner(clear_name)
      owners = @class_instance_method_names.filter_map do |class_name, methods|
        class_name if methods.include?(clear_name)
      end
      owners.uniq.one? ? owners.first : nil
    end
    public :unique_instance_method_owner

    def mutating_instance_method?(owner, method_name)
      resolved_owner = resolve_qualified_class_name(owner) || owner.to_s
      raw_name = method_name.to_s
      clear_name = clear_function_name(raw_name)
      @class_mutating_instance_method_names[resolved_owner].include?(raw_name) ||
        @class_mutating_instance_method_names[resolved_owner].include?(clear_name)
    end
    public :mutating_instance_method?

    def registry_receiver_name(receiver)
      return nil unless receiver

      if receiver.is_a?(Prism::LocalVariableReadNode)
        name = receiver.name.to_s
        renamed = @renames[name]
        renamed && static_clear_type_for_receiver(renamed) ? renamed : name
      elsif receiver.respond_to?(:full_name)
        receiver.full_name.delete_prefix("::")
      elsif receiver.respond_to?(:name)
        receiver.name.to_s
      end
    rescue StandardError
      nil
    end

    def registry_receiver_shape(receiver)
      return nil unless receiver

      case receiver
      when Prism::ArrayNode
        "array"
      when Prism::HashNode, Prism::KeywordHashNode
        "hash"
      when Prism::StringNode, Prism::InterpolatedStringNode
        "string"
      when Prism::SymbolNode
        "symbol"
      when Prism::IntegerNode, Prism::FloatNode
        "numeric"
      when Prism::NilNode
        "nil"
      when Prism::TrueNode, Prism::FalseNode
        "bool"
      when Prism::LocalVariableReadNode
        name = receiver.name.to_s
        renamed = @renames[name]
        renamed_shape = renamed && (@local_shapes[renamed] || clear_type_shape(static_clear_type_for_receiver(renamed)))
        renamed_shape || @local_shapes[name] || clear_type_shape(static_clear_type_for_receiver(name))
      else
        inferred_shape(receiver)
      end
    end

    def comment_unsupported(node)
      unsupported_comment(node)
    end

    def unsupported_comment(node, message = nil)
      node_name = node.class.name.split("::").last
      loc = node.location
      source_loc = "#{@source[0...loc.start_offset].count("\n") + 1}:#{loc.start_column}"
      slice = node.location.slice
      lines = slice.split("\n")
      header = "# [UNSUPPORTED: #{node_name} at #{source_loc}]"
      header = "#{header} #{message}" if message
      commented_lines = [header]
      lines.each do |line|
        commented_lines << "# #{line}"
      end
      commented_lines.map { |l| "#{indent}#{l}" }.join("\n")
    end

    def unsupported_expression(node, message)
      return raise_unsupported(message, node) if @raise_on_error

      node_name = node.class.name.split("::").last
      loc = node.location
      source_loc = "#{@source[0...loc.start_offset].count("\n") + 1}:#{loc.start_column}"
      encoded = "#{node_name} at #{source_loc}: #{message}".dump
      "unsupportedRuby(#{encoded})"
    end
    public :unsupported_expression

    def unsupported_gsub_sub_reason(node)
      args = node.arguments ? node.arguments.arguments : []
      if node.block || args.length != 2
        "#{node.name} with block or invalid arguments is not supported"
      end
    end

    def literal_replacement_block_expression(block)
      return nil unless block.is_a?(Prism::BlockNode)
      return nil if block.parameters&.parameters&.child_nodes&.compact&.any?

      statements = block.body
      return nil unless statements.is_a?(Prism::StatementsNode) && statements.body.length == 1

      expression = statements.body.first
      return nil unless literal_replacement_expression?(expression)

      visit(expression)
    end

    def literal_replacement_expression?(node)
      case node
      when Prism::StringNode, Prism::LocalVariableReadNode
        true
      when Prism::InterpolatedStringNode
        node.parts.all? { |part| literal_replacement_expression?(part) }
      when Prism::EmbeddedStatementsNode
        statements = node.statements
        statements.is_a?(Prism::StatementsNode) && statements.body.length == 1 &&
          literal_replacement_expression?(statements.body.first)
      else
        false
      end
    end

    def private_class_method_def_call?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver.nil? && node.name.to_s == "private_class_method"

      args = node.arguments&.arguments || []
      args.length == 1 && args.first.is_a?(Prism::DefNode)
    end

    def private_class_method_names(node)
      return [] unless node.is_a?(Prism::CallNode)
      return [] unless node.receiver.nil? && node.name.to_s == "private_class_method"

      args = node.arguments&.arguments || []
      return [] if args.any? { |arg| arg.is_a?(Prism::DefNode) }

      args.filter_map do |arg|
        arg.value.to_s if arg.is_a?(Prism::SymbolNode)
      end
    end

    # `public :name` after a def re-exports it from a private section.
    def declared_public_method_names(stmt)
      return [] unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name.to_s == "public"

      (stmt.arguments&.arguments || []).filter_map do |arg|
        arg.unescaped if arg.is_a?(Prism::SymbolNode)
      end
    end

    def visibility_section_call?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver.nil?
      return false unless ["private", "protected", "public"].include?(node.name.to_s)

      args = node.arguments&.arguments || []
      args.empty?
    end

    def ruby_scaffolding_call?(node)
      return false unless node.is_a?(Prism::CallNode)

      name = node.name.to_s
      return true if node.receiver.nil? && ["require", "require_relative", "private", "public", "protected", "private_constant", "public_constant", "attr_reader", "attr_accessor", "attr_writer"].include?(name)
      return true if node.receiver.nil? && name == "private_class_method" && private_class_method_names(node).any?

      if name == "extend" && node.receiver.nil?
        args = node.arguments ? node.arguments.arguments : []
        return true if args.length == 1 && ["T::Sig", "T::Helpers", "T::Generic"].include?(args.first.location.slice.strip)
      end

      return true if node.receiver.nil? && %w[requires_ancestor interface! abstract! final! sealed!].include?(name)

      false
    end

    def ruby_scaffolding_conditional?(node)
      return false unless node.respond_to?(:statements)
      return false if node.consequent

      statements = node.statements
      return false unless statements.is_a?(Prism::StatementsNode)
      return false if statements.body.empty?

      statements.body.all? { |stmt| ruby_scaffolding_call?(stmt) }
    end

    def block_statement_output?(code)
      stripped = code.lstrip
      # A multi-line value-block declaration (`decl = { ... };`, or any
      # bracketed RHS spanning multiple lines) may precede the trailing
      # block keyword; checked first because the single-line-only checks
      # below would otherwise return false as soon as they see this
      # declaration's own first line has an unclosed delimiter, without
      # ever looking past it to the trailing block that follows.
      return true if multiline_prefixed_block_output?(stripped)
      if stripped.match?(/\A(?:MUTABLE\s+)?[A-Za-z_]\w*(?:\s*:\s*[^=]+)?\s*=/) &&
         first_line_has_open_expression_delimiter?(stripped)
        return false
      end
      return false if stripped.match?(/\A(?:MUTABLE\s+)?[A-Za-z_]\w*(?:\s*:\s*[^=]+)?\s*=/) && stripped.rstrip.end_with?("END)")
      return true if stripped.start_with?("IF ", "COMPTIME IF ") && !expression_if_output?(stripped)
      return true if stripped.start_with?("WHILE ", "FOR ", "MATCH ", "PARTIAL MATCH ", "TEST ", "WHEN ")
      return true if stripped.start_with?("FN ", "PRIVATE FN ", "PUB FN ", "STRUCT ", "UNION ", "ENUM ")
      return true if stripped.start_with?("PUB STRUCT ", "PUB UNION ", "PUB ENUM ")
      # One OR MORE simple `decl = ...;` lines may precede the block keyword
      # (reverse_each emits items + index declarations before its WHILE).
      return true if stripped.match?(/\A(?:(?:MUTABLE\s+)?[A-Za-z_]\w*(?:\s*:\s*[^=\n]+)?\s*=[^\n]*;\n\s*)+(?:IF|COMPTIME IF|WHILE|FOR|MATCH|PARTIAL MATCH|TEST|WHEN|(?:PUB\s+)?FN) /)

      false
    end

    # Peels off zero-or-more leading `decl = value;` statements - single-line
    # (`x = 1;`) or multi-line with a bracketed value (`x = { ... };`,
    # `x = (\n  ...\n);`) - and checks whether what remains after the last
    # one is a trailing block-keyword statement. Consumes at least one
    # declaration; a bare block keyword with nothing preceding it is handled
    # by the existing start_with? checks in block_statement_output?, not here.
    def multiline_prefixed_block_output?(stripped)
      pos = 0
      consumed_any = false
      loop do
        remainder = stripped[pos..]
        break if remainder.nil? || remainder.empty?

        if (m = remainder.match(/\A(?:MUTABLE\s+)?[A-Za-z_]\w*(?:\s*:\s*[^=\n]+)?\s*=[^\n]*;\n\s*/)) &&
           !first_line_has_open_expression_delimiter?(m[0].lines.first.to_s)
          pos += m[0].length
          consumed_any = true
          next
        end

        if (m = remainder.match(/\A(?:MUTABLE\s+)?[A-Za-z_]\w*(?:\s*:\s*[^=\n]+)?\s*=\s*(?=[({\[])/)) &&
           (close_at = quote_aware_bracket_end(remainder, m[0].length)) &&
           (semi = remainder[close_at..].to_s.match(/\A;\n\s*/))
          pos += close_at + semi[0].length
          consumed_any = true
          next
        end

        break
      end

      return false unless consumed_any

      trailing = stripped[pos..].to_s
      return false if trailing.empty?

      return true if trailing.start_with?("IF ", "COMPTIME IF ") && !expression_if_output?(trailing)
      return true if trailing.start_with?("WHILE ", "FOR ", "MATCH ", "PARTIAL MATCH ", "TEST ", "WHEN ")
      return true if trailing.start_with?("FN ", "PRIVATE FN ", "PUB FN ", "STRUCT ", "UNION ", "ENUM ")
      return true if trailing.start_with?("PUB STRUCT ", "PUB UNION ", "PUB ENUM ")

      false
    end

    # Finds the index just past the delimiter that closes the bracket at
    # text[start_index] (which must be one of `([{`), tracking nested
    # depth and skipping quoted content. Returns nil if unbalanced. Distinct
    # from balanced_delimiter_end above: that one tracks a single opener/
    # closer pair with no quote-awareness; this tracks all of `([{`/`)]}`
    # together and must skip over string-literal content in a value block.
    def quote_aware_bracket_end(text, start_index)
      depth = 0
      quote = nil
      escaped = false
      i = start_index
      while i < text.length
        char = text[i]
        if quote
          if escaped
            escaped = false
          elsif char == "\\"
            escaped = true
          elsif char == quote
            quote = nil
          end
          i += 1
          next
        end

        if char == '"' || char == "'"
          quote = char
        elsif "([{".include?(char)
          depth += 1
        elsif ")]}".include?(char)
          depth -= 1
          return i + 1 if depth.zero?
        end
        i += 1
      end
      nil
    end

    def first_line_has_open_expression_delimiter?(code)
      depth = 0
      quote = nil
      escaped = false
      code.lines.first.to_s.each_char do |char|
        if quote
          if escaped
            escaped = false
          elsif char == "\\"
            escaped = true
          elsif char == quote
            quote = nil
          end
          next
        end

        if char == '"' || char == "'"
          quote = char
        elsif "([{".include?(char)
          depth += 1
        elsif ")]}".include?(char)
          depth -= 1 if depth.positive?
        end
      end
      depth.positive?
    end

    def expression_if_output?(stripped)
      return false unless stripped.start_with?("IF ", "COMPTIME IF ")

      lines = stripped.lines.map(&:strip).reject(&:empty?)
      return false unless lines.last == "END"

      payload_lines = lines[1...-1].reject { |line| line.start_with?("ELSE", "ELSE_IF") }
      return false if payload_lines.empty?

      payload_lines.all? { |line| expression_if_payload_line?(line) }
    end

    def expression_if_payload_line?(line)
      return false if line.end_with?(";")
      return false if line == "END"
      return false if line.start_with?("RETURN", "RAISE", "BREAK", "CONTINUE")
      return false if line.start_with?("IF ", "COMPTIME IF ", "WHILE ", "MATCH ", "PARTIAL MATCH ")
      return false if line.end_with?("{")
      return false if line.match?(/\A(?:MUTABLE\s+)?[A-Za-z_]\w*(?:\s*:\s*[^=]+)?\s*=/)

      true
    end

    def ruby_raise_call?(node)
      return false unless node.name.to_s == "raise"
      return true if node.receiver.nil?

      node.receiver.location.slice.strip == "Kernel"
    end

    # Programmer-error classes stay panics: they signal bugs, not conditions
    # a caller recovers from (Zig: unreachable/panic; CLEAR: `!!`).
    RAISE_PANIC_CLASSES = %w[
      ArgumentError TypeError RuntimeError NotImplementedError StandardError
      Exception KeyError IndexError FrozenError NoMethodError
    ].freeze

    def ruby_raise_code(node)
      # Ruby exceptions are source-visible failure paths. Preserve that fact
      # in the generated signature so CLEAR callers must propagate or handle
      # them instead of receiving an apparently total function that panics.
      mark_current_function_fallible! if @inside_function
      # A TYPED raise of a domain error class maps onto CLEAR's recoverable
      # error channel — `RAISE Input, <Type>, msg` — so the class survives as
      # the CATCH-able error type. Untyped raises and programmer-error
      # classes remain panics.
      if (error_type = ruby_raise_error_type(node))
        return "RAISE Input, #{error_type}, #{ruby_raise_message_code(node)}"
      end
      "panic(#{ruby_raise_message_code(node)})"
    end

    def ruby_raise_error_type(node)
      args = node.arguments ? node.arguments.arguments : []
      first = args.first
      return nil unless first

      const_node = if first.is_a?(Prism::ConstantReadNode) || first.is_a?(Prism::ConstantPathNode)
        first
      elsif first.is_a?(Prism::CallNode) && first.name.to_s == "new" &&
            (first.receiver.is_a?(Prism::ConstantReadNode) || first.receiver.is_a?(Prism::ConstantPathNode))
        first.receiver
      end
      return nil unless const_node

      name = const_node.location.slice.strip.split("::").last.to_s
      return nil if name.empty? || RAISE_PANIC_CLASSES.include?(name)
      return nil unless name.match?(/Error|Exceeded|Failure|Exception\z/)

      name
    end

    def ruby_raise_message_code(node)
      args = node.arguments ? node.arguments.arguments : []
      return clear_string_literal("Ruby exception raised") if args.empty?

      msg_node = if raise_message_argument?(args.first)
        args.first
      elsif args.length >= 2 && raise_message_argument?(args[1])
        args[1]
      else
        exception_constructor_message_arg(args.first)
      end

      return clear_string_literal("Ruby exception raised") unless msg_node

      if msg_node.is_a?(Prism::InterpolatedStringNode)
        static_parts = msg_node.parts.map do |part|
          part.is_a?(Prism::StringNode) ? part.content : "{}"
        end.join
        return clear_string_literal(static_parts)
      end

      visit(msg_node)
    end

    def exception_constructor_message_arg(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.name.to_s == "new"

      args = node.arguments ? node.arguments.arguments : []
      args.find { |arg| raise_message_argument?(arg) }
    end

    def raise_message_argument?(node)
      return true if node.is_a?(Prism::StringNode) || node.is_a?(Prism::InterpolatedStringNode)

      inferred_clear_type(node).to_s == "String"
    end

    def ternary_if_node?(node)
      node.respond_to?(:if_keyword_loc) && node.if_keyword_loc.nil? && node.consequent
    end

    def predicate_assignment_node(node)
      return node if node.is_a?(Prism::LocalVariableWriteNode)
      if node.is_a?(Prism::ParenthesesNode) &&
         node.body.is_a?(Prism::StatementsNode) &&
         node.body.body.length == 1 &&
         node.body.body.first.is_a?(Prism::LocalVariableWriteNode)
        return node.body.body.first
      end

      nil
    end

    def embedded_predicate_assignment_node(node)
      return nil unless node
      return node if node.is_a?(Prism::LocalVariableWriteNode)
      return nil unless node.respond_to?(:child_nodes)

      node.child_nodes.each do |child|
        found = embedded_predicate_assignment_node(child)
        return found if found
      end
      nil
    end

    def contains_node_type?(node, type)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(type)

      node.child_nodes.any? { |child| contains_node_type?(child, type) }
    end

    def visit_ternary_if_node(node, statement: false)
      optional_truthy = optional_union_truthy_if_guard(node.predicate)
      nil_receiver = nil_predicate_receiver(node.predicate)
      optional_nil_false = optional_union_truthy_if_guard(nil_receiver) if nil_receiver
      true_expr = if optional_truthy && optional_truthy[:receiver_node].is_a?(Prism::LocalVariableReadNode)
        # `x ? a(x) : b` lowers to `IF x != NIL THEN a(x) ELSE b`; the THEN
        # branch flow-narrows `x` to its payload in place, so narrow the
        # type (no rename to `x?`, which the narrowed value would reject).
        with_local_optional_narrowed(optional_truthy[:receiver_name], optional_truthy[:payload_type]) do
          single_expression_from_statements(node.statements)
        end
      elsif optional_truthy
        expression_guard = optional_truthy.merge(
          binding_name: optional_unwrap_code(optional_truthy[:receiver_code])
        )
        with_optional_truthy_context(expression_guard) { single_expression_from_statements(node.statements) }
      else
        single_expression_from_statements(node.statements)
      end
      false_expr = if optional_nil_false
        # `x.nil? ? a : b` lowers to `IF x == NIL THEN a ELSE b`; the else flow-
        # narrows `x` to its payload in place, so narrow the type (no rename to
        # `x?`, which the in-place-narrowed value would reject).
        with_local_optional_narrowed(optional_nil_false[:receiver_name], optional_nil_false[:payload_type]) do
          single_expression_from_statements(node.consequent.statements)
        end
      else
        single_expression_from_statements(node.consequent.statements)
      end
      unless true_expr && false_expr
        return unsupported_expression(node, "Ternary branches must contain one expression")
      end

      pred = if optional_truthy
        "#{optional_truthy[:receiver_code]} != NIL"
      else
        predicate_code(node.predicate)
      end
      return true_expr if pred == "TRUE"
      return false_expr if pred == "FALSE"
      true_node = node.statements&.body&.last
      false_node = node.consequent&.statements&.body&.last
      if statement || (ternary_effect_branch?(true_node) && ternary_effect_branch?(false_node))
        return "IF #{pred} THEN\n#{indent}  #{statement_code(true_expr)}\n" \
          "#{indent}ELSE\n#{indent}  #{statement_code(false_expr)}\n#{indent}END"
      end
      unless ternary_branch_copyable?(true_node) && ternary_branch_copyable?(false_node)
        return ternary_value_block_code(pred, true_expr, false_expr, true_node, false_node)
      end
      "IF #{pred} THEN\n#{indent}  #{true_expr}\n#{indent}ELSE\n#{indent}  #{false_expr}\n#{indent}END"
    end

    def ternary_effect_branch?(node)
      return false unless node.is_a?(Prism::CallNode)
      return true if inferred_clear_type(node).to_s == "Void"

      node.name.to_s == "[]=" || node.name.to_s.end_with?("=") ||
        %w[<< add append insert merge merge!].include?(node.name.to_s)
    end

    # CLEAR rejects an expression-form IF/ternary whose result is a
    # heap-allocated type (IF_EXPR_RESULT_NOT_COPYABLE) - only primitives,
    # symbols, and rodata strings may be selected inline. A KNOWN concrete
    # named struct/union/collection type is treated conservatively as
    # non-copyable, routing to the always-valid value-block form below.
    # Plain String stays on the existing inline path: the compiler stamps
    # an expression-IF's String result as rodata regardless of how it was
    # built (expressions.rb's visit_IfExpr coerces to `Type.new(:String,
    # location: :rodata)` after the copyability check passes), so nothing
    # about the branches themselves needs to be a literal - the ORIGINAL
    # bug this file fixes (IF_EXPR_RESULT_NOT_COPYABLE) was never reachable
    # for String, and routing it through the value-block form anyway broke
    # a real case (a String ternary nested inside string interpolation;
    # ast/type_expression.rb, a real G4 regression caught by the mandatory
    # verifier diff - the Zig backend does not support a multi-statement
    # value block nested inside a `${...}` interpolation slot).
    # An unresolved/dynamic type ("Any"/"Auto", or no type info at all) is
    # left alone too - the type checker has no basis to reject it as an
    # expression-IF result either, and treating "unknown" as "unsafe" would
    # force every untyped ternary through the value-block form for no
    # reason.
    def ternary_branch_copyable?(node)
      type = inferred_clear_type(node).to_s.delete_prefix("?")
      return true if type.empty? || %w[Any Auto Void String].include?(type)
      return true if type == "String@symbol"

      type.match?(/\A(?:Bool|U?Int\d*|Float\d*|Byte)\z/)
    end

    # Mirrors if_assignment_code's branch-push pattern (MUTABLE slot; IF
    # pred THEN slot = a; ELSE slot = b; END; slot?) but self-contained in a
    # value block, since visit_ternary_if_node's callers only expect back an
    # embeddable expression string, not an assignment target name.
    def ternary_value_block_code(pred, true_expr, false_expr, true_node, false_node)
      type = inferred_clear_type(true_node) || inferred_clear_type(false_node) || "Any"
      slot = next_generated_local("ternary_value")
      slot_type = optional_clear_type(type)
      read = type.to_s.start_with?("?") ? slot : "#{slot}?"
      "{ MUTABLE rtoc_value_block_marker = 0; MUTABLE #{slot}: #{slot_type} = NIL;\n" \
        "#{indent}IF #{pred} THEN\n#{indent}  #{slot} = #{true_expr};\n" \
        "#{indent}ELSE\n#{indent}  #{slot} = #{false_expr};\n#{indent}END\n" \
        "#{indent}#{read} }"
    end

    def visit_if_expression_or_placeholder(node)
      code = if_expression_code(node)
      return code if code

      unsupported_expression(node, "If expression branches must contain one expression")
    end

    def visit_case_expression_or_placeholder(node)
      code = case_expression_code(node)
      return code if code

      return unsupported_expression(node, "Case expressions without a target are not supported") if node.predicate.nil?

      unsupported_expression(unsupported_case_expression_node(node), "Case expression arms must contain one expression")
    end

    def unsupported_case_expression_node(node)
      node.conditions.find { |when_node| !case_expression_statements?(when_node.statements) } ||
        (node.consequent if node.consequent && !case_expression_statements?(node.consequent.statements)) ||
        node
    end

    def case_expression_code(node, expected_type: nil)
      return condition_case_expression_code(node, expected_type: expected_type) if node.predicate.nil?

      target = visit(node.predicate)
      arms = []
      node.conditions.each do |w|
        w.conditions.each do |cond|
          # A `when SomeVariant` on a union value is a variant pattern
          # (`UnionType.Variant AS binding`); the arm body reads the narrowed
          # payload through the binding. A bare constant reads as a value
          # pattern instead, so route union variants through the same narrowing
          # machinery the if-chain lowering uses.
          narrowing = union_case_narrowing(node.predicate, cond)
          pattern = narrowing ? narrowing.fetch(:pattern) : qualify_union_variant_pattern(visit(cond), node.predicate)
          stmt_val = if narrowing
            with_narrowing_context(narrowing.fetch(:context)) { case_arm_value_code(w.statements) }
          else
            case_arm_value_code(w.statements)
          end
          return nil unless stmt_val

          if expected_type
            stmt_val = wrap_argument_for_parameter_type(stmt_val, w.statements.body.last, expected_type)
          end
          stmt_val = match_arm_expression(stmt_val)
          arms << "#{pattern} -> #{stmt_val},"
        end
      end

      if node.consequent
        else_val = case_arm_value_code(node.consequent.statements)
        return nil unless else_val

        if expected_type
          else_val = wrap_argument_for_parameter_type(else_val, node.consequent.statements.body.last, expected_type)
        end
        else_val = match_arm_expression(else_val)
        arms << "DEFAULT -> #{else_val}"
      else
        arms << "DEFAULT -> NIL"
      end

      arms_body = with_indent do
        arms.map { |arm| arm.split("\n").map { |l| "#{indent}#{l}" }.join("\n") }.join("\n")
      end

      "PARTIAL MATCH #{target} START\n#{arms_body}\n#{indent}END"
    end

    # Qualify a bare `when Variant` as `UnionType.Variant` when the MATCH
    # subject is a union whose members include it. Used for subjects that are
    # not simple locals (no payload binding), e.g. `case expression.kind`.
    def qualify_union_variant_pattern(cond_val, predicate)
      subject_union = inferred_clear_type(predicate).to_s.delete_prefix("?")
      members = @union_types[subject_union]
      return cond_val unless members
      normalized = cond_val.to_s.delete_prefix("?")
      return cond_val unless members.include?(normalized)

      "#{subject_union}.#{union_variant_name(normalized, subject_union)}"
    end

    # An expression-MATCH cannot produce a heap-allocated (non implicitly
    # copyable) result; the frontend requires a statement-MATCH that assigns
    # the target in every arm. Mirrors `visit_local_variable_if_assignment`'s
    # branch-slot pattern: fill an optional slot in each arm, then unwrap it.
    def case_needs_statement_assignment?(case_node, name, type_annotation)
      return false if case_node.predicate.nil?
      return true if case_node_has_jump_arm?(case_node)
      atype = type_annotation || @local_types[name] || inferred_clear_type(case_node)
      atype = inferred_case_value_type(case_node) if atype.to_s.empty? || %w[Any Auto].include?(atype.to_s)
      affine_clear_type?(atype)
    end

    # The type a case yields is the type its value-producing arms agree on;
    # jump arms contribute nothing because they never reach the assignment.
    def inferred_case_value_type(case_node)
      types = case_node_arm_statements(case_node).filter_map do |statements|
        next if statements.body.empty? || jump_statement_node?(statements.body.last)

        inferred_branch_statement_type(statements)
      end
      types.uniq.one? ? types.first : nil
    end

    # A `when ... then return x` arm yields no value, so the case can only
    # lower to a statement MATCH that assigns the destination slot.
    def case_node_has_jump_arm?(case_node)
      case_node_arm_statements(case_node).any? { |statements| jump_statement_node?(statements.body.last) }
    end

    def case_node_arm_statements(case_node)
      arms = case_node.conditions.map(&:statements)
      arms << case_node.consequent.statements if case_node.consequent
      arms.select { |statements| statements.is_a?(Prism::StatementsNode) }
    end

    def visit_local_variable_case_assignment(name, case_node, type_annotation)
      shape = inferred_shape(case_node)
      assignment_type = type_annotation || @local_types[name] || inferred_clear_type(case_node)
      assignment_type = inferred_case_value_type(case_node) if assignment_type.to_s.empty?
      @declared_locals << name
      @local_shapes[name] = shape
      @local_types[name] = assignment_type
      branch_slot = "#{name}_branch_value"
      branch_code = case_assignment_code(branch_slot, case_node, assignment_type)
      branch_type = optional_clear_type(assignment_type)
      branch_value = assignment_type.to_s.start_with?("?") ? branch_slot : "#{branch_slot}?"
      "MUTABLE #{branch_slot}: #{branch_type} = NIL;\n#{branch_code}\n" \
        "MUTABLE #{name}: #{assignment_type} = #{branch_value};"
    end

    def case_assignment_code(name, node, type = nil)
      target = visit(node.predicate)
      arms = []
      node.conditions.each do |w|
        w.conditions.each do |cond|
          narrowing = union_case_narrowing(node.predicate, cond)
          pattern = narrowing ? narrowing.fetch(:pattern) : qualify_union_variant_pattern(visit(cond), node.predicate)
          body = with_indent do
            render = -> { assignment_branch_statements(name, w.statements, type) }
            narrowing ? with_narrowing_context(narrowing.fetch(:context), &render) : render.call
          end
          arms << "#{indent}  #{pattern} ->\n#{body},"
        end
      end
      default_body = with_indent do
        if node.consequent
          assignment_branch_statements(name, node.consequent.statements, type)
        else
          "#{indent}#{name} = #{default_value_for_type(type)};"
        end
      end
      arms << "#{indent}  DEFAULT ->\n#{default_body}"
      "#{indent}PARTIAL MATCH #{target} START\n#{arms.join("\n")}\n#{indent}END"
    end

    def condition_case_expression_code(node, expected_type: nil)
      chunks = node.conditions.map.with_index do |when_node, index|
        value = case_arm_value_code(when_node.statements)
        return nil unless value
        if expected_type
          value = wrap_argument_for_parameter_type(value, when_node.statements.body.last, expected_type)
        end

        keyword = index.zero? ? "IF" : "ELSE_IF"
        "#{keyword} #{case_when_predicate(nil, when_node)} THEN\n#{indent}  #{value}"
      end

      if node.consequent
        value = case_arm_value_code(node.consequent.statements)
        return nil unless value
        if expected_type
          value = wrap_argument_for_parameter_type(value, node.consequent.statements.body.last, expected_type)
        end
        chunks << "ELSE\n#{indent}  #{value}"
      else
        chunks << "ELSE\n#{indent}  NIL"
      end

      "#{chunks.join("\n")}\n#{indent}END"
    end

    def case_expression_statements?(statements)
      statements.is_a?(Prism::StatementsNode) && statements.body.any?
    end

    def case_arm_value_code(statements)
      return nil unless statements.is_a?(Prism::StatementsNode) && statements.body.any?
      if statements.body.length == 1
        statement = statements.body.first
        return nil if lambda_statement_node?(statement)
        # A jump arm yields no value, so the case cannot lower to a MATCH
        # expression; the caller falls back to the statement chain.
        return nil if jump_statement_node?(statement)
        code = match_arm_expression(expression_argument_code(statement))
        return (statement.is_a?(Prism::IfNode) || statement.is_a?(Prism::CaseNode)) ? "(#{code})" : code
      end

      lines = statements.body.map.with_index do |statement, index|
        code = visit(statement)
        if index < statements.body.length - 1
          statement_code(code)
        else
          if lambda_statement_node?(statement)
            return nil
          end
          final_code = if statement.is_a?(Prism::IfNode) || statement.is_a?(Prism::CaseNode)
            match_arm_expression(expression_argument_code(statement))
          else
            match_arm_expression(code)
          end
          (statement.is_a?(Prism::IfNode) || statement.is_a?(Prism::CaseNode)) ? "(#{final_code})" : final_code
        end
      end
      marker = "MUTABLE rtoc_value_block_marker = 0;"
      "{\n  #{marker}\n#{lines.map { |line| "  #{line}" }.join("\n")}\n}"
    end

    def render_returning_case_node(node)
      result_type = TypedIR::TypeRef.parse(@current_function_return_type)
      return_type = result_type.to_clear.delete_prefix("?")
      simple_value_arms = node.conditions.all? do |when_node|
        when_node.statements.is_a?(Prism::StatementsNode) && when_node.statements.body.length == 1
      end
      simple_value_arms &&= !node.consequent ||
        (node.consequent.statements.is_a?(Prism::StatementsNode) && node.consequent.statements.body.length == 1)
      if simple_value_arms && !@union_types.key?(return_type) && !result_type.requires_statement_result_lowering? &&
         (code = case_expression_code(node, expected_type: @current_function_return_type))
        return "RETURN #{code}"
      end

      target = node.predicate ? visit(node.predicate) : nil
      render_case_as_condition_chain(node, target, returning: true)
    end

    def if_expression_code(node)
      return visit_ternary_if_node(node) if ternary_if_node?(node)

      body = if_expression_branch_code(node, "IF")
      return nil unless body

      "#{body}\n#{indent}END"
    end

    def if_assignment_code(name, node, type = nil)
      body = if_assignment_branch_code(name, node, "IF", type)
      "#{body}\n#{indent}END"
    end

    def if_assignment_branch_code(name, node, keyword, type = nil)
      runtime_is_a = runtime_is_a_predicate(node.predicate)
      optional_truthy = runtime_is_a ? nil : optional_union_truthy_if_guard(node.predicate)
      pred = if runtime_is_a
        "#{runtime_is_a[:receiver_code]} IS_A #{runtime_is_a[:expected_type]} AS #{runtime_is_a[:binding_name]}"
      elsif optional_truthy
        "#{optional_truthy[:receiver_code]} EXISTS AS #{optional_truthy[:binding_name]}"
      else
        predicate_code(node.predicate)
      end
      code = "#{indent}#{keyword} #{pred} THEN\n"
      code += with_indent do
        if runtime_is_a
          with_narrowing_context(runtime_is_a) { assignment_branch_statements(name, node.statements, type) }
        elsif optional_truthy
          with_optional_truthy_context(optional_truthy) { assignment_branch_statements(name, node.statements, type) }
        else
          assignment_branch_statements(name, node.statements, type)
        end
      end
      consequent = node.consequent

      if consequent.is_a?(Prism::IfNode)
        if runtime_is_a || optional_truthy
          code += "\n#{indent}ELSE\n"
          code += with_indent { if_assignment_code(name, consequent, type) }
        else
          code += "\n#{if_assignment_branch_code(name, consequent, 'ELSE_IF', type)}"
        end
      elsif consequent
        code += "\n#{indent}ELSE\n"
        code += with_indent { assignment_branch_statements(name, consequent.statements, type) }
      else
        code += "\n#{indent}ELSE\n#{indent}  #{name} = #{default_value_for_type(type)};"
      end

      code
    end

    def noreturn_branch_code(node)
      return nil unless node.is_a?(Prism::CallNode) && sorbet_call?(node) && node.name.to_s == "absurd"

      visit(node).to_s.delete_suffix(";")
    end

    def assignment_branch_statements(name, statements, type = nil)
      return "#{indent}#{name} = NIL;" unless statements.is_a?(Prism::StatementsNode) && statements.body.any?

      body = statements.body
      rendered = body[0...-1].map { |stmt| format_statement_code(visit(stmt)) }
      if body.last.is_a?(Prism::IfNode) &&
         (runtime_is_a_predicate(body.last.predicate) || optional_union_truthy_if_guard(body.last.predicate) ||
          affine_clear_type?(type) || type.to_s == "String")
        rendered << if_assignment_code(name, body.last, type)
        return rendered.join("\n")
      end
      if jump_statement_node?(body.last) ||
         (body.last.is_a?(Prism::CallNode) && ruby_raise_call?(body.last))
        rendered << format_statement_code(visit(body.last))
        return rendered.join("\n")
      end
      # A branch whose value never returns (T.absurd, panic) terminates rather
      # than producing one: assigning NoReturn to the destination's type is a
      # type error, and the assignment is unreachable anyway.
      if (terminating = noreturn_branch_code(body.last))
        rendered << "#{indent}#{terminating};"
        return rendered.join("\n")
      end
      value = if name.start_with?("self.")
        wrap_argument_for_parameter_type(field_assignment_value(body.last), body.last, type)
      else
        rendered_value = with_expected_expression_type(type) { visit(body.last) }.delete_suffix(";")
        wrapped_value = wrap_argument_for_parameter_type(rendered_value, body.last, type)
        if wrapped_value != rendered_value
          wrapped_value
        elsif stored_borrowed_value?(body.last)
          "COPY #{rendered_value}"
        else
          rendered_value
        end
      end
      rendered << format_statement_code("#{name} = #{value}")
      rendered.join("\n")
    end

    def returning_branch_statements(statements)
      render_returning_statements(statements)
    end

    def if_expression_branch_code(node, keyword)
      true_expr = case_arm_value_code(node.statements)
      return nil unless true_expr

      pred = predicate_code(node.predicate)
      code = "#{indent}#{keyword} #{pred} THEN\n#{indent}  #{true_expr}"
      consequent = node.consequent

      if consequent.is_a?(Prism::IfNode)
        nested = if_expression_branch_code(consequent, "ELSE_IF")
        return nil unless nested

        code = "#{code}\n#{nested}"
      elsif consequent
        false_expr = case_arm_value_code(consequent.statements)
        return nil unless false_expr

        code = "#{code}\n#{indent}ELSE\n#{indent}  #{false_expr}"
      else
        code = "#{code}\n#{indent}ELSE\n#{indent}  NIL"
      end

      code
    end

    def single_expression_from_statements(statements)
      return nil unless statements.is_a?(Prism::StatementsNode)
      return nil unless statements.body.length == 1

      visit(statements.body.first)
    end

    def match_arm_expression(code)
      code.to_s.strip.delete_suffix(";")
    end

    def match_statement_arm_body(code)
      stripped = code.to_s.strip
      return stripped if stripped.include?("\n")

      match_arm_expression(stripped)
    end

    def parameter_default_supported?(node)
      !node.is_a?(Prism::ArrayNode) && !node.is_a?(Prism::HashNode)
    end
    public :collection_element_type, :copyable_storage_type?, :stored_borrowed_value?
  end
end
