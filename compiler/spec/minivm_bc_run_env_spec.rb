require "rspec"

require_relative "../../examples/minivm/bc_run"

RSpec.describe "MiniVM bc_run clear-build environment" do
  around do |example|
    old_trace = ENV["NIL_KILL_TRACE"]
    old_rubyopt = ENV["RUBYOPT"]
    example.run
  ensure
    ENV["NIL_KILL_TRACE"] = old_trace
    ENV["RUBYOPT"] = old_rubyopt
  end

  it "scrubs RUBYOPT during normal runner builds" do
    ENV.delete("NIL_KILL_TRACE")
    ENV["RUBYOPT"] = "-rnot_for_clear"

    expect(Object.new.send(:clear_build_env)["RUBYOPT"]).to be_nil
  end

  it "preserves RUBYOPT while nil-kill source instrumentation is active" do
    ENV["NIL_KILL_TRACE"] = "1"
    ENV["RUBYOPT"] = "-r./gems/nil-kill/ext/nil_kill_trace/nil_kill_trace.so"

    expect(Object.new.send(:clear_build_env)["RUBYOPT"]).to eq("-r./gems/nil-kill/ext/nil_kill_trace/nil_kill_trace.so")
  end
end
