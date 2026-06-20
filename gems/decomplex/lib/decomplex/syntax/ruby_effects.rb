# frozen_string_literal: true

module Decomplex
  module Syntax
    RUBY_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[send __send__ public_send const_get constantize
                        instance_variable_get].freeze,
      meta_mids: %w[define_method define_singleton_method alias_method
                    class_eval module_eval instance_eval class_exec
                    module_exec instance_exec eval const_set
                    instance_variable_set remove_method undef_method
                    prepend singleton_class binding].freeze,
      method_obj_mids: %i[method public_method instance_method].freeze,
      io_consts: %w[File IO Dir FileUtils Open3 Socket TCPSocket UDPSocket
                    TCPServer UNIXSocket Tempfile Pathname Marshal].freeze,
      io_bare: %w[puts print warn gets readline readlines system
                  exec spawn fork sleep open abort exit exit!].freeze,
      dir_context: %w[pwd getwd home].freeze,
      context_pairs: {
        "Time" => %w[now current], "Date" => %w[today current],
        "DateTime" => %w[now current], "Process" => %w[pid ppid uid gid euid],
        "Thread" => %w[current list main], "Fiber" => %w[current],
        "Random" => %w[rand bytes], "GC" => %w[stat count],
        "ObjectSpace" => %w[each_object count_objects]
      }.freeze,
      context_bare: %w[rand srand].freeze,
      callback_set: %w[transaction synchronize lock with_lock unlock
                       mutex atomic reentrant subscribe callback hook].freeze,
      core_consts: %w[String Symbol Integer Float Numeric Rational Complex
                      Array Hash Set Range Struct Object BasicObject Kernel
                      Module Class Comparable Enumerable Enumerator Proc Method
                      UnboundMethod NilClass TrueClass FalseClass Exception
                      StandardError RuntimeError ArgumentError TypeError
                      NameError NoMethodError IO File Dir Time Date DateTime
                      Regexp MatchData Thread Mutex Fiber Process Math GC
                      ObjectSpace Marshal Random Encoding].freeze
    ).freeze

    class RubySyntaxAdapter
      def semantic_effect_sites(document)
        sites = super
        sites.concat(ruby_global_context_sites(document))
        sites.concat(ruby_state_mutation_sites(document))
        sites.concat(ruby_method_hook_sites(document))
        TreeSitterAdapter.walk_document(document, initial_stack(document), self) do |node, stack|
          sites.concat(ruby_semantic_effect_sites_for_node(document, node, stack))
        end
        sites.uniq { |site| [site.kind, site.detail, site.file, site.function, site.line, site.span] }
      end

      private

      def effect_lexicon
        RUBY_EFFECT_LEXICON
      end

      def ruby_net_receiver?(receiver)
        receiver.to_s.sub(/\A::/, "").start_with?("Net::")
      end

      def const_effect_site_for_call(call, message)
        receiver = call.receiver.to_s.sub(/\A::/, "")
        return semantic_effect_site_from_call(call, :hidden_io, "URI.open") \
          if receiver == "URI" && message == "open"

        super
      end

      def ruby_global_context_sites(document)
        document.state_reads.filter_map do |read|
          next unless read.field.to_s.start_with?("$")
          next if ruby_global_assignment_read?(document, read)

          SemanticEffectSite.new(
            kind: :context_dependency,
            detail: read.field,
            file: read.file,
            function: read.function,
            owner: read.owner,
            line: read.line,
            span: read.span
          )
        end
      end

      def ruby_global_assignment_read?(document, read)
        line_text = document.lines[read.line - 1].to_s
        line_text[read.span[3]..].to_s.lstrip.start_with?("=")
      end

      def ruby_state_mutation_sites(document)
        document.state_writes.filter_map do |write|
          next if write.receiver.to_s == "self"
          next if write.field.to_s.start_with?("@", "$")

          SemanticEffectSite.new(
            kind: :hidden_mutation,
            detail: "#{write.field}=",
            file: write.file,
            function: write.function,
            owner: write.owner,
            line: write.line,
            span: write.span
          )
        end
      end

      def ruby_method_hook_sites(document)
        document.function_defs.filter_map do |function_def|
          name = function_def.name.to_s.split(".").last
          next unless %w[method_missing respond_to_missing?].include?(name)

          SemanticEffectSite.new(
            kind: :metaprogramming,
            detail: "def #{name}",
            file: function_def.file,
            function: function_def.name,
            owner: function_def.owner,
            line: function_def.line,
            span: function_def.span
          )
        end
      end

      def ruby_semantic_effect_sites_for_node(document, node, stack)
        case node.kind
        when "yield"
          [semantic_effect_site(document, node, stack, :dynamic_dispatch, "yield")]
        when "subshell"
          [semantic_effect_site(document, node, stack, :hidden_io, "backtick")]
        when "singleton_class"
          ruby_singleton_class_effect(document, node, stack)
        when "element_reference"
          ruby_element_reference_effect(document, node, stack)
        when "assignment"
          ruby_global_assignment_effect(document, node, stack) +
            ruby_assignment_effect(document, node, stack)
        when "operator_assignment"
          ruby_operator_assignment_effect(document, node, stack)
        when "binary"
          ruby_binary_effect(document, node, stack)
        when "body_statement", "block_body"
          ruby_flat_statement_effects(document, node, stack)
        else
          []
        end
      end

      def ruby_singleton_class_effect(document, node, stack)
        receiver = node.named_children.first
        return [] unless receiver
        return [] if receiver.text == "self"

        [semantic_effect_site(document, node, stack, :metaprogramming, "class << #{normalize_text(receiver.text)}")]
      end

      def ruby_element_reference_effect(document, node, stack)
        receiver = node.named_children.first
        return [] unless receiver&.text == "ENV"

        [semantic_effect_site(document, node, stack, :context_dependency, "ENV")]
      end

      def ruby_assignment_effect(document, node, stack)
        lhs = named_field(node, "left") || node.named_children.first
        return [] unless lhs&.kind == "element_reference"
        return [] if lhs.named_children.first&.text == "ENV"

        [semantic_effect_site(document, node, stack, :hidden_mutation, "[]=")]
      end

      def ruby_global_assignment_effect(document, node, stack)
        lhs = named_field(node, "left") || node.named_children.first
        return [] unless lhs&.kind == "global_variable"

        [semantic_effect_site(document, node, stack, :context_dependency, lhs.text)]
      end

      def ruby_operator_assignment_effect(document, node, stack)
        lhs = named_field(node, "left") || node.named_children.first
        return [] if ruby_local_operator_assignment_lhs?(lhs)

        [semantic_effect_site(document, node, stack, :hidden_mutation, "op-assign")]
      end

      def ruby_local_operator_assignment_lhs?(lhs)
        return true unless lhs

        %w[identifier instance_variable global_variable].include?(lhs.kind)
      end

      def ruby_binary_effect(document, node, stack)
        return [] unless direct_operator(node) == "<<"

        [semantic_effect_site(document, node, stack, :hidden_mutation, "<<")]
      end

      def ruby_flat_statement_effects(document, node, stack)
        operator = direct_operator(node)
        case operator
        when "<<"
          [semantic_effect_site(document, node, stack, :hidden_mutation, "<<")]
        when "="
          ruby_flat_element_assignment_effect(document, node, stack, "[]=")
        when "+=", "-=", "*=", "/=", "%=", "&&=", "||="
          ruby_flat_element_assignment_effect(document, node, stack, "op-assign")
        else
          []
        end
      end

      def ruby_flat_element_assignment_effect(document, node, stack, detail)
        lhs = node.named_children.first
        return [] unless lhs&.kind == "element_reference"
        return [] if lhs.named_children.first&.text == "ENV"

        [semantic_effect_site(document, node, stack, :hidden_mutation, detail)]
      end
    end
  end
end
