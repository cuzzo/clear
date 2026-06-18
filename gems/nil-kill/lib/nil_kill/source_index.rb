# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

module NilKill
  class SourceIndex
    # Cross-file shape/type symbol table; class-level readers delegate
    # here so existing call sites are unchanged.
    class ShapeSymbolTable
      attr_reader :attribute_hash_shapes, :attribute_array_element_shapes,
        :struct_field_hash_shapes, :struct_field_array_element_shapes,
        :struct_field_static_types, :struct_fields_by_name, :struct_full_by_name

      def initialize
        @attribute_hash_shapes = {}
        @attribute_array_element_shapes = {}
        @struct_field_hash_shapes = {}
        @struct_field_array_element_shapes = {}
        @struct_field_static_types = {}
        @struct_fields_by_name = {}
        @struct_full_by_name = {}
      end
    end

    @shape_table = ShapeSymbolTable.new

    class << self
      attr_reader :noreturn_methods, :shape_table

      %i[attribute_hash_shapes attribute_array_element_shapes
         struct_field_hash_shapes struct_field_array_element_shapes
         struct_field_static_types struct_fields_by_name struct_full_by_name].each do |idx|
        define_method(idx) { @shape_table.public_send(idx) }
      end

      def reset_global_shape_indexes
        @shape_table = ShapeSymbolTable.new
        @rbi_field_types = nil
        @noreturn_methods = Set.new
        @source_lines = {}
        @parsed_files = {}
      end

      def rbi_field_types
        @rbi_field_types ||= load_rbi_field_types
      end

      def noreturn_methods
        @noreturn_methods ||= Set.new
      end

      def register_noreturn_method(name)
        return unless name && !name.to_s.empty?
        @noreturn_methods ||= Set.new
        @noreturn_methods << name.to_s
      end

      def source_lines(path)
        @source_lines ||= {}
        @source_lines[path] ||= File.readlines(path)
      end

      def parsed_file(path)
        @parsed_files ||= {}
        @parsed_files[path] ||= NilKill.cached_parse_file(path)
      end

      def load_rbi_field_types
        provider = NilKill::Languages.provider_for("ruby") if defined?(NilKill::Languages)
        indexed = provider&.field_type_index(root: NilKill::ROOT)
        return indexed if indexed && !indexed.empty?

        types = {}
        Dir.glob(File.join(NilKill::ROOT, "sorbet", "rbi", "**", "*.rbi")).each do |path|
          klass = nil
          pending_type = nil
          File.readlines(path).each do |line|
            if line =~ /^\s*class\s+([A-Z]\S*)/
              klass = $1
            elsif klass && line =~ /^\s*sig\s*\{\s*returns\((.+)\)\s*\}/
              pending_type = $1.strip
            elsif klass && line =~ /^\s*def\s+([a-zA-Z_]\w*)\b/
              types[[klass, $1]] = pending_type || "T.untyped"
              pending_type = nil
            elsif line =~ /^\s*end\s*$/
              klass = nil
              pending_type = nil
            end
          end
        end
        types
      end
    end

    attr_reader :path, :rel, :methods, :tlet_sites, :dead_nil_checks, :struct_declarations, :struct_field_static, :tuple_arrays, :hash_shapes,
      :collection_index_lookups, :hash_record_blockers, :hash_record_member_calls,
      :type_normalizers, :deterministic_guards, :dispatcher_inferences, :return_origins, :param_origins,
      :return_usage_sites, :return_direct_usage_sites, :hash_record_escape_sites,
      :hidden_enum_observations,
      :ivar_protocols, :ivar_param_origins,
      :rescue_handlers, :included_modules, :sorbet_state_fields

    # Hash that bumps a shared epoch cell on every mutation so the
    # expression_type memo can detect staleness. `wrap` keeps the cell
    # bound across a non-mutating Hash#merge that returns an EpochHash.
    class EpochHash < Hash
      def self.wrap(src, cell)
        if src.is_a?(EpochHash)
          src.instance_variable_set(:@ec, cell)
          return src
        end
        h = new
        h.instance_variable_set(:@ec, cell)
        src&.each { |k, v| h[k] = v }
        h
      end

      def []=(k, v); @ec[0] += 1 if @ec; super; end
      def store(k, v); @ec[0] += 1 if @ec; super; end
      def delete(*a, &b); @ec[0] += 1 if @ec; super; end
      def clear; @ec[0] += 1 if @ec; super; end
      def merge!(*a, &b); @ec[0] += 1 if @ec; super; end
      def update(*a, &b); @ec[0] += 1 if @ec; super; end
      def replace(o); @ec[0] += 1 if @ec; super; end
      def delete_if(&b); @ec[0] += 1 if @ec; super; end
      def reject!(&b); @ec[0] += 1 if @ec; super; end
      def select!(&b); @ec[0] += 1 if @ec; super; end
      def keep_if(&b); @ec[0] += 1 if @ec; super; end
    end

    # The 5 @current_* maps expression_type reads. The writer re-wraps
    # so a reassignment and later in-place writes both bump the epoch.
    %i[current_param_types current_local_types current_collection_builders
       current_hash_shapes current_array_element_shapes].each do |n|
      define_method(n) { instance_variable_get("@#{n}") }
      define_method("#{n}=") { |v| instance_variable_set("@#{n}", EpochHash.wrap(v, @ep)) }
    end

    COLLECTION_APPEND_METHODS = %w[<< push unshift append prepend concat].freeze

    def initialize(path, warm_only: false, usage_only: false)
      @path = path
      @rel = NilKill.rel(path)
      @lines = self.class.source_lines(path)
      @warm_only = warm_only
      @usage_only = usage_only
      @ep = [0]
      @expr_memo = {}
      @expr_use_memo = ENV["NIL_KILL_EXPR_MEMO"] != "0"
      @expr_shadow = ENV["NIL_KILL_EXPR_SHADOW"] == "1"
      @expr_shadow_bad = 0
      @methods = []
      @tlet_sites = []
      @dead_nil_checks = []
      @struct_declarations = []
      @included_modules = []
      @sorbet_state_fields = []
      @struct_field_static = []
      @tuple_arrays = []
      @hash_shapes = []
      @collection_index_lookups = []
      @hash_record_blockers = []
      @hash_record_member_calls = []
      @type_normalizers = []
      @deterministic_guards = []
      @dispatcher_inferences = []
      @return_origins = []
      @param_origins = []
      @return_usage_sites = []
      @return_direct_usage_sites = []
      @hash_record_escape_sites = []
      @hidden_enum_observations = []
      @rescue_handlers = []
      @ivar_protocols = Hash.new { |hash, key| hash[key] = Set.new }
      @ivar_param_origins = Hash.new { |hash, key| hash[key] = Set.new }
      @struct_fields_by_name = {}
      @struct_full_by_name = {}
      @non_nil_locals = Set.new
      @maybe_nil_locals = Set.new
      @non_nil_method_returns = Set.new
      @method_return_types = Hash.new { |hash, key| hash[key] = [] }
      @static_return_types = {}
      @static_hash_return_shapes = {}
      @static_array_element_return_shapes = {}
      @inferred_param_hash_shapes = {}
      @inferred_param_array_element_shapes = {}
      @method_nodes = []
      # Pure function of the type string -> memoize by type.
      @rcfs_memo = {}
      # Symbol -> String memo: node.name.to_s on hot AST walks otherwise
      # allocates a fresh String per visit for repeated method names.
      @sym_str = {}
      self.current_param_types = {}
      self.current_local_types = {}
      self.current_collection_builders = {}
      self.current_hash_shapes = {}
      @current_hash_shape_sources = {}
      self.current_array_element_shapes = {}
      @current_method_name = nil
      @current_t_struct_owner = nil
      @local_container_origins = {}
      @ivar_container_origins = {}
      @ivar_tlet_names = Set.new
      @ivar_tlet_types = {}
      @current_class_name = nil
      @class_like_constants = Set.new
      parsed = self.class.parsed_file(path)
      if parsed.success?
        if @usage_only
          collect_return_usage_sites!(parsed.value)
        else
          collect_prescan(parsed.value, [], [])
          walk(parsed.value, [])
          unless @warm_only
            collect_return_usage_sites!(parsed.value)
            collect_hash_record_escape_sites!(parsed.value)
            recompute_return_origins_with_inferred_shapes
            recompute_collection_index_lookups_with_inferred_shapes
            recompute_struct_field_static_with_inferred_locals
          end
        end
      end
      unless @warm_only || @usage_only
        @method_nodes.each do |def_node, record|
          collect_type_normalizers!(def_node, record)
          collect_hidden_enum_observations!(def_node, record)
        end
      end
    end

    def summary
      TypedRecords::SummaryRecord.new(
        method_count: @methods.size,
        unsigned_methods: @methods.count { |m| !m["has_sig"] },
        tlet_sites: @tlet_sites.count { |s| s["tlet"] },
        candidate_tlet_sites: @tlet_sites.count { |s| !s["tlet"] },
        dead_nil_checks: @dead_nil_checks.size,
        structs: @struct_declarations.size,
        tuple_arrays: @tuple_arrays.size,
        hash_shapes: @hash_shapes.size,
        collection_index_lookups: @collection_index_lookups.size,
        type_normalizers: @type_normalizers.size,
        deterministic_guards: @deterministic_guards.size,
        return_origins: @return_origins.size,
        param_origins: @param_origins.size,
        return_usage_sites: @return_usage_sites.size,
        hash_record_escape_sites: @hash_record_escape_sites.size,
        hidden_enum_observations: @hidden_enum_observations.size,
      ).to_source_index_hash
    end

  end
end

require_relative "source_index/typed_records"
require_relative "source_index/observations"
require_relative "source_index/traversal"
require_relative "source_index/records"
require_relative "source_index/return_analysis"
require_relative "source_index/param_protocols"
require_relative "source_index/deterministic_guards"
require_relative "source_index/expression_shapes"
