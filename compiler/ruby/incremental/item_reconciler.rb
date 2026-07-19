# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "source_catalog"

module Incremental
  class Reconciliation < T::Struct
    const :fast_path, T::Boolean
    const :changed_function, T.nilable(String), default: nil
    const :reason, String
  end

  class ItemReconciler
    extend T::Sig

    sig { params(previous: SourceCatalog, current: SourceCatalog).returns(Reconciliation) }
    def self.reconcile(previous, current)
      old_items = previous.by_name
      new_items = current.by_name
      return fallback("root function set changed") unless old_items.keys == new_items.keys
      return fallback("non-function source changed") unless previous.non_function_fingerprint == current.non_function_fingerprint

      changed = old_items.keys.select do |name|
        T.must(old_items[name]).exact_fingerprint != T.must(new_items[name]).exact_fingerprint
      end
      return Reconciliation.new(fast_path: true, reason: "exact source hit") if changed.empty?
      return fallback("more than one function changed") unless changed.one?

      name = T.must(changed.first)
      old_item = T.must(old_items[name])
      new_item = T.must(new_items[name])
      return fallback("main function changed") if name == "main"
      return fallback("function interface changed") unless old_item.interface_fingerprint == new_item.interface_fingerprint
      return fallback("source line layout changed") unless line_layout_equal?(previous, current, old_item, new_item)
      return fallback("changed function calls a user function") unless old_item.called_functions.empty? && new_item.called_functions.empty?
      if previous.called_by_user_function?(name) || current.called_by_user_function?(name)
        return fallback("changed function has a user-code caller")
      end

      Reconciliation.new(
        fast_path: true,
        changed_function: name,
        reason: "isolated function body changed",
      )
    end

    class << self
      extend T::Sig

      private

      sig { params(reason: String).returns(Reconciliation) }
      def fallback(reason)
        Reconciliation.new(fast_path: false, reason: reason)
      end

      sig do
        params(
          previous: SourceCatalog,
          current: SourceCatalog,
          old_item: FunctionItem,
          new_item: FunctionItem,
        ).returns(T::Boolean)
      end
      def line_layout_equal?(previous, current, old_item, new_item)
        previous.source.count("\n") == current.source.count("\n") &&
          old_item.start_line == new_item.start_line &&
          old_item.end_line == new_item.end_line
      end
    end
  end
end
