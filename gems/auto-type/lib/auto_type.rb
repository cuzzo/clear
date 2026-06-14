# typed: false
# frozen_string_literal: true

require "fileutils"
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

module AutoType
  def self.target_files
    NilKill.target_files
  end

  def self.rel(path)
    NilKill.rel(path)
  end
end

require_relative "auto_type/apply"
require_relative "auto_type/providers/ruby"
require_relative "auto_type/interactive_review"
require_relative "auto_type/loop"
require_relative "auto_type/guarded_autocorrect"
require_relative "auto_type/cli"
