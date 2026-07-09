# frozen_string_literal: true

require "json"

module RubyToClear
  class HelperConfig
    attr_reader :requires

    def self.load(value)
      case value
      when nil
        new
      when HelperConfig
        value
      when String
        new(JSON.parse(File.read(value)))
      when Hash
        new(value)
      else
        raise ArgumentError, "Unsupported helper config: #{value.class}"
      end
    end

    def initialize(data = {})
      data ||= {}
      @requires = Array(data["requires"] || data[:requires])
      @prelude = Array(data["prelude"] || data[:prelude])
      @helpers = data["helpers"] || data[:helpers] || {}
      @types = data["types"] || data[:types] || {}
      @scanner_receivers = Array(
        data["scanner_receivers"] ||
        data[:scanner_receivers] ||
        @helpers["scanner_receivers"] ||
        @helpers[:scanner_receivers]
      )
    end

    def require_lines
      @requires.map do |entry|
        text = entry.to_s
        text.start_with?("REQUIRE ") ? text : "REQUIRE #{text.inspect}"
      end
    end

    def prelude_lines
      @prelude.map(&:to_s)
    end

    def helper?(name)
      helper_entry(name) != nil
    end

    def call(name, args)
      entry = helper_entry(name)
      return nil unless entry

      render_helper(entry, args)
    end

    def call_or(name, fallback_name, args)
      call(name, args) || "#{fallback_name}(#{args.join(', ')})"
    end

    def regex_literal(pattern_code)
      call(:regex_literal, [pattern_code]) || pattern_code
    end

    def regex_interpolated_literal(pattern_code)
      call(:regex_interpolated_literal, [pattern_code]) || regex_literal(pattern_code)
    end

    def scanner_receiver?(receiver_code)
      return false if @scanner_receivers.empty?

      @scanner_receivers.include?(receiver_code.to_s)
    end

    def clear_type(ruby_type)
      @types[ruby_type.to_s] || @types[ruby_type.to_sym]
    end

    private

    def helper_entry(name)
      @helpers[name.to_s] || @helpers[name.to_sym]
    end

    def render_helper(entry, args)
      case entry
      when Hash
        template = entry["template"] || entry[:template]
        return render_template(template.to_s, args) if template

        name = entry["name"] || entry[:name]
        return "#{name}(#{args.join(', ')})" if name
      when String
        return render_template(entry, args) if entry.include?("$")

        return "#{entry}(#{args.join(', ')})"
      end

      raise ArgumentError, "Invalid helper config entry: #{entry.inspect}"
    end

    def render_template(template, args)
      rendered = template.dup
      args.each_with_index do |arg, index|
        rendered = rendered.gsub("$#{index + 1}", arg.to_s)
      end
      rendered.gsub("$args", args.join(", "))
    end
  end
end
