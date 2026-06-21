# frozen_string_literal: true

module FactMine
  module Syntax
    SemanticEffectSite = Struct.new(:kind, :detail, :file, :function, :owner, :line, :span,
                                    keyword_init: true)
    EffectLexicon = Struct.new(
      :dispatch_mids, :meta_mids, :method_obj_mids, :io_consts, :io_pairs,
      :io_bare, :dir_context, :context_pairs, :context_bare,
      :callback_set, :callback_requires_block, :core_consts,
      keyword_init: true
    )

    def self.core_owner_names(language)
      lexicon = effect_lexicon_for(language)
      Array(lexicon&.core_consts)
    rescue ArgumentError, KeyError
      []
    end

    class Document
      def semantic_effect_sites
        @semantic_effect_sites ||= adapter.semantic_effect_sites(self)
      end
    end

    class TreeSitterLanguageAdapter
      def semantic_effect_sites(document)
        semantic_effect_sites_from_calls(document)
      end

      private

      def effect_lexicon
        Syntax.effect_lexicon_for(language)
      end

      def semantic_effect_sites_from_calls(document)
        return [] unless effect_lexicon

        by_operation = {}
        document.call_sites.each do |call|
          next if local_self_call?(document, call)

          site = semantic_effect_site_for_call(call)
          next unless site

          key = [site.kind, site.detail, site.file, site.function, site.owner,
                 site.line, call.receiver, call.message, call.arguments]
          current = by_operation[key]
          if current.nil? || span_width(site.span) > span_width(current.span)
            by_operation[key] = site
          end
        end
        by_operation.values
      end

      def span_width(span_value)
        ((span_value[2] - span_value[0]) * 100_000) + (span_value[3] - span_value[1])
      end

      def semantic_effect_site_for_call(call)
        lexicon = effect_lexicon
        message = call.message.to_s

        if effect_callback_call?(call, message)
          return semantic_effect_site_from_call(call, :callback_inversion, message)
        end
        return semantic_effect_site_from_call(call, :metaprogramming, message) if lexicon.meta_mids.include?(message)
        return semantic_effect_site_from_call(call, :dynamic_dispatch, message) if lexicon.dispatch_mids.include?(message)

        if message == "call" && !call.receiver.to_s.empty?
          return semantic_effect_site_from_call(call, :dynamic_dispatch, "method(...).call") if method_object_receiver?(call.receiver)
          return semantic_effect_site_from_call(call, :dynamic_dispatch, "#{call.receiver}.call") if variable_receiver?(call.receiver)
        end

        const_effect_site_for_call(call, message) ||
          bare_effect_site_for_call(call, message) ||
          mutation_effect_site_for_call(call, message)
      end

      def const_effect_site_for_call(call, message)
        receiver = call.receiver.to_s
        return nil if receiver.empty? || receiver == "self"

        lexicon = effect_lexicon
        base = receiver.sub(/\A::/, "").split("::").first
        return semantic_effect_site_from_call(call, :context_dependency, "Dir.#{message}") \
          if base == "Dir" && lexicon.dir_context.include?(message)

        if lexicon.io_pairs.to_h[base]&.include?(message)
          return semantic_effect_site_from_call(call, :hidden_io, "#{receiver.sub(/\A::/, "")}.#{message}")
        end

        if lexicon.io_consts.include?(base)
          return semantic_effect_site_from_call(call, :hidden_io, "#{receiver.sub(/\A::/, "")}.#{message}")
        end
        return semantic_effect_site_from_call(call, :context_dependency, "ENV") if receiver == "ENV"

        if lexicon.context_pairs[base]&.include?(message)
          return semantic_effect_site_from_call(call, :context_dependency, "#{base}.#{message}")
        end
        if receiver.include?(".")
          receiver_base, receiver_message = receiver.sub(/\A::/, "").split(".", 2)
          if lexicon.context_pairs[receiver_base]&.include?(receiver_message)
            return semantic_effect_site_from_call(
              call,
              :context_dependency,
              "#{receiver_base}.#{receiver_message}"
            )
          end
        end

        nil
      end

      def bare_effect_site_for_call(call, message)
        return nil unless call.receiver.to_s == "self"

        lexicon = effect_lexicon
        return semantic_effect_site_from_call(call, :hidden_io, message) if lexicon.io_bare.include?(message)
        return semantic_effect_site_from_call(call, :context_dependency, message) if lexicon.context_bare.include?(message)

        nil
      end

      def mutation_effect_site_for_call(call, message)
        return semantic_effect_site_from_call(call, :hidden_mutation, message) \
          if message.length > 1 && message.end_with?("!") && !%w[!= !~].include?(message)

        nil
      end

      def effect_callback_call?(call, message)
        return false unless effect_callback_name?(message)
        return false if effect_lexicon.meta_mids.include?(message)

        effect_lexicon.callback_requires_block == false ||
          call.block ||
          call.arguments.to_a.any? { |arg| arg.to_s.start_with?("&") }
      end

      def effect_callback_name?(message)
        effect_lexicon.callback_set.include?(message) ||
          message.match?(/\A(with_|around_|on_|before_|after_)/) ||
          message.match?(/_hook\z/)
      end

      def method_object_receiver?(receiver)
        names = effect_lexicon.method_obj_mids.map(&:to_s).map { |name| Regexp.escape(name) }
        return false if names.empty?

        receiver.to_s.match?(/(?:\A|\.)(?:#{names.join("|")})\s*\(/)
      end

      def variable_receiver?(receiver)
        receiver.to_s.match?(/\A(?:[a-z_]\w*|[@$][A-Za-z_]\w*)\z/)
      end

      def semantic_effect_site_from_call(call, kind, detail)
        SemanticEffectSite.new(
          kind: kind,
          detail: detail,
          file: call.file,
          function: call.function,
          owner: call.owner,
          line: call.line,
          span: call.span
        )
      end

      def local_self_call?(document, call)
        return false unless call.receiver.to_s == "self"
        return false unless document.respond_to?(:function_defs)

        document.function_defs.any? do |function_def|
          function_def.owner == call.owner && function_def.name.to_s == call.message.to_s
        end
      end

      def semantic_effect_site(document, node, stack, kind, detail)
        SemanticEffectSite.new(
          kind: kind,
          detail: detail,
          file: document.file,
          function: current_function(stack),
          owner: current_owner(document, stack),
          line: line(node),
          span: span(node)
        )
      end
    end

    class TreeSitterAdapter
      def semantic_effect_sites(document)
        syntax_profile(document.language).semantic_effect_sites(document)
      end
    end

    GENERIC_SYSTEM_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: [].freeze,
      meta_mids: [].freeze,
      method_obj_mids: [].freeze,
      io_consts: [].freeze,
      io_pairs: {}.freeze,
      io_bare: [].freeze,
      dir_context: [].freeze,
      context_pairs: {}.freeze,
      context_bare: [].freeze,
      callback_set: [].freeze,
      callback_requires_block: true,
      core_consts: [].freeze
    ).freeze

    @effect_lexicons = {}

    def self.register_effect_lexicon(language, lexicon)
      @effect_lexicons[language.to_sym] = lexicon
    end

    def self.effect_lexicon_for(language)
      @effect_lexicons.fetch(language.to_sym, GENERIC_SYSTEM_EFFECT_LEXICON)
    end
  end
end
