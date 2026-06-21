# frozen_string_literal: true

module FactMine
  module Syntax
    class Document
      def local_contract_assignments(method)
        adapter.local_contract_assignments(self, method)
      end
    end

    class TreeSitterLanguageAdapter
      def local_contract_assignments(_document, method)
        method.statements.each_with_object({}) do |statement, map|
          next unless statement.writes.size == 1

          name = statement.writes.first.to_s
          map[name] ||= local_contract_source(name, statement.source)
        end.compact
      end

      private

      def local_contract_source(name, source)
        match = source.to_s.match(/\b#{Regexp.escape(name)}\b\s*(?::=|=)\s*(.+?)\s*;?\z/m)
        return nil unless match

        rhs = match[1].strip
        return nil if rhs.match?(/\s(?:if|unless|rescue)\s|\?|:/)

        rhs
      end
    end

    class TreeSitterAdapter
      def local_contract_assignments(document, method)
        syntax_profile(document.language).local_contract_assignments(document, method)
      end
    end
  end
end
