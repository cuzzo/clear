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
      keys = Hash(left["keys"]).keys | Hash(right["keys"]).keys
      {
        "keys" => keys.each_with_object({}) do |key, merged|
          out_key = shape_key(key, stringify_keys)
          merged[out_key] = (Array(left.dig("keys", key)) + Array(right.dig("keys", key))).uniq
        end,
        "value_hash_shapes" => merge_nested_shape_maps(left["value_hash_shapes"], right["value_hash_shapes"], stringify_keys: stringify_keys),
        "value_array_element_shapes" => merge_nested_shape_maps(left["value_array_element_shapes"], right["value_array_element_shapes"], stringify_keys: stringify_keys),
        "poisoned" => false,
      }
    end

    def merge_nested_shape_maps(left, right, stringify_keys: false)
      keys = Hash(left).keys | Hash(right).keys
      keys.each_with_object({}) do |key, merged|
        l = Hash(left)[key]
        r = Hash(right)[key]
        out_key = shape_key(key, stringify_keys)
        merged[out_key] = l && r ? merge_shapes(l, r, stringify_keys: stringify_keys) : dup_shape(l || r, stringify_keys: stringify_keys)
      end
    end

    def poisoned_shape
      { "keys" => {}, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => true }
    end

    def shape_key(key, stringify)
      stringify ? key.to_s : key
    end
  end
end
