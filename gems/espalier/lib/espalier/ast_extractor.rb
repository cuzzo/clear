# frozen_string_literal: true

require "set"

sibling_syntax = File.expand_path("../../../decomplex/lib/decomplex/syntax", __dir__)
if File.file?("#{sibling_syntax}.rb")
  require sibling_syntax
else
  require "decomplex/syntax"
end

module Espalier
  # Extracts the structural skeleton, state, and call delegation model through
  # Decomplex's Tree-sitter syntax facts. Every supported language uses the same
  # extractor and manifest-shaping path.
  class AstExtractor
    attr_reader :file_path

    def initialize(file_path)
      @file_path = file_path
    end

    # Return structure: List of classes/modules with states & methods.
    def extract
      TreeSitterStructuralExtractor.new(file_path).extract
    end

    class TreeSitterStructuralExtractor
      STATE_RECEIVER_PATTERN = /\A@[A-Za-z_]\w*(?:\.|\z)/
      VISIBILITY_DIRECTIVES = %w[private protected public].freeze
      IGNORED_SELECTORS = %w[
        to_s to_i class hash inspect nil? present? empty? == != === < > <= >= + - * / && ||
        last first sort compact uniq map flat_map size length each keys values any? all? none?
        select find find_all map! map_with_index each_with_index reject reject! include? include
        keys values fetch dig puts raise p warn print tap block_given? respond_to? is_a?
        let must unsafe cast bind type_as zip flatten compact! index find_index
      ].freeze

      def initialize(file_path)
        @file_path = file_path
      end

      def extract
        doc = Decomplex::Syntax.parse(@file_path, parser: "tree_sitter")
        facts = doc.adapter.structural_facts(doc)
        build_modules(doc, facts).values
      end

      private

      def build_modules(doc, facts)
        modules = {}
        owner_kinds = facts[:owner_defs].to_h { |owner| [owner.name.to_s, owner.kind] }
        owner_defs = facts[:owner_defs].to_h { |owner| [owner.name.to_s, owner] }

        facts[:owner_defs].each do |owner|
          module_for(modules, owner.name.to_s, doc, owner.kind, owner)
        end

        method_names = facts[:function_defs].each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |fn, index|
          index[owner_name(doc, fn.owner)].add(fn.name.to_s)
        end
        declared_states = facts[:state_declarations].each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |state, index|
          index[state.owner.to_s].add(state.field.to_s)
        end
        method_records_by_owner = Hash.new { |h, k| h[k] = [] }

        facts[:function_defs].each do |fn|
          owner = owner_name(doc, fn.owner)
          mod = module_for(modules, owner, doc, owner_kinds[owner], owner_defs[owner])
          method = {
            name: fn.name.to_s,
            signature: method_signature(doc, fn),
            parameters: Array(fn.params).map(&:to_s),
            visibility: fn.visibility || :public,
            line: fn.line,
            span: fn.span,
            effects: { reads: Set.new, writes: Set.new },
            delegations: []
          }

          mod[:methods] << method
          method_records_by_owner[owner] << [fn, method]
        end

        apply_visibility!(facts, method_records_by_owner)

        facts[:state_declarations].each do |state|
          mod = module_for(modules, state.owner.to_s, doc, owner_kinds[state.owner.to_s], owner_defs[state.owner.to_s])
          mod[:states] << state.field.to_s
          mod[:ivar_types][state.field.to_s] = state.type.to_s unless state.type.to_s.empty?
        end

        methods_by_owner_name = modules.transform_values do |mod|
          mod[:methods].to_h { |method| [method[:name].to_s, method] }
        end

        facts[:state_writes].each do |write|
          owner = owner_name(doc, write.owner)
          next unless state_fact?(write, declared_states[owner])

          mod = module_for(modules, owner, doc, owner_kinds[owner])
          method = methods_by_owner_name.dig(owner, write.function.to_s)
          next unless method

          mod[:states] << write.field.to_s
          method[:effects][:writes] << write.field.to_s
        end

        facts[:state_reads].each do |read|
          owner = owner_name(doc, read.owner)
          next unless state_fact?(read, declared_states[owner])
          next if method_names[owner].include?(read.field.to_s) && receiver_self_like?(read.receiver)

          mod = module_for(modules, owner, doc, owner_kinds[owner])
          method = methods_by_owner_name.dig(owner, read.function.to_s)
          next unless method
          next if method[:effects][:writes].include?(read.field.to_s)

          mod[:states] << read.field.to_s
          method[:effects][:reads] << read.field.to_s
        end

        facts[:call_sites].each do |call|
          owner = owner_name(doc, call.owner)
          method = methods_by_owner_name.dig(owner, call.function.to_s)
          next unless method
          next if ignored_delegation?(call)

          method[:delegations] << {
            receiver: delegation_receiver(call.receiver),
            message: call.message.to_s,
            type: call_type(call)
          }
        end

        modules.each_value do |mod|
          mod[:states] = mod[:states].to_set
          mod[:methods].each do |method|
            method[:visibility] ||= :public
            method[:delegations].uniq!
          end
        end
        modules
      end

      def module_for(modules, owner, doc, kind, owner_def = nil)
        modules[owner] ||= begin
          mod = {
            type: module_type(kind, owner, doc),
            name: owner,
            file: @file_path,
            line: owner_def&.line || 1,
            span: owner_def&.span,
            states: Set.new,
            ivar_types: {},
            methods: [],
            language: doc.language
          }
          mod
        end
      end

      def owner_name(doc, owner)
        text = owner.to_s
        text.empty? ? File.basename(doc.file, File.extname(doc.file)) : text
      end

      def module_type(kind, owner, doc)
        return kind if kind && kind != :owner
        return :file if owner == File.basename(doc.file, File.extname(doc.file))

        :container
      end

      def method_signature(doc, fn)
        signature = fn.signature.to_s.empty? ? fn.name.to_s : fn.signature.to_s
        normalize_signature(signature)
      end

      def normalize_signature(signature)
        signature = signature.sub(/\A(?:private|protected|public)\s+/, "")
        signature = signature.sub(/;\s*end\z/, "")
        signature = signature.sub(/\s+end\z/, "")
        signature = signature.sub(/;+\z/, "")
        signature.strip.gsub(/\s+/, " ")
      end

      def apply_visibility!(facts, method_records_by_owner)
        directives_by_owner = visibility_directives(facts).group_by { |call| call.owner.to_s }
        method_records_by_owner.each do |owner, records|
          current = :public
          methods_by_name = Hash.new { |h, k| h[k] = [] }
          records.each { |fn, method| methods_by_name[fn.name.to_s] << [fn, method] }

          events = records.map { |fn, method| [:method, fn, method] } +
                   Array(directives_by_owner[owner]).map { |call| [:directive, call, nil] }
          events.sort_by! { |kind, item, _method| [item.line.to_i, Array(item.span)[1].to_i, kind == :directive ? 0 : 1] }

          events.each do |kind, item, method|
            if kind == :directive
              visibility = item.message.to_sym
              args = visibility_argument_names(item)
              if args.empty?
                current = visibility
              else
                args.each do |name|
                  prior = Array(methods_by_name[name]).select { |fn, _m| fn.line.to_i <= item.line.to_i }.last
                  prior&.last&.[]=(:visibility, visibility)
                end
              end
            else
              method[:visibility] = method_visibility(item, current)
            end
          end
        end
      end

      def visibility_directives(facts)
        facts[:call_sites].select do |call|
          call.function.to_s == "(top-level)" &&
            call.receiver.to_s == "self" &&
            VISIBILITY_DIRECTIVES.include?(call.message.to_s)
        end
      end

      def visibility_argument_names(call)
        Array(call.arguments).filter_map do |arg|
          text = arg.to_s.strip
          next if text.empty? || text.start_with?("def ")

          text.sub(/\A:/, "").delete_prefix("\"").delete_prefix("'").delete_suffix("\"").delete_suffix("'")
        end
      end

      def method_visibility(fn, current)
        return :public if fn.name.to_s.start_with?("self.")

        if (match = fn.signature.to_s.match(/\A\s*(private|protected|public)\s+def\b/))
          return match[1].to_sym
        end

        fn.visibility || current
      end

      def state_fact?(fact, declared)
        receiver = fact.receiver.to_s
        return declared.include?(fact.field.to_s) if receiver == ".literal"
        return true if receiver_self_like?(receiver)
        return true if receiver.match?(STATE_RECEIVER_PATTERN)
        return false if receiver.start_with?("self.", "this.")

        false
      end

      def ignored_delegation?(call)
        message = call.message.to_s
        receiver = call.receiver.to_s
        return true if message.include?("\n") || receiver.include?("\n")

        IGNORED_SELECTORS.include?(message)
      end

      def receiver_self_like?(receiver)
        %w[self this].include?(receiver.to_s)
      end

      def delegation_receiver(receiver)
        text = receiver.to_s.sub(/\A\*/, "")
        return "self" if text == "this"

        text.empty? ? "self" : text
      end

      def call_type(call)
        control = call.respond_to?(:control) ? call.control : nil
        return control if %i[conditional iterates always].include?(control)

        call.conditional ? :conditional : :always
      end
    end
  end
end
