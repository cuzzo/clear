# typed: false
# frozen_string_literal: true

module AutoType
  class Workspace
    attr_reader :root

    def initialize(root: AutoType.root)
      @root = File.expand_path(root)
    end

    def absolute_path(path)
      raw = path.to_s
      raise ArgumentError, "path is required" if raw.empty?

      expanded = if Pathname.new(raw).absolute?
        File.expand_path(raw)
      else
        File.expand_path(raw, root)
      end
      unless expanded == root || expanded.start_with?("#{root}#{File::SEPARATOR}")
        raise ArgumentError, "path escapes workspace root: #{path}"
      end
      expanded
    end

    def file?(path)
      File.file?(absolute_path(path))
    end

    def read(path)
      File.read(absolute_path(path))
    end

    def read_lines(path)
      File.readlines(absolute_path(path))
    end

    def write(path, content)
      File.write(absolute_path(path), content)
    end

    def digest(path)
      Digest::SHA256.file(absolute_path(path)).hexdigest
    end

    def snapshot(paths)
      Array(paths).each_with_object({}) do |path, snap|
        abs = absolute_path(path)
        snap[abs] = File.read(abs) if File.file?(abs)
      end
    end

    def restore(snapshot)
      snapshot.each { |path, content| File.write(absolute_path(path), content) }
    end

    def apply_text_edits(path, edits)
      normalized = Array(edits).map do |edit|
        edit.is_a?(TextEdit) ? edit : TextEdit.new(
          path: edit.fetch("path", path),
          start_offset: edit.fetch("start_offset"),
          end_offset: edit.fetch("end_offset"),
          replacement: edit.fetch("replacement"),
        )
      end
      return false if normalized.empty?

      source = read(path)
      write(path, apply_edits_to_source(source, normalized))
      true
    end

    def apply_edits_to_source(source, edits)
      bytes = source.b
      non_overlapping_edits(edits).sort_by { |edit| -edit.start_offset }.each do |edit|
        bytes = bytes.byteslice(0, edit.start_offset) +
          edit.replacement.b +
          bytes.byteslice(edit.end_offset..).to_s
      end
      bytes
    end

    def non_overlapping_edits(edits)
      kept = []
      Array(edits).sort_by { |edit| [edit.start_offset, -(edit.end_offset - edit.start_offset)] }.each do |edit|
        next if kept.any? { |existing| edit.start_offset >= existing.start_offset && edit.end_offset <= existing.end_offset }
        if kept.any? { |existing| edit.start_offset < existing.end_offset && edit.end_offset > existing.start_offset }
          raise ArgumentError, "overlapping text edits for #{edit.path}"
        end
        kept << edit
      end
      kept
    end
  end
end
