# typed: false
# frozen_string_literal: true

module AutoType
  class TextEdit
    attr_reader :path, :start_offset, :end_offset, :replacement

    def initialize(path:, start_offset:, end_offset:, replacement:)
      @path = path.to_s
      @start_offset = Integer(start_offset)
      @end_offset = Integer(end_offset)
      @replacement = replacement.to_s
      raise ArgumentError, "path is required" if @path.empty?
      raise ArgumentError, "start_offset must be non-negative" if @start_offset.negative?
      raise ArgumentError, "end_offset must be >= start_offset" if @end_offset < @start_offset
    end

    def to_h
      {
        "path" => path,
        "start_offset" => start_offset,
        "end_offset" => end_offset,
        "replacement" => replacement,
      }
    end
  end
end
