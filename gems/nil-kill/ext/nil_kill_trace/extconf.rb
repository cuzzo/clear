# frozen_string_literal: true

require "mkmf"

$CFLAGS = "#{$CFLAGS} -O2"
create_makefile("nil_kill_trace/nil_kill_trace")
