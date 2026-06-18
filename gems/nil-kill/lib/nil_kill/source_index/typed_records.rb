# typed: true
# frozen_string_literal: true

module NilKill
  class SourceIndex
    module TypedRecords
      unless const_defined?(:MethodParameterRecord, false)

      module RecordHashAccess
        def [](key)
          to_source_index_hash[key.to_s]
        end

        def fetch(key, *default)
          hash = to_source_index_hash
          string_key = key.to_s
          return hash[string_key] if hash.key?(string_key)
          return default.first unless default.empty?
          raise KeyError, "key not found: #{string_key.inspect}"
        end

        def dig(first, *rest)
          rest.reduce(self[first]) do |value, key|
            value.respond_to?(:[]) ? value[key] : nil
          end
        end
      end

      def self.serialize_value(value)
        if value.respond_to?(:to_source_index_hash)
          value.to_source_index_hash
        elsif value.is_a?(Hash)
          value.each_with_object({}) { |(key, item), out| out[key.to_s] = serialize_value(item) }
        elsif value.is_a?(Array)
          value.map { |item| serialize_value(item) }
        else
          value
        end
      end

      def self.serialize_hash(hash)
        serialize_value(hash)
      end

      class HashShapeRecord < T::Struct
        prop :keys, T::Hash[String, T::Array[String]], factory: -> { {} }
        prop :value_hash_shapes, T::Hash[String, HashShapeRecord], factory: -> { {} }
        prop :value_array_element_shapes, T::Hash[String, HashShapeRecord], factory: -> { {} }
        prop :poisoned, T::Boolean, default: false

        def self.empty
          new
        end

        def self.poisoned_record
          new(poisoned: true)
        end

        def self.from(value)
          return nil unless value
          return value if value.is_a?(HashShapeRecord)

          new(
            keys: Hash(value["keys"]).each_with_object({}) do |(key, types), out|
              out[key.to_s] = Array(types).map(&:to_s)
            end,
            value_hash_shapes: shape_map_from(value["value_hash_shapes"]),
            value_array_element_shapes: shape_map_from(value["value_array_element_shapes"]),
            poisoned: !!value["poisoned"],
          )
        end

        def self.shape_map_from(value)
          Hash(value).each_with_object({}) do |(key, nested), out|
            shape = from(nested)
            out[key.to_s] = shape if shape
          end
        end

        def [](key)
          case key.to_s
          when "keys" then keys
          when "value_hash_shapes" then value_hash_shapes
          when "value_array_element_shapes" then value_array_element_shapes
          when "poisoned" then poisoned
          end
        end

        def []=(key, value)
          case key.to_s
          when "keys"
            self.keys = Hash(value).each_with_object({}) { |(k, types), out| out[k.to_s] = Array(types).map(&:to_s) }
          when "value_hash_shapes"
            self.value_hash_shapes = self.class.shape_map_from(value)
          when "value_array_element_shapes"
            self.value_array_element_shapes = self.class.shape_map_from(value)
          when "poisoned"
            self.poisoned = !!value
          else
            raise KeyError, "key not found: #{key.inspect}"
          end
        end

        def dig(first, *rest)
          rest.reduce(self[first]) do |value, key|
            value.respond_to?(:[]) ? value[key] : nil
          end
        end

        def deep_dup
          self.class.new(
            keys: keys.transform_values(&:dup),
            value_hash_shapes: self.class.deep_dup_shape_map(value_hash_shapes),
            value_array_element_shapes: self.class.deep_dup_shape_map(value_array_element_shapes),
            poisoned: poisoned,
          )
        end

        def self.deep_dup_shape_map(map)
          map.transform_values(&:deep_dup)
        end

        def merge_shape(other)
          right = self.class.from(other)
          return deep_dup unless right
          return self.class.poisoned_record if poisoned || right.poisoned

          merged_keys = (keys.keys | right.keys.keys).each_with_object({}) do |key, out|
            out[key] = (Array(keys[key]) + Array(right.keys[key])).uniq
          end
          self.class.new(
            keys: merged_keys,
            value_hash_shapes: self.class.merge_shape_maps(value_hash_shapes, right.value_hash_shapes),
            value_array_element_shapes: self.class.merge_shape_maps(value_array_element_shapes, right.value_array_element_shapes),
            poisoned: false,
          )
        end

        def self.merge_shape_maps(left, right)
          (left.keys | right.keys).each_with_object({}) do |key, out|
            left_shape = left[key]
            right_shape = right[key]
            out[key] = left_shape && right_shape ? left_shape.merge_shape(right_shape) : (left_shape || right_shape).deep_dup
          end
        end

        def to_source_index_hash
          {
            "keys" => keys.transform_values(&:dup),
            "value_hash_shapes" => value_hash_shapes.transform_values(&:to_source_index_hash),
            "value_array_element_shapes" => value_array_element_shapes.transform_values(&:to_source_index_hash),
            "poisoned" => poisoned,
          }
        end
      end

      class CollectionBuilderRecord < T::Struct
        prop :kind, String
        prop :types, T::Array[String], factory: -> { [] }
        prop :key_types, T::Array[String], factory: -> { [] }
        prop :value_types, T::Array[String], factory: -> { [] }
        prop :poisoned, T::Boolean, default: false

        def self.from(value)
          return value if value.is_a?(CollectionBuilderRecord)
          new(
            kind: value["kind"].to_s,
            types: Array(value["types"]).map(&:to_s),
            key_types: Array(value["key_types"]).map(&:to_s),
            value_types: Array(value["value_types"]).map(&:to_s),
            poisoned: !!value["poisoned"],
          )
        end

        def [](key)
          case key.to_s
          when "kind" then kind
          when "types" then types
          when "key_types" then key_types
          when "value_types" then value_types
          when "poisoned" then poisoned
          end
        end

        def []=(key, value)
          case key.to_s
          when "kind" then self.kind = value.to_s
          when "types" then self.types = Array(value).map(&:to_s)
          when "key_types" then self.key_types = Array(value).map(&:to_s)
          when "value_types" then self.value_types = Array(value).map(&:to_s)
          when "poisoned" then self.poisoned = !!value
          else raise KeyError, "key not found: #{key.inspect}"
          end
        end

        def merge(overrides)
          self.class.from(to_source_index_hash.merge(TypedRecords.serialize_hash(overrides)))
        end

        def deep_dup
          self.class.new(
            kind: kind,
            types: types.dup,
            key_types: key_types.dup,
            value_types: value_types.dup,
            poisoned: poisoned,
          )
        end

        def to_source_index_hash
          {
            "kind" => kind,
            "types" => types.dup,
            "key_types" => key_types.dup,
            "value_types" => value_types.dup,
            "poisoned" => poisoned,
          }
        end
      end

      class ParamProtocolRecord < T::Struct
        const :method_names, T::Array[String]
        const :aliases, T::Array[String]
        const :gaps, T::Array[String]

        def to_source_index_hash
          { "methods" => method_names, "aliases" => aliases, "gaps" => gaps }
        end
      end

      class ReturnSourceRecord < T::Struct
        const :kind, String
        const :line, T.nilable(Integer)
        const :code, String
        const :return_type, T.nilable(String), default: nil
        const :callee, T.nilable(String), default: nil
        const :stdlib, T.nilable(T.any(T::Boolean, String)), default: nil
        const :unknown_reasons, T.nilable(T::Array[String]), default: nil

        def to_source_index_hash
          out = { "kind" => kind }
          out["callee"] = callee unless callee.nil?
          out["type"] = return_type unless return_type.nil?
          out["line"] = line
          out["code"] = code
          out["stdlib"] = stdlib unless stdlib.nil?
          out["unknown_reasons"] = unknown_reasons unless unknown_reasons.nil?
          out
        end
      end

      class MethodParameterRecord < T::Struct
        const :name, String
        const :nil_default, T::Boolean
        const :param_type, T.nilable(String)

        def to_source_index_hash
          { "name" => name, "nil_default" => nil_default, "type" => param_type }
        end
      end

      class MethodContainerOriginRecord < T::Struct
        const :name, String
        const :param_type, T.nilable(String)
        const :path, String
        const :line, Integer

        def to_source_index_hash
          { "kind" => "method parameter", "name" => name, "type" => param_type, "path" => path, "line" => line }
        end
      end

      class MethodRecord < T::Struct
        const :path, String
        const :line, Integer
        const :end_line, Integer
        const :owner, String
        const :method_name, String
        const :method_kind, String
        const :has_sig, T::Boolean
        const :sig, T.nilable(String)
        const :params, T::Array[MethodParameterRecord]
        const :scope, T::Array[String]
        const :non_nil_params, T::Array[String]
        const :uses_yield, T::Boolean
        const :untraceable_params, T::Array[String]
        const :protocols, T::Hash[String, ParamProtocolRecord]
        const :noreturn_candidate, T::Boolean

        def to_source_index_hash
          {
            "path" => path,
            "line" => line,
            "end_line" => end_line,
            "class" => owner,
            "method" => method_name,
            "kind" => method_kind,
            "has_sig" => has_sig,
            "sig" => sig,
            "params" => TypedRecords.serialize_value(params),
            "scope" => scope,
            "non_nil_params" => non_nil_params,
            "uses_yield" => uses_yield,
            "untraceable_params" => untraceable_params,
            "protocols" => TypedRecords.serialize_hash(protocols),
            "noreturn_candidate" => noreturn_candidate,
          }
        end
      end

      class SummaryRecord < T::Struct
        const :method_count, Integer
        const :unsigned_methods, Integer
        const :tlet_sites, Integer
        const :candidate_tlet_sites, Integer
        const :dead_nil_checks, Integer
        const :structs, Integer
        const :tuple_arrays, Integer
        const :hash_shapes, Integer
        const :collection_index_lookups, Integer
        const :type_normalizers, Integer
        const :deterministic_guards, Integer
        const :return_origins, Integer
        const :param_origins, Integer
        const :return_usage_sites, Integer
        const :hash_record_escape_sites, Integer
        const :hidden_enum_observations, Integer

        def to_source_index_hash
          {
            "methods" => method_count,
            "unsigned_methods" => unsigned_methods,
            "tlet_sites" => tlet_sites,
            "candidate_tlet_sites" => candidate_tlet_sites,
            "dead_nil_checks" => dead_nil_checks,
            "structs" => structs,
            "tuple_arrays" => tuple_arrays,
            "hash_shapes" => hash_shapes,
            "collection_index_lookups" => collection_index_lookups,
            "type_normalizers" => type_normalizers,
            "deterministic_guards" => deterministic_guards,
            "return_origins" => return_origins,
            "param_origins" => param_origins,
            "return_usage_sites" => return_usage_sites,
            "hash_record_escape_sites" => hash_record_escape_sites,
            "hidden_enum_observations" => hidden_enum_observations,
          }
        end
      end

      class ReturnOriginRecord < T::Struct
        const :path, String
        const :line, Integer
        const :end_line, Integer
        const :owner, String
        const :method_name, String
        const :method_kind, String
        const :implicit, T::Boolean
        const :return_syntax, String
        const :control_shape, String
        const :candidate_type, String
        const :confidence, String
        const :sources, T::Array[ReturnSourceRecord]
        const :blockers, T::Array[String]
        const :hash_shape, T.nilable(HashShapeRecord)
        const :array_element_shape, T.nilable(HashShapeRecord)

        def to_source_index_hash
          {
            "path" => path,
            "line" => line,
            "end_line" => end_line,
            "class" => owner,
            "method" => method_name,
            "kind" => method_kind,
            "implicit" => implicit,
            "return_syntax" => return_syntax,
            "control_shape" => control_shape,
            "candidate_type" => candidate_type,
            "confidence" => confidence,
            "sources" => TypedRecords.serialize_value(sources),
            "blockers" => blockers,
            "hash_shape" => TypedRecords.serialize_value(hash_shape),
            "array_element_shape" => TypedRecords.serialize_value(array_element_shape),
          }
        end
      end

      class StructDeclarationRecord < T::Struct
        const :path, String
        const :line, Integer
        const :owner, String
        const :fields, T::Array[String]

        def to_source_index_hash
          { "path" => path, "line" => line, "class" => owner, "fields" => fields }
        end
      end

      class IncludedModuleRecord < T::Struct
        const :path, String
        const :line, Integer
        const :owner, String
        const :module_name, String

        def to_source_index_hash
          { "path" => path, "line" => line, "class" => owner, "module" => module_name }
        end
      end

      class SorbetStateFieldRecord < T::Struct
        const :path, String
        const :line, Integer
        const :owner, String
        const :field, String
        const :declared_type, String

        def to_source_index_hash
          { "path" => path, "line" => line, "class" => owner, "field" => field, "type" => declared_type }
        end
      end

      class StructFieldStaticRecord < T::Struct
        const :path, String
        const :line, Integer
        const :owner, String
        const :field, String
        const :static_type, T.nilable(String)
        const :expression, String

        def to_source_index_hash
          { "path" => path, "line" => line, "class" => owner, "field" => field, "type" => static_type, "expression" => expression }
        end
      end

      class TupleArrayRecord < T::Struct
        const :path, String
        const :line, Integer
        const :size, Integer
        const :types, T::Array[String]
        const :confidence, String
        const :code, String

        def to_source_index_hash
          { "path" => path, "line" => line, "size" => size, "types" => types, "confidence" => confidence, "code" => code }
        end
      end

      class HashShapeObservationRecord < T::Struct
        const :path, String
        const :line, Integer
        const :keys, T::Array[String]
        const :value_types, T::Array[T.nilable(String)]
        const :value_hash_shapes, T::Hash[String, HashShapeRecord]
        const :value_array_element_shapes, T::Hash[String, HashShapeRecord]
        const :code, String

        def to_source_index_hash
          {
            "path" => path,
            "line" => line,
            "keys" => keys,
            "value_types" => value_types,
            "value_hash_shapes" => TypedRecords.serialize_hash(value_hash_shapes),
            "value_array_element_shapes" => TypedRecords.serialize_hash(value_array_element_shapes),
            "code" => code,
          }
        end
      end

      class ContainerOriginRecord < T::Struct
        const :kind, String
        const :name, T.nilable(String), default: nil
        const :path, T.nilable(String), default: nil
        const :line, T.nilable(Integer), default: nil
        const :code, T.nilable(String), default: nil
        const :array_element_types, T.nilable(T::Array[String]), default: nil
        const :hash_key_types, T.nilable(T::Array[String]), default: nil
        const :hash_value_types, T.nilable(T::Array[String]), default: nil
        const :alias_of, T.nilable(String), default: nil
        const :callee, T.nilable(String), default: nil
        const :receiver, T.nilable(String), default: nil
        const :param_type, T.nilable(String), default: nil
        const :shape, T.nilable(HashShapeRecord), default: nil

        def to_source_index_hash
          out = { "kind" => kind }
          out["name"] = name unless name.nil?
          out["type"] = param_type unless param_type.nil?
          out["path"] = path unless path.nil?
          out["line"] = line unless line.nil?
          out["code"] = code unless code.nil?
          out["array_element_types"] = array_element_types unless array_element_types.nil?
          out["hash_key_types"] = hash_key_types unless hash_key_types.nil?
          out["hash_value_types"] = hash_value_types unless hash_value_types.nil?
          out["alias_of"] = alias_of unless alias_of.nil?
          out["callee"] = callee unless callee.nil?
          out["receiver"] = receiver unless receiver.nil?
          out["shape"] = shape.to_source_index_hash unless shape.nil?
          out
        end

        def self.from_hash(hash)
          new(
            kind: hash["kind"].to_s,
            name: hash["name"]&.to_s,
            path: hash["path"]&.to_s,
            line: hash["line"],
            code: hash["code"]&.to_s,
            array_element_types: hash["array_element_types"],
            hash_key_types: hash["hash_key_types"],
            hash_value_types: hash["hash_value_types"],
            alias_of: hash["alias_of"]&.to_s,
            callee: hash["callee"]&.to_s,
            receiver: hash["receiver"]&.to_s,
            param_type: hash["type"]&.to_s,
            shape: HashShapeRecord.from(hash["shape"]),
          )
        end

        def merge(overrides)
          self.class.from_hash(to_source_index_hash.merge(TypedRecords.serialize_hash(overrides)))
        end
      end

      class CollectionIndexLookupRecord < T::Struct
        const :path, String
        const :line, Integer
        const :enclosing_scope, String
        const :code, String
        const :receiver, String
        const :index, String
        const :receiver_type, T.nilable(String)
        const :index_type, T.nilable(String)
        const :lookup_type, T.nilable(String)
        const :status, String
        const :origin, T.nilable(ContainerOriginRecord)

        def to_source_index_hash
          {
            "path" => path,
            "line" => line,
            "enclosing_scope" => enclosing_scope,
            "code" => code,
            "receiver" => receiver,
            "index" => index,
            "receiver_type" => receiver_type,
            "index_type" => index_type,
            "lookup_type" => lookup_type,
            "status" => status,
            "origin" => TypedRecords.serialize_value(origin),
          }
        end
      end

      class HashRecordBlockerRecord < T::Struct
        const :path, String
        const :line, Integer
        const :enclosing_scope, String
        const :kind, String
        const :code, String
        const :receiver, String
        const :origin, ContainerOriginRecord
        const :message, String
        const :index, T.nilable(String), default: nil

        def to_source_index_hash
          out = {
            "path" => path,
            "line" => line,
            "enclosing_scope" => enclosing_scope,
            "kind" => kind,
            "code" => code,
            "receiver" => receiver,
          }
          out["index"] = index unless index.nil?
          out["origin"] = origin.to_source_index_hash
          out["message"] = message
          out
        end
      end

      class HashRecordMemberCallRecord < T::Struct
        const :path, String
        const :line, Integer
        const :enclosing_scope, String
        const :field, String
        const :member, String
        const :code, String
        const :lookup_code, String
        const :receiver, T.nilable(String)
        const :origin, ContainerOriginRecord

        def to_source_index_hash
          {
            "path" => path,
            "line" => line,
            "enclosing_scope" => enclosing_scope,
            "field" => field,
            "member" => member,
            "code" => code,
            "lookup_code" => lookup_code,
            "receiver" => receiver,
            "origin" => origin.to_source_index_hash,
          }
        end
      end

      class DispatcherInferenceRecord < T::Struct
        const :path, String
        const :line, Integer
        const :owner, String
        const :method_kind, String
        const :dispatcher, String
        const :helper, String
        const :inferred_type, String
        const :classes, T::Array[String]

        def to_source_index_hash
          {
            "path" => path,
            "line" => line,
            "class" => owner,
            "kind" => method_kind,
            "dispatcher" => dispatcher,
            "helper" => helper,
            "type" => inferred_type,
            "classes" => classes,
          }
        end
      end

      class DispatchArmRecord < T::Struct
        const :helper, String
        const :classes, T::Array[String]

        def to_source_index_hash
          { "helper" => helper, "classes" => classes }
        end
      end

      class ParamOriginRecord < T::Struct
        const :path, String
        const :line, Integer
        const :enclosing_scope, String
        const :callee, String
        const :arg_kind, String
        const :slot, String
        const :origin_kind, String
        const :receiver, T.nilable(String)
        const :source_method, T.nilable(String)
        const :arg_type, T.nilable(String)
        const :code, String
        const :hash_shape, T.nilable(HashShapeRecord)
        const :array_element_shape, T.nilable(HashShapeRecord)
        const :unknown_reasons, T::Array[String]

        def to_source_index_hash
          {
            "path" => path,
            "line" => line,
            "enclosing_scope" => enclosing_scope,
            "callee" => callee,
            "arg_kind" => arg_kind,
            "slot" => slot,
            "origin_kind" => origin_kind,
            "receiver" => receiver,
            "source_method" => source_method,
            "type" => arg_type,
            "code" => code,
            "hash_shape" => TypedRecords.serialize_value(hash_shape),
            "array_element_shape" => TypedRecords.serialize_value(array_element_shape),
            "unknown_reasons" => unknown_reasons,
          }
        end
      end

      class TLetSiteRecord < T::Struct
        const :path, String
        const :line, Integer
        const :tlet, T::Boolean
        const :sorbet_type, T.nilable(String), default: nil
        const :name, T.nilable(String), default: nil
        const :candidate_type, T.nilable(String), default: nil

        def to_source_index_hash
          out = { "path" => path, "line" => line, "tlet" => tlet }
          out["name"] = name unless name.nil?
          out["candidate_type"] = candidate_type unless candidate_type.nil?
          out["type"] = sorbet_type unless sorbet_type.nil?
          out
        end
      end

      class DeadNilCheckRecord < T::Struct
        const :path, String
        const :line, Integer
        const :kind, String
        const :code, String
        const :reason, String

        def to_source_index_hash
          { "path" => path, "line" => line, "kind" => kind, "code" => code, "reason" => reason }
        end
      end

      class TypeNormalizerRecord < T::Struct
        const :path, String
        const :line, Integer
        const :owner, String
        const :method_name, String
        const :code, String
        const :origin_kind, String
        const :origin_name, T.nilable(String)

        def to_source_index_hash
          {
            "path" => path,
            "line" => line,
            "class" => owner,
            "method" => method_name,
            "code" => code,
            "origin_kind" => origin_kind,
            "origin_name" => origin_name,
          }
        end
      end

      class HiddenEnumSlotRecord < T::Struct
        const :key, String
        const :kind, String
        const :path, String
        const :line, Integer
        const :owner, String
        const :method_name, T.nilable(String)
        const :method_kind, T.nilable(String)
        const :slot, String
        const :slot_type, String

        def to_source_index_hash
          {
            "key" => key,
            "kind" => kind,
            "path" => path,
            "line" => line,
            "owner" => owner,
            "method" => method_name,
            "method_kind" => method_kind,
            "slot" => slot,
            "type" => slot_type,
          }
        end
      end

      class HiddenEnumValueRecord < T::Struct
        const :kind, String
        const :value, String

        def to_source_index_hash
          { "kind" => kind, "value" => value }
        end
      end

      class HiddenEnumSiteRecord < T::Struct
        const :path, String
        const :line, Integer
        const :kind, String
        const :code, String

        def to_source_index_hash
          { "path" => path, "line" => line, "kind" => kind, "code" => code }
        end
      end

      class HiddenEnumObservationRecord < T::Struct
        const :slot, HiddenEnumSlotRecord
        const :values, T::Array[HiddenEnumValueRecord]
        const :site, HiddenEnumSiteRecord

        def to_source_index_hash
          slot.to_source_index_hash.merge(
            "event" => "decision",
            "values" => TypedRecords.serialize_value(values),
            "site" => site.to_source_index_hash,
          )
        end
      end

      class RescueHandlerRecord < T::Struct
        const :path, String
        const :line, Integer
        const :kind, String
        const :method_name, T.nilable(String)

        def to_source_index_hash
          { "path" => path, "line" => line, "kind" => kind, "method" => method_name }
        end
      end

      class ReturnUsageSiteRecord < T::Struct
        const :path, String
        const :line, Integer
        const :name, String
        const :context, String
        const :current_method, T.nilable(String)
        const :handler_line, T.nilable(Integer)
        const :code, String

        def to_source_index_hash
          {
            "path" => path,
            "line" => line,
            "name" => name,
            "context" => context,
            "current_method" => current_method,
            "handler_line" => handler_line,
            "code" => code,
          }
        end
      end

      class HashRecordEscapeSiteRecord < T::Struct
        const :path, String
        const :line, Integer
        const :code, String
        const :escapes_collection, T::Boolean
        const :reason, String

        def to_source_index_hash
          { "path" => path, "line" => line, "code" => code, "escapes_collection" => escapes_collection, "reason" => reason }
        end
      end

      class DeterministicGuardResultRecord < T::Struct
        const :truth_value, T::Boolean
        const :predicate_kind, String
        const :reason, String
        const :origin_kind, T.nilable(String)
        const :origin_name, T.nilable(String)

        def to_source_index_hash
          {
            "truth_value" => truth_value,
            "proof_tier" => "static_proven",
            "predicate_kind" => predicate_kind,
            "reason" => reason,
            "origin_kind" => origin_kind,
            "origin_name" => origin_name,
          }
        end
      end

      class DeterministicGuardRecord < T::Struct
        const :path, String
        const :line, Integer
        const :owner, T.nilable(String)
        const :method_name, T.nilable(String)
        const :code, String
        const :branch_kind, String
        const :truth_value, T::Boolean
        const :taken_branch, String
        const :proof_tier, String
        const :predicate_kind, String
        const :reason, String
        const :origin_kind, T.nilable(String)
        const :origin_name, T.nilable(String)

        def to_source_index_hash
          {
            "path" => path,
            "line" => line,
            "class" => owner,
            "method" => method_name,
            "code" => code,
            "branch_kind" => branch_kind,
            "truth_value" => truth_value,
            "taken_branch" => taken_branch,
            "proof_tier" => proof_tier,
            "predicate_kind" => predicate_kind,
            "reason" => reason,
            "origin_kind" => origin_kind,
            "origin_name" => origin_name,
          }
        end
      end

      class CollectionTypeInfoRecord < T::Struct
        const :kind, String
        const :element, T.nilable(String), default: nil
        const :key, T.nilable(String), default: nil
        const :value, T.nilable(String), default: nil

        def to_source_index_hash
          out = { "kind" => kind }
          out["element"] = element unless element.nil?
          out["key"] = key unless key.nil?
          out["value"] = value unless value.nil?
          out
        end
      end

      [
        MethodParameterRecord,
        MethodContainerOriginRecord,
        MethodRecord,
        ParamProtocolRecord,
        ReturnSourceRecord,
        ReturnOriginRecord,
        ContainerOriginRecord,
        StructDeclarationRecord,
        IncludedModuleRecord,
        SorbetStateFieldRecord,
        StructFieldStaticRecord,
        DispatchArmRecord,
        HiddenEnumSlotRecord,
        HiddenEnumValueRecord,
        HiddenEnumSiteRecord,
        DeterministicGuardResultRecord,
        CollectionTypeInfoRecord,
      ].each { |record_class| record_class.include(RecordHashAccess) }

      end
    end
  end
end
