require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe 'BG profile metadata' do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it 'emits a stable metadata comment and local dispatch fields for plain BG' do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void ->
          f = BG {
              1;
          };
          ASSERT (NEXT f) == 1, "result";
      END
    CLEAR

    expect(zig).to include('CLEAR_PROFILE_TASK_SITE')
    expect(zig).to include('kind=BG')
    expect(zig).to include('line=2')
    expect(zig).to include('dispatch=local')
    expect(zig).to include('form=fsm')
    expect(zig).to include('.profile_site_id = 1')
    expect(zig).to include('.profile_dispatch = 1')
    expect(zig).to include('.profile_site_id = 1')
  end

  it 'marks @parallel BG sites as parallel in metadata and task config' do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void ->
          f = BG { @parallel ->
              1;
          };
          ASSERT (NEXT f) == 1, "result";
      END
    CLEAR

    expect(zig).to include('CLEAR_PROFILE_TASK_SITE')
    expect(zig).to include('dispatch=parallel')
    expect(zig).to include('.profile_dispatch = 2')
  end

  it 'emits stackful BG profile metadata when @stack forces a fiber' do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Void ->
          f = BG { @stack ->
              1;
          };
          ASSERT (NEXT f) == 1, "result";
      END
    CLEAR

    expect(zig).to include('CLEAR_PROFILE_TASK_SITE')
    expect(zig).to include('form=stack')
    expect(zig).to include('.profile_site_id = 1')
    expect(zig).to include('.profile_dispatch = 1')
  end
end
