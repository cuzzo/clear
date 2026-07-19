require 'rspec'
require 'tmpdir'
require 'open3'

require_relative '../../tools/fuzz/semantic_advanced'

RSpec.describe 'SemanticAdvanced allocation-fault oracle', :integration do
  clear = File.expand_path('../../clear', __dir__)

  it 'executes every generated allocation-fault recovery witness' do
    SemanticAdvanced.allocation_fault_cases.each do |entry|
      Dir.mktmpdir("semantic-oom-#{entry.id}") do |dir|
        source = File.join(dir, 'case.clear')
        binary = File.join(dir, 'case-bin')
        File.write(source, entry.source)
        build_out, build_status = Open3.capture2e(clear, 'build', source, '-o', binary)
        expect(build_status).to be_success, "#{entry.id} build failed:\n#{build_out}"

        out, status = Open3.capture2e({ 'CLEAR_OOM_AFTER' => entry.oom_after.to_s }, binary)
        expect(status).to be_success, "#{entry.id} fault run failed:\n#{out}"
        expect(out).to include(entry.expected_output)
        expect(out).not_to match(/System\/OutOfMemory/)
        expect(entry.trace.outcome).to eq(:return)
      end
    end
  end
end
