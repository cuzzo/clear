# typed: false
# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "pathname"
require "set"
require "shellwords"

begin
  require "nil_kill"
rescue LoadError
  require_relative "../../nil-kill/lib/nil_kill"
end

require_relative "auto_type/adapters/nil_kill"
require_relative "auto_type/text_edit"
require_relative "auto_type/rewrite_plan"
require_relative "auto_type/workspace"
require_relative "auto_type/providers/base"
require_relative "auto_type/providers/registry"
require_relative "auto_type/providers/ruby"
require_relative "auto_type/providers/python"

module AutoType
  def self.nil_kill
    @nil_kill ||= NilKillAdapter.new
  end

  def self.root
    nil_kill.root
  end

  def self.tmp_dir
    nil_kill.tmp_dir
  end

  def self.evidence
    nil_kill.evidence
  end

  def self.target_files
    nil_kill.target_files
  end

  def self.rel(path)
    nil_kill.rel(path)
  end

  def self.high_confidence
    nil_kill.high_confidence
  end

  def self.review_confidence
    nil_kill.review_confidence
  end

  def self.ensure_src_restored!
    nil_kill.ensure_src_restored!
  end

  def self.syntax
    nil_kill.syntax
  end
end

require_relative "auto_type/apply"
require_relative "auto_type/interactive_review"
require_relative "auto_type/loop"
require_relative "auto_type/guarded_autocorrect"
require_relative "auto_type/cli"
