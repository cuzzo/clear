# typed: false
# frozen_string_literal: true
#
# The sealed workload: load every lib via its DESIGNATED load path and
# call each method once with a concrete (non-nil) value. Every step is
# fault-isolated so one failure does not hide the rest -- a missing
# record then surfaces as a precise guarantee-spec failure, not a
# blanket abort. __dir__ resolves to the real corpus dir (in-place
# wrapping keeps the file at its real path).

require "rbconfig"

here = __dir__

step = lambda do |label, &blk|
  blk.call
rescue StandardError, LoadError, ScriptError => e
  warn "workload step #{label} failed: #{e.class}: #{e.message}"
end

# 1. bare require via $LOAD_PATH
step.call("plain_require") do
  $LOAD_PATH.unshift(here) unless $LOAD_PATH.include?(here)
  require "plain_require_lib"
  PlainReq.new.transform(21)
end

# 2. require_relative + endless def
step.call("require_relative") do
  require_relative "require_relative_lib"
  RelReq.new.calc(42)
end

# 3. Kernel#load + splat/kwsplat/block
step.call("kernel_load") do
  load File.join(here, "kernel_load_lib.rb")
  KernelLoad.new.handle({ n: 1 }, 2, 3, k: 9) { 4 }
end

# 4. autoload
step.call("autoload") do
  Object.autoload(:AutoLib, File.join(here, "autoload_lib.rb"))
  AutoLib.new.one_line("hi")
end

# 5. absolute-path require + recursive-from-.each (collect_bg_blocks shape)
step.call("abs_require") do
  require File.expand_path("abs_require_lib.rb", here)
  AbsReq.new.run([{ a: [1] }, 2, { b: { c: [3] } }])
end

# 6. reached ONLY through a spawned ruby child (re-exec boundary). The
#    child inherits RUBYOPT + NIL_KILL_* so it traces and dumps its own
#    runtime jsonl into the shared RUNTIME_DIR.
step.call("subprocess") do
  sub = File.expand_path("subprocess_lib.rb", here)
  code = "require #{sub.inspect}; SubProc.new.in_child('xyz-payload')"
  pid = Process.spawn(RbConfig.ruby, "-e", code)
  Process.wait(pid)
end

# 7. ensure body source wrapping
step.call("ensure_punt") do
  require_relative "ensure_punt_lib"
  EnsurePunt.new.guarded(7)
end

# 8. Struct field + T.let + collection element
step.call("struct_collection") do
  require_relative "struct_collection_lib"
  StructColl.new.build([1, 2, 3])
end
