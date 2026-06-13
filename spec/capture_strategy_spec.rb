require "rspec"
require "set"

require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../src/ast/type" unless defined?(Type)
require_relative "../src/semantic/capture_strategy" unless defined?(CaptureStrategy::CaptureSiteInfo)

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
end
