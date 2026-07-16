# typed: strict
# frozen_string_literal: true

module NilKill
  module StructFieldTypeIndex
    extend T::Sig

    FieldKey = T.type_alias { [String, String] }
    FieldTypes = T.type_alias { T::Hash[FieldKey, String] }

    sig { params(root: String).returns(FieldTypes) }
    def self.from_rbi(root)
      types = T.let({}, FieldTypes)
      Dir.glob(File.join(root, "sorbet", "rbi", "**", "*.rbi")).each do |path|
        klass = T.let(nil, T.nilable(String))
        pending_type = T.let(nil, T.nilable(String))
        File.readlines(path).each do |line|
          if (match = line.match(/^\s*class\s+([A-Z]\S*)/))
            klass = match[1]
          elsif klass && (match = line.match(/^\s*sig\s*\{\s*returns\((.+)\)\s*\}/))
            pending_type = match[1].strip
          elsif klass && (match = line.match(/^\s*def\s+([a-zA-Z_]\w*)\b/))
            types[[klass, match[1]]] = pending_type || "T.untyped"
            pending_type = nil
          elsif line.match?(/^\s*end\s*$/)
            klass = nil
            pending_type = nil
          end
        end
      end
      types
    end
  end
end
