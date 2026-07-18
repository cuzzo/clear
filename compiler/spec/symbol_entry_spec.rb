require_relative "../ruby/ast/symbol_entry" unless defined?(SymbolEntry::BindingLifecycleFacts)
require_relative "../ruby/ast/ast" unless defined?(AST::Param)
require "set"

RSpec.describe SymbolEntry do
  def symbol_entry(type: :Int64, mutable: true, storage: :stack, sync: nil, layout: nil)
    SymbolEntry.new(
      reg: :some_node,
      type: type,
      mutable: mutable,
      storage: storage,
      sync: sync,
      layout: layout,
      size: 8,
      capabilities: Set[:RESTRICT]
    )
  end

  let(:entry) do
    symbol_entry(sync: :locked)
  end

  describe "attr_accessor" do
    it "provides typed field access" do
      expect(entry.type).to eq(:Int64)
      expect(entry.mutable).to eq(true)
      expect(entry.storage).to eq(:stack)
      expect(entry.sync).to eq(:locked)
      expect(entry.size).to eq(8)
      expect(entry.valid).to eq(true)
    end

    it "allows direct mutation" do
      entry.storage = :heap
      expect(entry.storage).to eq(:heap)
    end
  end

  describe "generated lifecycle accessors" do
    it "reads and writes every lifecycle-backed field" do
      close_plan = Schemas::ResourceClosePlan.method("close")
      async_shape = AsyncResultShape.promise(Type.new(:String), shared: true)
      fn_sig = FunctionSignature.new(params: [], return_type: Type.new(:Bool))

      entry.async_result_shape = async_shape
      entry.type = fn_sig
      entry.storage = :heap
      entry.sync = :atomic
      entry.layout = :indirect
      entry.resource = true
      entry.close_plan = close_plan
      entry.ownership_kind = :affine
      entry.takes = true
      entry.is_param = true
      entry.link_source = :source_name

      expect(entry.async_result_shape).to equal(async_shape)
      expect(entry.fn_signature).to equal(fn_sig)
      expect(entry.storage).to eq(:heap)
      expect(entry.sync).to eq(:atomic)
      expect(entry.layout).to eq(:indirect)
      expect(entry.resource).to eq(true)
      expect(entry.close_plan).to equal(close_plan)
      expect(entry.ownership_kind).to eq(:affine)
      expect(entry.takes).to be(true)
      expect(entry.is_param).to be(true)
      expect(entry.link_source).to eq(:source_name)
    end
  end

  describe "generated flow accessors" do
    it "reads every flow fact from the flow object" do
      flow = entry.send(:flow_facts)
      flow.non_escaping = true
      flow.borrowed_alias = true
      flow.valid = false
      flow.invalid_reason = "moved"
      flow.read = true
      flow.mutated = true
      flow.mutable_ref_target = true
      flow.poly_borrow_target = true
      flow.init_contents_heap = true

      expect(entry.non_escaping).to be(true)
      expect(entry.borrowed_alias).to be(true)
      expect(entry.valid).to be(false)
      expect(entry.invalid_reason).to eq("moved")
      expect(entry.read).to be(true)
      expect(entry.mutated).to be(true)
      expect(entry.mutable_ref_target).to be(true)
      expect(entry.poly_borrow_target).to be(true)
      expect(entry.init_contents_heap).to be(true)
    end
  end

  describe "scope back-reference" do
    it "starts as nil (set by Scope#declare)" do
      expect(entry.scope).to be_nil
    end

    it "can be set and read" do
      entry.scope = :mock_scope
      expect(entry.scope).to eq(:mock_scope)
    end

    it "is preserved through dup" do
      entry.scope = :original_scope
      copy = entry.dup
      expect(copy.scope).to eq(:original_scope)
    end
  end

  describe "dup" do
    it "shares lifecycle facts and shallow-copies overlays" do
      copy = entry.dup
      expect(copy.type).to eq(:Int64)
      expect(copy.storage).to eq(:stack)
      expect(copy.lifecycle).to equal(entry.lifecycle)
      expect(copy.capabilities).to equal(entry.capabilities) # same object (shallow)
    end

    it "shares storage lifecycle changes across branch copies" do
      copy = entry.dup
      copy.storage = :heap

      expect(entry.storage).to eq(:heap)
    end

    it "forks binding flow facts when copied" do
      entry.mark_read!
      entry.mark_mutated!(touch_declaration: false)
      entry.mark_mutated_via_reference!
      entry.mark_poly_borrow_target!
      entry.mark_init_contents_heap!

      copy = entry.dup
      copy.mark_non_escaping!
      copy.invalidate!("branch-local invalidation")

      expect(copy.read).to eq(true)
      expect(copy.mutated).to eq(true)
      expect(copy.mutable_ref_target).to eq(true)
      expect(copy.poly_borrow_target).to eq(true)
      expect(copy.init_contents_heap).to eq(true)
      expect(copy.valid).to eq(false)
      expect(copy.invalid_reason).to eq("branch-local invalidation")

      expect(entry.non_escaping).to eq(false)
      expect(entry.valid).to eq(true)
      expect(entry.invalid_reason).to be_nil
    end

    it "forks lifetime source arrays when copied" do
      source = symbol_entry
      extra_source = symbol_entry
      entry.lifetime = [source]

      copy = entry.dup
      copy.lifetime << extra_source

      expect(copy.lifetime).to eq([source, extra_source])
      expect(entry.lifetime).to eq([source])
    end

    it "preserves stable binding identity across branch copies" do
      copy = entry.dup
      other = SymbolEntry.new(reg: :other_node, type: :Int64, mutable: true, storage: :stack)

      expect(copy.binding_id).to eq(entry.binding_id)
      expect(other.binding_id).not_to eq(entry.binding_id)
    end

    it "assigns consecutive binding identities to fresh entries" do
      first = symbol_entry.binding_id
      second = symbol_entry.binding_id
      third = symbol_entry.binding_id

      expect(second - first).to eq(1)
      expect(third - second).to eq(1)
    end
  end

  describe "defaults" do
    it "provides sensible defaults for optional fields" do
      minimal = SymbolEntry.new(reg: nil, type: :Bool, mutable: false, storage: :stack)
      expect(minimal.sync).to be_nil
      expect(minimal.rebindable).to eq(false)
      expect(minimal.size).to eq(0)
      expect(minimal.capabilities).to eq(Set.new)
      expect(minimal.valid).to eq(true)
      expect(minimal.invalid_reason).to be_nil
      expect(minimal.resource).to be_nil
      expect(minimal.close_plan).to be_nil
      expect(minimal.scope).to be_nil
      expect(minimal.scope_depth).to be_nil
      expect(minimal.param_decl_token).to be_nil
      expect(minimal.sync_families).to be_nil
      expect(minimal.lifetime).to eq([])
      expect(minimal.send(:flow_snapshot).valid).to be(true)
    end

    it "honors explicit constructor options" do
      close_plan = Schemas::ResourceClosePlan.function("cleanup")
      custom_caps = Set[:MUTABLE, :LOCKED]
      constructed = SymbolEntry.new(
        reg: :node,
        type: nil,
        mutable: false,
        storage: :shared,
        sync: :locked,
        layout: :indirect,
        rebindable: true,
        size: 16,
        capabilities: custom_caps,
        valid: false,
        invalid_reason: "stale",
        resource: true,
        close_plan: close_plan
      )

      expect(constructed.reg).to eq(:node)
      expect(constructed.type).to eq(Type.new(:Untyped))
      expect(constructed.mutable).to be(false)
      expect(constructed.storage).to eq(:shared)
      expect(constructed.sync).to eq(:locked)
      expect(constructed.layout).to eq(:indirect)
      expect(constructed.rebindable).to be(true)
      expect(constructed.size).to eq(16)
      expect(constructed.capabilities).to equal(custom_caps)
      expect(constructed.valid).to be(false)
      expect(constructed.invalid_reason).to eq("stale")
      expect(constructed.resource).to be(true)
      expect(constructed.close_plan).to equal(close_plan)
    end
  end

  describe "integration with scope locals iteration" do
    it "works in each { |name, info| info.type } pattern" do
      locals = { "x" => entry }
      result = nil
      locals.each { |_name, info| result = info.type }
      expect(result).to eq(:Int64)
    end
  end

  describe "sync classifiers" do
    it "classifies single sync values exactly" do
      expect(SymbolEntry.atomic_sync?(:atomic)).to be(true)
      expect(SymbolEntry.locked_sync?(:locked)).to be(true)
      expect(SymbolEntry.write_locked_sync?(:write_locked)).to be(true)
      expect(SymbolEntry.versioned_sync?(:versioned)).to be(true)
      expect(SymbolEntry.local_sync?(:local)).to be(true)
      expect(SymbolEntry.always_mutable_sync?(:always_mutable)).to be(true)

      expect(SymbolEntry.atomic_sync?(:locked)).to be(false)
      expect(SymbolEntry.locked_sync?(nil)).to be(false)
      expect(SymbolEntry.write_locked_sync?(:locked)).to be(false)
      expect(SymbolEntry.versioned_sync?(:always_mutable)).to be(false)
      expect(SymbolEntry.local_sync?(:heap)).to be(false)
      expect(SymbolEntry.always_mutable_sync?(:versioned)).to be(false)
    end

    it "classifies sync families" do
      expect(SymbolEntry.locked_family_sync?(:locked)).to be(true)
      expect(SymbolEntry.locked_family_sync?(:write_locked)).to be(true)
      expect(SymbolEntry.locked_family_sync?(:atomic)).to be(false)

      expect(SymbolEntry.cleanup_sync?(:locked)).to be(true)
      expect(SymbolEntry.cleanup_sync?(:write_locked)).to be(true)
      expect(SymbolEntry.cleanup_sync?(:always_mutable)).to be(true)
      expect(SymbolEntry.cleanup_sync?(:versioned)).to be(true)
      expect(SymbolEntry.cleanup_sync?(:atomic)).to be(false)
      expect(SymbolEntry.cleanup_sync?(nil)).to be(false)
    end

    it "exposes instance sync predicates" do
      expect(symbol_entry(sync: :atomic).atomic?).to be(true)
      expect(symbol_entry(sync: :locked).atomic?).to be(false)
      expect(symbol_entry(sync: :locked).locked?).to be(true)
      expect(symbol_entry(sync: :local).local?).to be(true)
      expect(symbol_entry(sync: :locked).local?).to be(false)
      expect(symbol_entry(sync: :write_locked).write_locked?).to be(true)
      expect(symbol_entry(sync: :atomic, layout: :indirect).atomic_ptr?).to be(true)
      expect(symbol_entry(sync: :atomic, layout: :direct).atomic_ptr?).to be(false)
      expect(symbol_entry(sync: :locked, layout: :indirect).atomic_ptr?).to be(false)
    end

    it "recognizes declared sync contracts from direct sync or family sets" do
      direct = symbol_entry(sync: :locked)
      from_family = symbol_entry(sync: nil)
      from_family.sync_families = Set[:locked, :atomic]
      missing = symbol_entry(sync: nil)
      missing.sync_families = Set.new
      invalid_family = symbol_entry(sync: nil)
      invalid_family.sync_families = [:locked]

      expect(direct.declared_sync_contract?).to be(true)
      expect(from_family.declared_sync_contract?).to be(true)
      expect(missing.declared_sync_contract?).to be(false)
      expect(invalid_family.declared_sync_contract?).to be(false)
    end
  end

  describe "storage and capture classifiers" do
    it "classifies storage values exactly" do
      expect(SymbolEntry.rc_storage?(:shared)).to be(true)
      expect(SymbolEntry.rc_storage?(:multiowned)).to be(true)
      expect(SymbolEntry.rc_storage?(:heap)).to be(false)
      expect(SymbolEntry.heap_storage_value?(:heap)).to be(true)
      expect(SymbolEntry.heap_storage_value?(:stack)).to be(false)
      expect(SymbolEntry.frame_storage_value?(:frame)).to be(true)
      expect(SymbolEntry.frame_storage_value?(:heap)).to be(false)
      expect(SymbolEntry.local_storage_value?(:local)).to be(true)
      expect(SymbolEntry.local_storage_value?(:shared)).to be(false)
    end

    it "exposes storage provenance predicates" do
      expect(symbol_entry(storage: :shared).rc_stored?).to be(true)
      expect(symbol_entry(storage: :multiowned).rc_stored?).to be(true)
      expect(symbol_entry(storage: :heap).heap_storage?).to be(true)
      expect(symbol_entry(storage: :frame).frame_provenance?).to be(true)
      expect(symbol_entry(storage: :heap).frame_provenance?).to be(false)
      expect(symbol_entry(storage: :rodata).rodata_provenance?).to be(true)
      expect(symbol_entry(storage: :borrow).borrow_provenance?).to be(true)
    end

    it "returns provenance only for storage values that encode provenance" do
      expect(symbol_entry(storage: :heap).provenance).to eq(:heap)
      expect(symbol_entry(storage: :frame).provenance).to eq(:frame)
      expect(symbol_entry(storage: :rodata).provenance).to eq(:rodata)
      expect(symbol_entry(storage: :borrow).provenance).to eq(:borrow)
      expect(symbol_entry(storage: :stack).provenance).to eq(:stack)
      expect(symbol_entry(storage: :shared).provenance).to be_nil
      expect(symbol_entry(storage: :local).provenance).to be_nil
    end

    it "classifies capture storage families" do
      expect(symbol_entry(sync: :locked).sync_or_shared_storage?).to be(true)
      expect(symbol_entry(storage: :shared).sync_or_shared_storage?).to be(true)
      expect(symbol_entry(storage: :local).sync_or_shared_storage?).to be(true)
      expect(symbol_entry(storage: :stack, sync: nil).sync_or_shared_storage?).to be(false)

      expect(symbol_entry(sync: :write_locked).boxed_capture_storage?).to be(true)
      expect(symbol_entry(storage: :local).boxed_capture_storage?).to be(true)
      expect(symbol_entry(storage: :shared).boxed_capture_storage?).to be(false)

      expect(symbol_entry(sync: :locked).affine_locked_capture?).to be(true)
      expect(symbol_entry(sync: :locked, storage: :shared).affine_locked_capture?).to be(false)
      expect(symbol_entry(storage: :stack, sync: nil).affine_locked_capture?).to be(false)
    end

    it "classifies with-match and plain-local families" do
      expect(symbol_entry(sync: :atomic).with_match_capability_family?).to be(true)
      expect(symbol_entry(storage: :shared).with_match_capability_family?).to be(true)
      expect(symbol_entry(storage: :local).with_match_capability_family?).to be(true)
      expect(symbol_entry(storage: :heap).with_match_capability_family?).to be(true)
      expect(symbol_entry(storage: :stack, sync: nil).with_match_capability_family?).to be(false)

      expect(symbol_entry(storage: :stack, sync: nil).plain_local_family?).to be(true)
      expect(symbol_entry(storage: :heap, sync: nil).plain_local_family?).to be(true)
      expect(symbol_entry(storage: :stack, sync: :locked).plain_local_family?).to be(false)
      expect(symbol_entry(storage: :shared, sync: nil).plain_local_family?).to be(false)
    end

    it "requires capture moves only for live resource or affine bindings" do
      resource = symbol_entry
      resource.ownership_kind = :resource
      affine = symbol_entry
      affine.ownership_kind = :affine
      plain = symbol_entry

      expect(resource.capture_move_required?(true)).to be(true)
      expect(resource.capture_move_required?(false)).to be(false)
      expect(affine.capture_move_required?(true)).to be(true)
      expect(plain.capture_move_required?(true)).to be(false)
    end

    it "requires live capture moves for slice-managed types" do
      string_entry = symbol_entry(type: :String)
      expect(string_entry.type.needs_escape_promotion?).to be(true)
      expect(string_entry.capture_move_required?(true)).to be(true)
      expect(string_entry.capture_move_required?(false)).to be(false)
    end
  end

  describe "flow markers" do
    it "marks reads and declaration mutations on compatible AST nodes" do
      reg = AST::VarDecl.new(nil, "x", nil, nil)
      reg.var_used = false
      reg.var_mutated = false
      tracked = SymbolEntry.new(reg: reg, type: :Int64, mutable: true, storage: :stack)

      tracked.mark_read!
      tracked.mark_mutated!(touch_declaration: true)

      expect(tracked.read).to be(true)
      expect(tracked.mutated).to be(true)
      expect(reg.var_used).to be(true)
      expect(reg.var_mutated).to be(true)
    end

    it "marks reference and borrow flow facts independently" do
      entry.mark_mutated_via_reference!
      entry.mark_poly_borrow_target!
      entry.mark_init_contents_heap!
      entry.mark_borrowed_alias!

      expect(entry.mutated).to be(true)
      expect(entry.mutable_ref_target).to be(true)
      expect(entry.poly_borrow_target).to be(true)
      expect(entry.init_contents_heap).to be(true)
      expect(entry.borrowed_alias).to be(true)
    end

    it "can clear non-escaping state without changing unconstrained bindings" do
      entry.mark_non_escaping!
      expect(entry.non_escaping).to be(true)
      expect(entry.lifetime).to eq([entry])

      entry.clear_non_escaping!
      expect(entry.non_escaping).to be(false)
      expect(entry.lifetime).to eq([])

      entry.clear_non_escaping!
      expect(entry.non_escaping).to be(false)
      expect(entry.lifetime).to eq([])
    end

    it "does not clear lifetime sources when the binding is not marked non-escaping" do
      source = symbol_entry
      entry.lifetime = [source]

      entry.clear_non_escaping!

      expect(entry.non_escaping).to be(false)
      expect(entry.lifetime).to eq([source])
    end
  end

  describe "flow snapshots" do
    it "copies every flow fact and remains independent from later mutation" do
      entry.mark_non_escaping!
      entry.mark_borrowed_alias!
      entry.invalidate!("invalid")
      entry.mark_read!
      entry.mark_mutated!(touch_declaration: false)
      entry.mark_mutated_via_reference!
      entry.mark_poly_borrow_target!
      entry.mark_init_contents_heap!

      snapshot = entry.send(:flow_snapshot)
      entry.clear_non_escaping!
      entry.invalidate!("changed")

      expect(snapshot.non_escaping).to be(true)
      expect(snapshot.borrowed_alias).to be(true)
      expect(snapshot.valid).to be(false)
      expect(snapshot.invalid_reason).to eq("invalid")
      expect(snapshot.read).to be(true)
      expect(snapshot.mutated).to be(true)
      expect(snapshot.mutable_ref_target).to be(true)
      expect(snapshot.poly_borrow_target).to be(true)
      expect(snapshot.init_contents_heap).to be(true)
    end
  end

  describe "lifetime normalization" do
    it "normalizes nil and current-scope lifetimes" do
      entry.lifetime = nil
      expect(entry.lifetime).to eq([])
      expect(entry.non_escaping).to be(false)

      entry.lifetime = { sources: nil }
      expect(entry.lifetime).to eq([])
      expect(entry.non_escaping).to be(false)

      entry.lifetime = :current_scope
      expect(entry.lifetime).to eq([entry])
      expect(entry.non_escaping).to be(true)
    end

    it "normalizes arrays and source hashes to unique SymbolEntry sources" do
      source_a = symbol_entry
      source_b = symbol_entry

      entry.lifetime = [source_a, source_b, source_a]
      expect(entry.lifetime).to eq([source_a, source_b])
      expect(entry.non_escaping).to be(false)

      entry.lifetime = { sources: [source_b, source_a, source_b] }
      expect(entry.lifetime).to eq([source_b, source_a])
    end

    it "rejects non-SymbolEntry lifetime sources" do
      expect { entry.lifetime = :unknown_source }
        .to raise_error(TypeError, "SymbolEntry#lifetime sources must be SymbolEntry instances")
      expect { entry.lifetime = { sources: [:bad] } }
        .to raise_error(TypeError, "SymbolEntry#lifetime sources must be SymbolEntry instances")
    end

    it "builds tied lifetimes from unique sources" do
      source_a = symbol_entry
      source_b = symbol_entry

      expect(SymbolEntry.tied_lifetime([])).to eq([])
      expect(SymbolEntry.tied_lifetime([source_a, source_b, source_a])).to eq([source_a, source_b])
    end
  end
end
