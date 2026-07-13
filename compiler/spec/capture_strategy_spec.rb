require "rspec"
require "set"

require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/type" unless defined?(Type)
require_relative "../ruby/semantic/capture_strategy" unless defined?(CaptureStrategy::CaptureSiteInfo)

RSpec.describe CaptureStrategy do
  let(:empty_site) { CaptureStrategy::CaptureSiteInfo.empty }

  def t(raw, **opts) = Type.new(raw, **opts)

  def classify(name: "x", type:, site_info: empty_site)
    CaptureStrategy.classify(name: name, type: type, site_info: site_info)
  end

  # ----------------------------------------------------------------
  # ByValue — primitives and rodata string slices
  # ----------------------------------------------------------------
  describe "ByValue: primitives and rodata strings" do
    %i[Int64 Float64 Bool Int8 Int16 Int32 UInt8 UInt16 UInt32 UInt64].each do |raw|
      it "classifies #{raw} as ByValue" do
        strat = classify(type: t(raw))
        expect(strat).to be_a(CaptureStrategy::ByValue)
        expect(strat.marker_plan).to be_empty
        expect(strat.needs_capture_site_annotation?).to be false
      end
    end

    it "classifies rodata String as ByValue" do
      strat = classify(type: t(:String, location: :rodata))
      expect(strat).to be_a(CaptureStrategy::ByValue)
    end
  end

  # ----------------------------------------------------------------
  # RcClone — @multiowned / @shared
  # ----------------------------------------------------------------
  describe "RcClone: @multiowned and @shared" do
    it "classifies @multiowned struct as RcClone" do
      strat = classify(type: t(:Counter, ownership: :multiowned))
      expect(strat).to be_a(CaptureStrategy::RcClone)
      expect(strat.marker_plan).to be_empty
    end

    it "classifies @shared struct as RcClone" do
      strat = classify(type: t(:Counter, ownership: :shared))
      expect(strat).to be_a(CaptureStrategy::RcClone)
    end

    it "classifies @indirect:atomic as an internally retained RcClone" do
      type = t(:Counter, sync: :atomic, layout: :indirect)
      strat = classify(type: type)
      expect(strat).to be_a(CaptureStrategy::RcClone)
      expect(CaptureStrategy.field_zig_type(type)).to eq("*CheatLib.AtomicPtr(Counter)")
    end
  end

  # ----------------------------------------------------------------
  # FreshHeapCopy — owned aggregate captures get a fiber-owned duplicate
  # ----------------------------------------------------------------
  describe "FreshHeapCopy: owned aggregate captures" do
    it "classifies managed String capture as FreshHeapCopy" do
      strat = classify(type: t(:String))
      expect(strat).to be_a(CaptureStrategy::FreshHeapCopy)
      expect(strat.alloc_sym).to eq(:heap)
    end

    it "classifies @list local capture as FreshHeapCopy" do
      strat = classify(type: t(:"Int64[]", collection: :list))
      expect(strat).to be_a(CaptureStrategy::FreshHeapCopy)
      expect(strat.alloc_sym).to eq(:heap)
    end
  end

  # ----------------------------------------------------------------
  # MoveInto — resources and affine promise handles transfer ownership
  # ----------------------------------------------------------------
  describe "MoveInto: resources and affine promises" do
    it "classifies resource captures as MoveInto even when the type is value-like" do
      strat = CaptureStrategy.classify(
        name: "fd",
        type: t(:Int64),
        site_info: empty_site,
        is_resource: true,
      )

      expect(strat).to be_a(CaptureStrategy::MoveInto)
      expect(strat.source_name).to eq("fd")
      expect(strat.zig_type).to eq("i64")
    end

    it "classifies single affine promise handles as MoveInto" do
      strat = classify(type: t(:"~Int64"))

      expect(strat).to be_a(CaptureStrategy::MoveInto)
      expect(strat.marker_plan).to contain_exactly(
        have_attributes(source_name: "x")
      )
    end

    it "does not treat streams as single affine promise handles" do
      expect(CaptureStrategy.owned_affine_promise_handle?(t(:"~Int64[]"))).to eq(false)
      expect(CaptureStrategy.owned_affine_promise_handle?(t(:"~Int64@shared"))).to eq(false)
      expect(classify(type: t(:"~Int64[]"))).not_to be_a(CaptureStrategy::MoveInto)
    end
  end

  # ----------------------------------------------------------------
  # ByValue — pinned synchronized collections stay on the pinned path
  # ----------------------------------------------------------------
  describe "ByValue: pinned synchronized collections" do
    it "classifies synchronized collection captures as ByValue for the pinned lowering path" do
      strat = classify(name: "xs", type: t(:"Int64[]", collection: :list, sync: :locked))

      expect(strat).to be_a(CaptureStrategy::ByValue)
      expect(strat.ctx_init_name).to eq("xs")
      expect(strat.zig_type).to eq("*CheatLib.Locked(std.ArrayListUnmanaged(i64))")
      expect(CaptureStrategy.pinned_sync_collection?(t(:"Int64[]", collection: :list, sync: :locked))).to eq(true)
      expect(CaptureStrategy.pinned_sync_collection?(t(:"Int64[]", collection: :list))).to eq(false)
    end
  end

  # ----------------------------------------------------------------
  # Refuse — pointer-passed / borrow without explicit transfer
  # ----------------------------------------------------------------
  describe "Refuse: pointer-passed / borrow without COPY or GIVE at capture site" do
    it "refuses @pool local capture" do
      strat = classify(type: t(:"Env[100]", collection: :pool))
      expect(strat).to be_a(CaptureStrategy::Refuse)
      # @pool satisfies needs_pointer_passing, so reason prefers pointer-passed
      expect(strat.reason).to eq(:pointer_passed_without_transfer)
    end

    it "classifies slice (Int64[]) capture as FreshHeapCopy" do
      strat = classify(type: t(:"Int64[]"))
      expect(strat).to be_a(CaptureStrategy::FreshHeapCopy)
      expect(strat.alloc_sym).to eq(:heap)
    end

    it "refuses HashMap capture" do
      strat = classify(type: t(:"HashMap<Int64>"))
      expect(strat).to be_a(CaptureStrategy::Refuse)
      expect(strat.reason).to eq(:pointer_passed_without_transfer)
    end
  end

  # ----------------------------------------------------------------
  # MoveInto — user wrote GIVE x at the BG capture site
  # ----------------------------------------------------------------
  describe "MoveInto: explicit GIVE at capture site" do
    let(:site) { CaptureStrategy::CaptureSiteInfo.new(copied_names: Set.new, moved_names: Set["xs"]) }

    it "classifies primitive values as MoveInto when GIVE is present" do
      strat = CaptureStrategy.classify(
        name: "xs",
        type: t(:Int64),
        site_info: site,
      )

      expect(strat).to be_a(CaptureStrategy::MoveInto)
      expect(strat.zig_type).to eq("i64")
      expect(strat.source_name).to eq("xs")
    end

    it "classifies @list as MoveInto when GIVE is present" do
      strat = CaptureStrategy.classify(
        name: "xs",
        type: t(:"Int64[]", collection: :list),
        site_info: site,
      )
      expect(strat).to be_a(CaptureStrategy::MoveInto)
      expect(strat.source_name).to eq("xs")
      expect(strat.marker_plan).to contain_exactly(have_attributes(source_name: "xs"))
    end

    it "classifies slice as MoveInto when GIVE is present" do
      strat = CaptureStrategy.classify(
        name: "xs",
        type: t(:"Int64[]"),
        site_info: site,
      )
      expect(strat).to be_a(CaptureStrategy::MoveInto)
    end

    it "does not refuse when the user gave ownership away" do
      strat = CaptureStrategy.classify(
        name: "xs",
        type: t(:"Int64[]"),
        site_info: site,
      )
      expect(strat).not_to be_a(CaptureStrategy::Refuse)
    end
  end

  # ----------------------------------------------------------------
  # FreshHeapCopy — user wrote COPY x at the BG capture site
  # ----------------------------------------------------------------
  describe "FreshHeapCopy: explicit COPY at capture site" do
    let(:site) { CaptureStrategy::CaptureSiteInfo.new(copied_names: Set["xs"], moved_names: Set.new) }

    it "classifies primitive values as FreshHeapCopy when COPY is present" do
      strat = CaptureStrategy.classify(
        name: "xs",
        type: t(:Int64),
        site_info: site,
      )

      expect(strat).to be_a(CaptureStrategy::FreshHeapCopy)
      expect(strat.zig_type).to eq("i64")
      expect(strat.ctx_init_name).to eq("xs")
      expect(strat.marker_plan).to contain_exactly(
        an_instance_of(CaptureStrategy::AllocMarkPlan).and(have_attributes(ctx_init_name: "xs", alloc_sym: :heap)),
        an_instance_of(CaptureStrategy::CleanupPlan).and(have_attributes(ctx_init_name: "xs", alloc_sym: :heap))
      )
    end

    it "classifies @list as FreshHeapCopy when COPY is present" do
      strat = CaptureStrategy.classify(
        name: "xs",
        type: t(:"Int64[]", collection: :list),
        site_info: site,
      )
      expect(strat).to be_a(CaptureStrategy::FreshHeapCopy)
      expect(strat.alloc_sym).to eq(:heap)
      expect(strat.marker_plan).to contain_exactly(
        an_instance_of(CaptureStrategy::AllocMarkPlan).and(have_attributes(ctx_init_name: "xs", alloc_sym: :heap)),
        an_instance_of(CaptureStrategy::CleanupPlan).and(have_attributes(ctx_init_name: "xs", alloc_sym: :heap))
      )
    end

    it "classifies slice as FreshHeapCopy when COPY is present" do
      strat = CaptureStrategy.classify(
        name: "xs",
        type: t(:"Int64[]"),
        site_info: site,
      )
      expect(strat).to be_a(CaptureStrategy::FreshHeapCopy)
    end
  end

  # ----------------------------------------------------------------
  # Exhaustiveness — no silent fall-through
  # ----------------------------------------------------------------
  describe "Exhaustiveness" do
    it "always returns exactly one of the five strategy variants" do
      types_to_try = [
        t(:Int64),
        t(:Float64),
        t(:Bool),
        t(:String),
        t(:String, location: :rodata),
        t(:Counter, ownership: :multiowned),
        t(:Counter, ownership: :shared),
        t(:"Int64[]", collection: :list),
        t(:"Env[100]", collection: :pool),
        t(:"HashMap<Int64>"),
        t(:"Int64[]"),
      ]
      types_to_try.each do |type|
        strat = classify(type: type)
        variants = [
          CaptureStrategy::ByValue, CaptureStrategy::RcClone,
          CaptureStrategy::FreshHeapCopy, CaptureStrategy::MoveInto,
          CaptureStrategy::Refuse,
        ]
        expect(variants).to include(strat.class),
          "type #{type.inspect} produced unexpected strategy class #{strat.class}"
      end
    end

    it "never silently produces ByValue for heap-backed types (the gap that caused Bug #3)" do
      heap_backed = [
        t(:"Int64[]", collection: :list),
        t(:"Value[]", collection: :list),
        t(:String),
        t(:"Env[100]", collection: :pool),
        t(:"HashMap<Int64>"),
        t(:"Int64[]"),  # slice — borrow of some owner
      ]
      heap_backed.each do |type|
        strat = classify(type: type)
        expect(strat).not_to be_a(CaptureStrategy::ByValue),
          "heap-backed #{type.inspect} was silently classified as ByValue; this is the dangling-pointer gap"
      end
    end
  end

  # ----------------------------------------------------------------
  # CaptureSiteInfo
  # ----------------------------------------------------------------
  describe "CaptureSiteInfo" do
    it "exposes copied?/moved? predicates" do
      info = CaptureStrategy::CaptureSiteInfo.new(copied_names: Set["a"], moved_names: Set["b"])
      expect(info.copied?("a")).to be true
      expect(info.copied?("b")).to be false
      expect(info.moved?("b")).to be true
      expect(info.moved?("a")).to be false
    end

    it "builds an empty info cleanly" do
      info = CaptureStrategy::CaptureSiteInfo.empty
      expect(info.copied?("x")).to be false
      expect(info.moved?("x")).to be false
    end
  end

  describe "helper predicates" do
    it "selects field Zig types for pointer-passed and ordinary values" do
      expect(CaptureStrategy.field_zig_type(t(:Int64))).to eq("i64")
      expect(CaptureStrategy.field_zig_type(t(:"Env[100]", collection: :pool))).to eq("*CheatLib.Pool(Env)")
    end

    it "classifies value-like and deep-copy capture shapes directly" do
      expect(CaptureStrategy.value_like?(t(:Bool))).to eq(true)
      expect(CaptureStrategy.value_like?(t(:String, location: :rodata))).to eq(true)
      expect(CaptureStrategy.value_like?(t(:String))).to eq(false)
      expect(CaptureStrategy.deep_copy_capture?(t(:String))).to eq(true)
      expect(CaptureStrategy.deep_copy_capture?(t(:"HashMap<Int64>"))).to eq(false)
      expect(CaptureStrategy.deep_copy_capture?(t(:"~Int64"))).to eq(false)
    end

    it "reports specific refusal reasons in priority order" do
      expect(CaptureStrategy.refuse_reason_for(t(:"Env[100]", collection: :pool))).to eq(:pointer_passed_without_transfer)
      expect(CaptureStrategy.refuse_reason_for(t(:"Int64[]", collection: :list))).to eq(:list_borrow_without_transfer)
      expect(CaptureStrategy.refuse_reason_for(t(:"Int64[]"))).to eq(:array_borrow_without_transfer)
      expect(CaptureStrategy.refuse_reason_for(t(:String, location: :heap))).to eq(:heap_backed_without_transfer)
      expect(CaptureStrategy.refuse_reason_for(t(:Bool))).to eq(:unclassified_capture)
    end
  end
end
