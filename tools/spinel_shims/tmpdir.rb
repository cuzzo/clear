# frozen_string_literal: true

# `require "tmpdir"` is a dead require on the compile path -- Dir.mktmpdir has
# no call site there. Present only so the require resolves.
