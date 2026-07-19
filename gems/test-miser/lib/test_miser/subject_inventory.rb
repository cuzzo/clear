# frozen_string_literal: true

require "pathname"

module TestMiser
  class SubjectInventory
    Entry = Struct.new(:expression, :scope, :file, :line, keyword_init: true) do
      def to_h = { expression: expression, scope: scope, file: file, line: line }
    end

    def initialize(namespace:, roots:)
      @namespace = namespace
      @roots = roots.map { |root| Pathname.new(root).expand_path.to_s }
    end

    def call
      ObjectSpace.each_object(Module).filter_map do |scope|
        next unless scope.name&.start_with?(@namespace)

        entries_for(scope)
      end.flatten.sort_by(&:expression)
    end

    private

    def entries_for(scope)
      instance_entries(scope) + singleton_entries(scope)
    end

    def instance_entries(scope)
      names = scope.instance_methods(false) +
        scope.private_instance_methods(false) +
        scope.protected_instance_methods(false)
      names.uniq.filter_map do |name|
        location = scope.instance_method(name).source_location
        entry(scope, name, "#", location)
      end
    end

    def singleton_entries(scope)
      scope.singleton_methods(false).filter_map do |name|
        location = scope.method(name).source_location
        next if module_function_copy?(scope, name, location)

        entry(scope, name, ".", location)
      end
    end

    def module_function_copy?(scope, name, location)
      scope.private_instance_methods(false).include?(name) &&
        scope.instance_method(name).source_location == location
    end

    def entry(scope, name, separator, location)
      return unless location

      path = Pathname.new(location.first).expand_path.to_s
      return unless @roots.any? { |root| path == root || path.start_with?("#{root}/") }

      Entry.new(
        expression: "#{scope.name}#{separator}#{name}",
        scope: scope.name,
        file: relative_path(path),
        line: location.last
      )
    end

    def relative_path(path)
      Pathname.new(path).relative_path_from(Pathname.pwd.expand_path).to_s
    rescue ArgumentError
      path
    end
  end
end
