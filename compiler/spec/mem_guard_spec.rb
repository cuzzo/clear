# frozen_string_literal: true

# tools/mem-guard and tools/zig-guard are shell, so their tests are shell too
# (tools/test/mem_guard_test.sh). This wrapper is what puts them in the Ruby
# suite, so a broken guard fails CI rather than waiting to be noticed the next
# time a zig run tries to take the machine down.
#
# The slow end-to-end case -- a real `clear build` proving the ZIG constant
# routes through the wrapper -- runs only with SLOW=1.
require 'open3'

RSpec.describe 'tools/mem-guard and tools/zig-guard' do
  it 'passes its behavioural suite with full line coverage' do
    root = File.expand_path('../..', __dir__)
    script = File.join(root, 'tools', 'test', 'mem_guard_test.sh')
    out, status = Open3.capture2e({ 'COVERAGE' => '1' }, script, chdir: root)

    aggregate_failures do
      expect(status).to be_success, "guard suite failed:\n#{out}"
      expect(out).to match(/mem-guard\s+\d+\/\d+ lines = 100\.0%/), "mem-guard not fully covered:\n#{out}"
      expect(out).to match(/zig-guard\s+\d+\/\d+ lines = 100\.0%/), "zig-guard not fully covered:\n#{out}"
      expect(out).to include('0 failed')
    end
  end
end
