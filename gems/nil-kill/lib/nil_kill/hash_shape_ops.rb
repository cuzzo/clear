# typed: false
# frozen_string_literal: true

module NilKill
  module HashShapeOps
    module_function

    def dup_shape(shape, stringify_keys: false)
      return nil unless shape
      {
        "keys" => Hash[Hash(shape["keys"]).map { |key, types| [shape_key(key, stringify_keys), Array(types).dup] }],
        "value_hash_shapes" => Hash[Hash(shape["value_hash_shapes"]).map { |key, nested| [shape_key(key, stringify_keys), dup_shape(nested, stringify_keys: stringify_keys)] }],
        "value_array_element_shapes" => Hash[Hash(shape["value_array_element_shapes"]).map { |key, nested| [shape_key(key, stringify_keys), dup_shape(nested, stringify_keys: stringify_keys)] }],
        "poisoned" => !!shape["poisoned"],
      }
    end

    def merge_shapes(left, right, stringify_keys: false)
      return poisoned_shape if left["poisoned"] || right["poisoned"]
      merged_keys = {}
      Hash(left["keys"]).each do |key, types|
        out_key = shape_key(key, stringify_keys)
        merged_keys[out_key] ||= []
        merged_keys[out_key].concat(Array(types))
      end
      Hash(right["keys"]).each do |key, types|
        out_key = shape_key(key, stringify_keys)
        merged_keys[out_key] ||= []
        merged_keys[out_key].concat(Array(types))
      end
      merged_keys.each { |_, v| v.uniq! }

      {
        "keys" => merged_keys,
        "value_hash_shapes" => merge_nested_shape_maps(left["value_hash_shapes"], right["value_hash_shapes"], stringify_keys: stringify_keys),
        "value_array_element_shapes" => merge_nested_shape_maps(left["value_array_element_shapes"], right["value_array_element_shapes"], stringify_keys: stringify_keys),
        "poisoned" => false,
      }
    end

    def merge_nested_shape_maps(left, right, stringify_keys: false)
      merged = {}
      Hash(left).each do |key, shape|
        out_key = shape_key(key, stringify_keys)
        merged[out_key] = dup_shape(shape, stringify_keys: stringify_keys)
      end
      Hash(right).each do |key, shape|
        out_key = shape_key(key, stringify_keys)
        if merged.key?(out_key)
          merged[out_key] = merge_shapes(merged[out_key], shape, stringify_keys: stringify_keys)
        else
          merged[out_key] = dup_shape(shape, stringify_keys: stringify_keys)
        end
      end
      merged
    end

    def poisoned_shape
      { "keys" => {}, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => true }
    end

    def shape_key(key, stringify)
      stringify ? key.to_s : key
    end
  end
end
