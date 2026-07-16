# typed: false
# frozen_string_literal: true

require "pathname"
require "set"

require_relative "root"
require_relative "type_profile"

module Espalier
  ROOT = File.expand_path("../../../..", __dir__) unless const_defined?(:ROOT, false)

  HIGH = "high"
  REVIEW = "review"
  GAP = "gap"
  MAX_UNION_TYPES = 3

  module_function

  def target_dirs(root: ROOT)
    ENV.fetch("ESPALIER_TARGETS", ENV.fetch("NIL_KILL_TARGETS", "src"))
      .split(File::PATH_SEPARATOR)
      .map { |path| File.expand_path(path, root) }
  end

  def target_exclude_dirs(root: ROOT)
    ENV.fetch("ESPALIER_EXCLUDE_TARGETS", ENV.fetch("NIL_KILL_EXCLUDE_TARGETS", ""))
      .split(File::PATH_SEPARATOR)
      .reject(&:empty?)
      .map { |path| File.expand_path(path, root) }
  end

  def target_excluded?(path, root: ROOT)
    abs = File.expand_path(path, root)
    target_exclude_dirs(root: root).any? { |dir| abs == dir || abs.start_with?(dir + File::SEPARATOR) }
  end

  def rel(path, root: ROOT)
    Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
  rescue StandardError
    path.to_s
  end

  def useful_type?(type)
    ruby_type_profile.useful_type?(type)
  end

  def static_sorbet_type(types)
    ruby_type_profile.static_type(types)
  end

  def normalize_static_sorbet_type(type)
    ruby_type_profile.normalize_static_type(type)
  end

  def extract_call_args(source, name)
    FactMine::Syntax.type_profile(:generic).extract_call_args(source, name)
  end

  def split_top_level(source)
    FactMine::Syntax.type_profile(:generic).split_top_level(source)
  end

  def broad_union_type?(type, max: MAX_UNION_TYPES)
    ruby_type_profile.broad_union_type?(type, max: max)
  end

  def extract_param_entries(sig)
    ruby_type_profile.extract_param_entries(sig)
  end

  def extract_return_type(sig)
    ruby_type_profile.extract_return_type(sig)
  end

  def strip_nilable_type(type)
    ruby_type_profile.strip_nilable_type(type)
  end

  def type_profile_for(language = nil, type_system: nil)
    FactMine::Syntax.type_profile(language || :generic, type_system: type_system)
  rescue StandardError
    FactMine::Syntax.type_profile(:generic)
  end

  def ruby_type_profile
    type_profile_for(:ruby, type_system: "sorbet")
  end
end
