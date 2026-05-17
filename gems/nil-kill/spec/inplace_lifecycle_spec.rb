# frozen_string_literal: true
#
# Crash-safety contract for B1 in-place instrumentation: snapshot ->
# wrap-in-place -> byte-perfect restore, idempotent, sentinel-driven
# self-heal. This is the safety net that lets `collect` mutate the
# real src tree.

require_relative "spec_helper"

RSpec.describe "in-place instrumentation lifecycle" do
  def corpus_with_sigd_method
    dir = Dir.mktmpdir("nk-inplace", NilKill::ROOT)
    File.write(File.join(dir, "a.rb"), <<~RUBY)
      # typed: false
      require "sorbet-runtime"
      class A
        extend T::Sig
        sig { params(x: T.untyped).returns(T.untyped) }
        def go(x)
          y = x + 1
          y * 2
        end
      end
    RUBY
    dir
  end

  it "snapshots pristine, wraps the real file in place, restores byte-perfect" do
    dir = corpus_with_sigd_method
    a = File.join(dir, "a.rb")
    pristine = File.read(a)
    snap = File.join(NilKill::TMP_DIR, "src-snapshot")
    manifest = nil
    isolated_env("NIL_KILL_TARGETS" => dir, "NIL_KILL_INSTRUMENTED_ROOT" => nil) do
      NilKill::TracePlan.write(NilKill::TRACE_PLAN_PATH)
      manifest = NilKill::SourceInstrumenter.new.run_in_place(snap)
    end
    rel = NilKill.rel(a)
    expect(manifest).to include(rel)
    # wrapped in place at the REAL path
    expect(File.read(a)).to include("NilKillRuntimeTrace.record_source_method_call")
    expect(File.read(a)).not_to eq(pristine)
    # snapshot holds the exact pristine bytes
    expect(File.binread(File.join(snap, rel))).to eq(pristine)
    # linemap written under RUNTIME_DIR (where the child reads it)
    expect(File.file?(File.join(NilKill::RUNTIME_DIR, ".nk-linemap.json"))).to be(true)

    NilKill.write_inplace_sentinel!(snap, manifest)
    expect(JSON.parse(File.read(NilKill.inplace_sentinel_path))).to include("files" => manifest)

    expect(NilKill.restore_inplace_snapshot!).to be(true)
    expect(File.read(a)).to eq(pristine)
    expect(File.file?(NilKill.inplace_sentinel_path)).to be(false)
    # idempotent: a second restore (ensure + trap + next-run all call it)
    expect(NilKill.restore_inplace_snapshot!).to be(false)
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  it "ensure_src_restored! heals a crashed collect (sentinel present), else no-op" do
    dir = corpus_with_sigd_method
    a = File.join(dir, "a.rb")
    pristine = File.read(a)
    snap = File.join(NilKill::TMP_DIR, "src-snapshot")
    isolated_env("NIL_KILL_TARGETS" => dir, "NIL_KILL_INSTRUMENTED_ROOT" => nil) do
      NilKill::TracePlan.write(NilKill::TRACE_PLAN_PATH)
      m = NilKill::SourceInstrumenter.new.run_in_place(snap)
      # simulate a crash: sentinel on disk, src still wrapped, process dies
      NilKill.write_inplace_sentinel!(snap, m)
    end
    expect(File.read(a)).not_to eq(pristine) # wrapped (crashed state)

    # next nil-kill process startup self-heals
    expect { NilKill.ensure_src_restored! }.to output(/Restoring pristine sources/).to_stderr
    expect(File.read(a)).to eq(pristine)

    # no sentinel -> silent no-op, no restore work
    expect { NilKill.ensure_src_restored! }.not_to output.to_stderr
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  it "restore tolerates a not-yet-wrapped file (crash mid-wrap is still healed)" do
    dir = corpus_with_sigd_method
    snap = File.join(NilKill::TMP_DIR, "src-snapshot")
    # sentinel lists a file that was never snapshotted (crash before its
    # cp). restore must skip it (already pristine) and not blow up.
    FileUtils.mkdir_p(snap)
    NilKill.write_inplace_sentinel!(snap, ["src/never_wrapped.rb"])
    expect(NilKill.restore_inplace_snapshot!).to be(true)
    expect(File.file?(NilKill.inplace_sentinel_path)).to be(false)
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end
end
