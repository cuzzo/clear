# frozen_string_literal: true

module MiniVM
  module Register
    # Capacity caps for the register VM register files.
    #
    # Tune by editing the constants below. `validate_vm_cht!` checks that
    # vm.cht's pre-fill loops match (so the runtime has slots for every
    # register the allocator may emit). The allocator rewriter enforces
    # the caps statically at compile time and raises OverRegisterCap if a
    # program needs more registers than the cap allows.
    module RegisterFileLimits
      I = 512
      F = 512
      S = 256

      class OverRegisterCap < StandardError; end

      ALL = { i: I, f: F, s: S }.freeze

      # Verifies vm.cht declares each register file as a raw fixed-size
      # array sized at exactly the corresponding cap. Mismatches raise --
      # tuning a cap means editing both this file and the vm.cht decl.
      def self.validate_vm_cht!(vm_path = File.join(__dir__, "vm.cht"))
        source = File.read(vm_path)
        observed = {
          i: scan_decl_size(source, "iregs", "Int64"),
          f: scan_decl_size(source, "fregs", "Float64"),
          s: scan_decl_size(source, "sregs", "String"),
        }
        ALL.each do |kind, cap|
          actual = observed.fetch(kind)
          if actual.nil?
            raise "RegisterFileLimits drift: vm.cht has no `MUTABLE #{kind}regs: ...[N]` declaration"
          end
          if actual != cap
            raise "RegisterFileLimits drift: vm.cht declares #{kind}regs as size #{actual}, " \
                  "but RegisterFileLimits::#{kind.upcase} = #{cap}. " \
                  "Update both to match."
          end
        end
        true
      end

      # Matches `MUTABLE iregs: Int64[512]` (with or without `;` and any
      # capability suffix). Returns the integer N or nil.
      def self.scan_decl_size(source, name, elem_type)
        m = source.match(/MUTABLE\s+#{Regexp.escape(name)}\s*:\s*#{Regexp.escape(elem_type)}\s*\[\s*(\d+)\s*\]/)
        m && m[1].to_i
      end
    end

    module OpcodeSpec
      Opcode = Struct.new(:name, :code, :arity, :vm_name, :operands, keyword_init: true)

      OPCODES = [
        Opcode.new(name: :ICONST, code: 0, arity: 2, vm_name: "IConst"),
        Opcode.new(name: :IRET, code: 1, arity: 1, vm_name: "IRet"),
        Opcode.new(name: :HALT, code: 2, arity: 0, vm_name: "Halt"),
        Opcode.new(name: :IMOV, code: 3, arity: 2, vm_name: "IMov"),
        Opcode.new(name: :IADD, code: 4, arity: 3, vm_name: "IAdd"),
        Opcode.new(name: :ISUB, code: 5, arity: 3, vm_name: "ISub"),
        Opcode.new(name: :IMUL, code: 6, arity: 3, vm_name: "IMul"),
        Opcode.new(name: :IDIV, code: 7, arity: 3, vm_name: "IDiv"),
        Opcode.new(name: :ILT, code: 8, arity: 3, vm_name: "ILt"),
        Opcode.new(name: :IGT, code: 9, arity: 3, vm_name: "IGt"),
        Opcode.new(name: :IEQ, code: 10, arity: 3, vm_name: "IEq"),
        Opcode.new(name: :INEQ, code: 11, arity: 3, vm_name: "INeq"),
        Opcode.new(name: :ILTE, code: 12, arity: 3, vm_name: "ILte"),
        Opcode.new(name: :IGTE, code: 13, arity: 3, vm_name: "IGte"),
        Opcode.new(name: :JMP, code: 14, arity: 1, vm_name: "Jmp"),
        Opcode.new(name: :JF, code: 15, arity: 2, vm_name: "Jf"),
        Opcode.new(name: :FCONST, code: 16, arity: 2, vm_name: "FConst"),
        Opcode.new(name: :FRET, code: 17, arity: 1, vm_name: "FRet"),
        Opcode.new(name: :FMOV, code: 18, arity: 2, vm_name: "FMov"),
        Opcode.new(name: :FADD, code: 19, arity: 3, vm_name: "FAdd"),
        Opcode.new(name: :FSUB, code: 20, arity: 3, vm_name: "FSub"),
        Opcode.new(name: :FMUL, code: 21, arity: 3, vm_name: "FMul"),
        Opcode.new(name: :FDIV, code: 22, arity: 3, vm_name: "FDiv"),
        Opcode.new(name: :FLT, code: 23, arity: 3, vm_name: "FLt"),
        Opcode.new(name: :FGT, code: 24, arity: 3, vm_name: "FGt"),
        Opcode.new(name: :FEQ, code: 25, arity: 3, vm_name: "FEq"),
        Opcode.new(name: :FNEQ, code: 26, arity: 3, vm_name: "FNeq"),
        Opcode.new(name: :FLTE, code: 27, arity: 3, vm_name: "FLte"),
        Opcode.new(name: :FGTE, code: 28, arity: 3, vm_name: "FGte"),
        Opcode.new(name: :IMOD, code: 29, arity: 3, vm_name: "IMod"),
        Opcode.new(name: :ICALL, code: 30, arity: :call, vm_name: "ICall"),
        Opcode.new(name: :FCALL, code: 31, arity: :call, vm_name: "FCall"),
        Opcode.new(name: :NCALL, code: 32, arity: :native_call, vm_name: "NCall"),
        Opcode.new(name: :IPRINT, code: 33, arity: 3, vm_name: "IPrint"),
        Opcode.new(name: :IPRINT2, code: 37, arity: 5, vm_name: "IPrint2"),
        Opcode.new(name: :SCONST, code: 38, arity: 2, vm_name: "SConst"),
        Opcode.new(name: :SRET, code: 39, arity: 1, vm_name: "SRet"),
        Opcode.new(name: :SMOV, code: 40, arity: 2, vm_name: "SMov"),
        Opcode.new(name: :SCONCAT, code: 41, arity: 3, vm_name: "SConcat"),
        Opcode.new(name: :LNEW, code: 42, arity: 1, vm_name: "LNew"),
        Opcode.new(name: :LAPPENDI, code: 43, arity: 2, vm_name: "LAppendI"),
        Opcode.new(name: :LGETI, code: 44, arity: 3, vm_name: "LGetI"),
        Opcode.new(name: :LLEN, code: 45, arity: 2, vm_name: "LLen"),
        Opcode.new(name: :MNEW, code: 46, arity: 1, vm_name: "MNew"),
        Opcode.new(name: :MPUTI, code: 47, arity: 3, vm_name: "MPutI"),
        Opcode.new(name: :MGETI, code: 48, arity: 4, vm_name: "MGetI"),
        Opcode.new(name: :LFNEW, code: 49, arity: 1, vm_name: "LFNew"),
        Opcode.new(name: :LFAPPEND, code: 50, arity: 2, vm_name: "LFAppend"),
        Opcode.new(name: :LFGET, code: 51, arity: 3, vm_name: "LFGet"),
        Opcode.new(name: :SEQ, code: 52, arity: 3, vm_name: "SEq"),
        Opcode.new(name: :LSSET, code: 53, arity: 3, vm_name: "LSSet"),
        Opcode.new(name: :LSETI, code: 54, arity: 3, vm_name: "LSetI"),
        Opcode.new(name: :LFSET, code: 55, arity: 3, vm_name: "LFSet"),
        Opcode.new(name: :LFLEN, code: 56, arity: 2, vm_name: "LFLen"),
        Opcode.new(name: :MLEN, code: 57, arity: 2, vm_name: "MLen"),
        Opcode.new(name: :MCONTAINS, code: 58, arity: 3, vm_name: "MContains"),
        Opcode.new(name: :MDELETE, code: 59, arity: 2, vm_name: "MDelete"),
        Opcode.new(name: :NMPUTI, code: 60, arity: 3, vm_name: "NMPutI"),
        Opcode.new(name: :NMGETI, code: 61, arity: 4, vm_name: "NMGetI"),
        Opcode.new(name: :NMCONTAINS, code: 62, arity: 3, vm_name: "NMContains"),
        Opcode.new(name: :NMDELETE, code: 63, arity: 2, vm_name: "NMDelete"),
        Opcode.new(name: :NMNEW, code: 64, arity: 1, vm_name: "NMNew"),
        Opcode.new(name: :NMLEN, code: 65, arity: 2, vm_name: "NMLen"),
        Opcode.new(name: :JILTF, code: 66, arity: 3, vm_name: "JILtF"),
        Opcode.new(name: :JIGTF, code: 67, arity: 3, vm_name: "JIGtF"),
        Opcode.new(name: :JIEQF, code: 68, arity: 3, vm_name: "JIEqF"),
        Opcode.new(name: :JINEQF, code: 69, arity: 3, vm_name: "JINeqF"),
        Opcode.new(name: :JILTEF, code: 70, arity: 3, vm_name: "JILteF"),
        Opcode.new(name: :JIGTEF, code: 71, arity: 3, vm_name: "JIGteF"),
        Opcode.new(name: :JFLTF, code: 72, arity: 3, vm_name: "JFLtF"),
        Opcode.new(name: :JFGTF, code: 73, arity: 3, vm_name: "JFGtF"),
        Opcode.new(name: :JFEQF, code: 74, arity: 3, vm_name: "JFEqF"),
        Opcode.new(name: :JFNEQF, code: 75, arity: 3, vm_name: "JFNeqF"),
        Opcode.new(name: :JFLTEF, code: 76, arity: 3, vm_name: "JFLteF"),
        Opcode.new(name: :JFGTEF, code: 77, arity: 3, vm_name: "JFGteF"),
        # Debugger trap. Replaces the original opcode at a breakpoint IP at
        # startup; the original is preserved in a side table so the dispatch
        # arm can restore + re-execute on continue. Arity 0 -- the operand
        # bytes that followed the original opcode are unchanged in `ops`.
        Opcode.new(name: :TRAP, code: 78, arity: 0, vm_name: "Trap"),
        Opcode.new(name: :SPRINT, code: 79, arity: 1, vm_name: "SPrint"),
        # String list opcodes — mirror LNEW/LAPPENDI/LGETI/LLEN for
        # `String[]@list` programs. Slot indexes 0..3 (slist0..slist3
        # in vm.cht) and the v register file is shared with the other
        # list/map kinds (existing Int64/Float64 list and map slots).
        Opcode.new(name: :LSNEW, code: 80, arity: 1, vm_name: "LSNew"),
        Opcode.new(name: :LSAPPEND, code: 81, arity: 2, vm_name: "LSAppend"),
        Opcode.new(name: :LSGET, code: 82, arity: 3, vm_name: "LSGet"),
        Opcode.new(name: :LSLEN, code: 83, arity: 2, vm_name: "LSLen"),
        # join(stringList, sep) -- writes the joined string to dst sreg.
        # Dedicated opcode rather than NCALL because NCALL's typed-arg
        # protocol only passes scalar registers (ARG_I/F/S), not slot
        # indexes for container vregs.
        Opcode.new(name: :LSJOIN, code: 84, arity: 3, vm_name: "LSJoin"),
        # Phase-1 polymorphic-value HashMap. Storage =
        # HashMap<RegisterValue> in 4 slots (vmap0..vmap3). Guest tag
        # names (Value.Str etc.) transcode to RegisterValue's tag
        # names at emit time. See
        # docs/agents/register-vm-polymorphic-values.md. GET opcodes
        # land in a follow-up commit; this commit covers the write
        # half so the design can be reviewed in pieces.
        Opcode.new(name: :VMNEW,    code: 85, arity: 1, vm_name: "VMNew"),
        Opcode.new(name: :VMPUTNIL, code: 86, arity: 2, vm_name: "VMPutNil"),
        Opcode.new(name: :VMPUTI,   code: 87, arity: 3, vm_name: "VMPutI"),
        Opcode.new(name: :VMPUTF,   code: 88, arity: 3, vm_name: "VMPutF"),
        Opcode.new(name: :VMPUTS,   code: 89, arity: 3, vm_name: "VMPutS"),
        # VMGETTAG dst_tag map key_idx miss_tag -- writes the tag of
        # map[key] into dst_tag (i64), or miss_tag (immediate i64) if
        # the key is missing. Tag values match RegisterValue's
        # declaration order (0=Nil, 1=Int64Val, 2=Number, 3=Str). The
        # MATCH lowering emits VMGETTAG once, then dispatches via
        # JIEQF on dst_tag, then VMGET<I/F/S> in the matching arm.
        Opcode.new(name: :VMGETTAG, code: 90, arity: 4, vm_name: "VMGetTag"),
        Opcode.new(name: :VMGETI,   code: 91, arity: 3, vm_name: "VMGetI"),
        Opcode.new(name: :VMGETF,   code: 92, arity: 3, vm_name: "VMGetF"),
        Opcode.new(name: :VMGETS,   code: 93, arity: 3, vm_name: "VMGetS"),
        # Dynamic-key (register-held) variants of the const-key map
        # ops. Used when the key is computed at runtime, e.g.
        # `map["k_" + i.toString()] = v`. The register holds the
        # already-built string; the dispatch arm COPYs it into the
        # map's own storage just like CLEAR does for compiled code.
        Opcode.new(name: :MPUTIR,    code: 94,  arity: 3, vm_name: "MPutIR"),
        Opcode.new(name: :MGETIR,    code: 95,  arity: 4, vm_name: "MGetIR"),
        Opcode.new(name: :MCONTAINSR, code: 96, arity: 3, vm_name: "MContainsR"),
        Opcode.new(name: :VMPUTNILR, code: 97,  arity: 2, vm_name: "VMPutNilR"),
        Opcode.new(name: :VMPUTIR,   code: 98,  arity: 3, vm_name: "VMPutIR"),
        Opcode.new(name: :VMPUTFR,   code: 99,  arity: 3, vm_name: "VMPutFR"),
        Opcode.new(name: :VMPUTSR,   code: 100, arity: 3, vm_name: "VMPutSR"),
        Opcode.new(name: :VMGETTAGR, code: 101, arity: 4, vm_name: "VMGetTagR"),
        Opcode.new(name: :VMGETIR,   code: 102, arity: 3, vm_name: "VMGetIR"),
        Opcode.new(name: :VMGETFR,   code: 103, arity: 3, vm_name: "VMGetFR"),
        Opcode.new(name: :VMGETSR,   code: 104, arity: 3, vm_name: "VMGetSR"),
        # Phase-2 polymorphic-value List. Storage =
        # RegisterValue[]@list in 4 slots (vlist0..vlist3). Mirrors
        # the Phase-1 vmap design; same RegisterValue transcoding,
        # same cleanup faithfulness (CLEAR's @list cleanup runs
        # RegisterValue's variant cleanup on each element).
        Opcode.new(name: :LVNEW,    code: 105, arity: 1, vm_name: "LVNew"),
        Opcode.new(name: :LVAPPNIL, code: 106, arity: 1, vm_name: "LVAppNil"),
        Opcode.new(name: :LVAPPI,   code: 107, arity: 2, vm_name: "LVAppI"),
        Opcode.new(name: :LVAPPF,   code: 108, arity: 2, vm_name: "LVAppF"),
        Opcode.new(name: :LVAPPS,   code: 109, arity: 2, vm_name: "LVAppS"),
        Opcode.new(name: :LVLEN,    code: 110, arity: 2, vm_name: "LVLen"),
        Opcode.new(name: :LVGETTAG, code: 111, arity: 3, vm_name: "LVGetTag"),
        Opcode.new(name: :LVGETI,   code: 112, arity: 3, vm_name: "LVGetI"),
        Opcode.new(name: :LVGETF,   code: 113, arity: 3, vm_name: "LVGetF"),
        Opcode.new(name: :LVGETS,   code: 114, arity: 3, vm_name: "LVGetS"),
        # `string.split(sep)` returns a String[]@list; emit LSSPLIT
        # which allocates a slist slot and fills it from CheatLib.split.
        Opcode.new(name: :LSSPLIT,  code: 115, arity: 3, vm_name: "LSSplit"),
        # HashMap iteration. {M,NM}KEYS / {M,NM}VALUES land the map's
        # keys (or values) in a list slot. After the
        # hotfix/keys-values-list-type-mismatch fix, `map.keys()` /
        # `map.values()` return owned ArrayLists, so each runtime
        # arm is a direct assignment to the slist / ilist slot
        # (rather than the iterate-and-append workaround the stack
        # machine uses at _bc_runner.cht:3120).
        Opcode.new(name: :MKEYS,    code: 116, arity: 2, vm_name: "MKeys"),
        Opcode.new(name: :MVALUES,  code: 117, arity: 2, vm_name: "MValues"),
        Opcode.new(name: :NMKEYS,   code: 118, arity: 2, vm_name: "NMKeys"),
        Opcode.new(name: :NMVALUES, code: 119, arity: 2, vm_name: "NMValues"),
        # Runtime collection handles. Handle IDs live in iregs and
        # point into VM-owned dynamic list tables. Struct-list rows and
        # StringMap<Int64> buckets can therefore store collection
        # references without needing typed nested containers in vregs.
        Opcode.new(name: :IHNEW,    code: 120, arity: 1, vm_name: "IHNew"),
        Opcode.new(name: :IHAPPEND, code: 121, arity: 2, vm_name: "IHAppend"),
        Opcode.new(name: :IHGET,    code: 122, arity: 3, vm_name: "IHGet"),
        Opcode.new(name: :IHLEN,    code: 123, arity: 2, vm_name: "IHLen"),
        Opcode.new(name: :SHNEW,    code: 124, arity: 1, vm_name: "SHNew"),
        Opcode.new(name: :SHAPPEND, code: 125, arity: 2, vm_name: "SHAppend"),
        Opcode.new(name: :SHGET,    code: 126, arity: 3, vm_name: "SHGet"),
        Opcode.new(name: :SHLEN,    code: 127, arity: 2, vm_name: "SHLen"),
      ].freeze

      OPERANDS_BY_NAME = {
        ICONST: [:i_def, :const],
        IRET: [:i_use],
        HALT: [],
        IMOV: [:i_def, :i_use],
        IADD: [:i_def, :i_use, :i_use],
        ISUB: [:i_def, :i_use, :i_use],
        IMUL: [:i_def, :i_use, :i_use],
        IDIV: [:i_def, :i_use, :i_use],
        ILT: [:i_def, :i_use, :i_use],
        IGT: [:i_def, :i_use, :i_use],
        IEQ: [:i_def, :i_use, :i_use],
        INEQ: [:i_def, :i_use, :i_use],
        ILTE: [:i_def, :i_use, :i_use],
        IGTE: [:i_def, :i_use, :i_use],
        JMP: [:target],
        JF: [:i_use, :target],
        FCONST: [:f_def, :const],
        FRET: [:f_use],
        FMOV: [:f_def, :f_use],
        FADD: [:f_def, :f_use, :f_use],
        FSUB: [:f_def, :f_use, :f_use],
        FMUL: [:f_def, :f_use, :f_use],
        FDIV: [:f_def, :f_use, :f_use],
        FLT: [:i_def, :f_use, :f_use],
        FGT: [:i_def, :f_use, :f_use],
        FEQ: [:i_def, :f_use, :f_use],
        FNEQ: [:i_def, :f_use, :f_use],
        FLTE: [:i_def, :f_use, :f_use],
        FGTE: [:i_def, :f_use, :f_use],
        IMOD: [:i_def, :i_use, :i_use],
        ICALL: [:i_def, :call_target, :argc, :iframe, :fframe, :typed_args],
        FCALL: [:f_def, :call_target, :argc, :iframe, :fframe, :typed_args],
        NCALL: [:ret_kind, :ret_dynamic_def, :native_id, :argc, :typed_args],
        IPRINT: [:const, :i_use, :const],
        IPRINT2: [:const, :i_use, :const, :i_use, :const],
        SCONST: [:s_def, :const],
        SRET: [:s_use],
        SMOV: [:s_def, :s_use],
        SCONCAT: [:s_def, :s_use, :s_use],
        LNEW: [:v_def],
        LAPPENDI: [:v_use, :i_use],
        LGETI: [:i_def, :v_use, :i_use],
        LLEN: [:i_def, :v_use],
        LSNEW: [:v_def],
        LSAPPEND: [:v_use, :s_use],
        LSGET: [:s_def, :v_use, :i_use],
        LSLEN: [:i_def, :v_use],
        LSJOIN: [:s_def, :v_use, :s_use],
        VMNEW:    [:m_def],
        VMPUTNIL: [:m_use, :const],
        VMPUTI:   [:m_use, :const, :i_use],
        VMPUTF:   [:m_use, :const, :f_use],
        VMPUTS:   [:m_use, :const, :s_use],
        VMGETTAG: [:i_def, :m_use, :const, :i_use],
        VMGETI:   [:i_def, :m_use, :const],
        VMGETF:   [:f_def, :m_use, :const],
        VMGETS:   [:s_def, :m_use, :const],
        MPUTIR:    [:m_use, :s_use, :i_use],
        MGETIR:    [:i_def, :m_use, :s_use, :i_use],
        MCONTAINSR: [:i_def, :m_use, :s_use],
        VMPUTNILR: [:m_use, :s_use],
        VMPUTIR:   [:m_use, :s_use, :i_use],
        VMPUTFR:   [:m_use, :s_use, :f_use],
        VMPUTSR:   [:m_use, :s_use, :s_use],
        VMGETTAGR: [:i_def, :m_use, :s_use, :i_use],
        VMGETIR:   [:i_def, :m_use, :s_use],
        VMGETFR:   [:f_def, :m_use, :s_use],
        VMGETSR:   [:s_def, :m_use, :s_use],
        LVNEW:    [:v_def],
        LVAPPNIL: [:v_use],
        LVAPPI:   [:v_use, :i_use],
        LVAPPF:   [:v_use, :f_use],
        LVAPPS:   [:v_use, :s_use],
        LVLEN:    [:i_def, :v_use],
        LVGETTAG: [:i_def, :v_use, :i_use],
        LVGETI:   [:i_def, :v_use, :i_use],
        LVGETF:   [:f_def, :v_use, :i_use],
        LVGETS:   [:s_def, :v_use, :i_use],
        LSSPLIT:  [:v_def, :s_use, :s_use],
        MNEW: [:m_def],
        MPUTI: [:m_use, :const, :i_use],
        MGETI: [:i_def, :m_use, :const, :i_use],
        LFNEW: [:v_def],
        LFAPPEND: [:v_use, :f_use],
        LFGET: [:f_def, :v_use, :i_use],
        SEQ: [:i_def, :s_use, :s_use],
        LSSET: [:v_use, :i_use, :s_use],
        LSETI: [:v_use, :i_use, :i_use],
        LFSET: [:v_use, :i_use, :f_use],
        LFLEN: [:i_def, :v_use],
        MLEN: [:i_def, :m_use],
        MCONTAINS: [:i_def, :m_use, :const],
        MDELETE: [:m_use, :const],
        NMPUTI: [:m_use, :i_use, :i_use],
        NMGETI: [:i_def, :m_use, :i_use, :i_use],
        NMCONTAINS: [:i_def, :m_use, :i_use],
        NMDELETE: [:m_use, :i_use],
        NMNEW: [:m_def],
        NMLEN: [:i_def, :m_use],
        MKEYS:    [:v_use, :v_use],
        MVALUES:  [:v_use, :v_use],
        NMKEYS:   [:v_use, :v_use],
        NMVALUES: [:v_use, :v_use],
        IHNEW:    [:i_def],
        IHAPPEND: [:i_use, :i_use],
        IHGET:    [:i_def, :i_use, :i_use],
        IHLEN:    [:i_def, :i_use],
        SHNEW:    [:i_def],
        SHAPPEND: [:i_use, :s_use],
        SHGET:    [:s_def, :i_use, :i_use],
        SHLEN:    [:i_def, :i_use],
        JILTF: [:i_use, :i_use, :target],
        JIGTF: [:i_use, :i_use, :target],
        JIEQF: [:i_use, :i_use, :target],
        JINEQF: [:i_use, :i_use, :target],
        JILTEF: [:i_use, :i_use, :target],
        JIGTEF: [:i_use, :i_use, :target],
        JFLTF: [:f_use, :f_use, :target],
        JFGTF: [:f_use, :f_use, :target],
        JFEQF: [:f_use, :f_use, :target],
        JFNEQF: [:f_use, :f_use, :target],
        JFLTEF: [:f_use, :f_use, :target],
        JFGTEF: [:f_use, :f_use, :target],
        TRAP: [],
        SPRINT: [:s_use],
      }.freeze

      OPCODES.each do |op|
        op.operands = OPERANDS_BY_NAME.fetch(op.name)
        op.freeze
      end

      BY_NAME = OPCODES.to_h { |op| [op.name, op] }.freeze
      BY_CODE = OPCODES.to_h { |op| [op.code, op] }.freeze
      FIXED_ARITIES = OPCODES
        .select { |op| op.arity.is_a?(Integer) }
        .to_h { |op| [op.code, op.arity] }
        .freeze

      VM_ENUM_EXPECTED = begin
        max_code = OPCODES.map(&:code).max
        names = Array.new(max_code + 1) { |i| "Reserved#{i}" }
        OPCODES.each { |op| names[op.code] = op.vm_name }
        names << "Operand"
        names.freeze
      end

      def self.branch_target_indexes(opcode)
        schema = BY_CODE.fetch(opcode).operands
        schema.each_index.select { |idx| schema[idx] == :target }
      end

      def self.code_target_indexes(opcode)
        schema = BY_CODE.fetch(opcode).operands
        schema.each_index.select { |idx| schema[idx] == :target || schema[idx] == :call_target }
      end

      def self.register_uses(opcode, args)
        refs_from_schema(opcode, args, use: true)
      end

      def self.register_defs(opcode, args)
        refs_from_schema(opcode, args, use: false)
      end

      def self.rewrite_registers!(opcode, args, mapping)
        schema = BY_CODE.fetch(opcode).operands
        schema.each_with_index do |role, idx|
          rewrite_role!(args, idx, role, mapping)
        end
        rewrite_typed_args!(args, typed_args_start(schema), mapping)
        args
      end

      module Encoding
        MAGIC = [82, 66, 67, 49].freeze # "RBC1"

        LIMITS = {
          opcode: 0xff,
          reg: 0xff,
          const: 0xffff,
          target: 0xffff_ffff,
          argc: 0xff,
          frame: 0xffff,
          tag: 0xff,
          native_id: 0xff,
          list_reg: 0xff,
          map_reg: 0xff,
        }.freeze

        ROLE_KIND = {
          i_use: :reg,
          i_def: :reg,
          f_use: :reg,
          f_def: :reg,
          s_use: :reg,
          s_def: :reg,
          v_use: :list_reg,
          v_def: :list_reg,
          m_use: :map_reg,
          m_def: :map_reg,
          const: :const,
          target: :target,
          call_target: :target,
          argc: :argc,
          iframe: :frame,
          fframe: :frame,
          ret_kind: :tag,
          ret_dynamic_def: :reg,
          native_id: :native_id,
        }.freeze

        FIXED_BYTES = {
          opcode: 1,
          reg: 1,
          const: 2,
          target: 4,
          argc: 1,
          frame: 2,
          tag: 1,
          native_id: 1,
          list_reg: 1,
          map_reg: 1,
        }.freeze

        VARIABLE_BYTES = {
          typed_arg_pair: 2,
        }.freeze
      end

      PackingProfile = Struct.new(
        :instruction_count,
        :raw_i64_bytes,
        :packed_bytes,
        :max_by_kind,
        :count_by_kind,
        :failures,
        keyword_init: true
      ) do
        def initialize(**kwargs)
          super(
            instruction_count: kwargs.fetch(:instruction_count, 0),
            raw_i64_bytes: kwargs.fetch(:raw_i64_bytes, 0),
            packed_bytes: kwargs.fetch(:packed_bytes, 0),
            max_by_kind: kwargs.fetch(:max_by_kind, Hash.new(0)),
            count_by_kind: kwargs.fetch(:count_by_kind, Hash.new(0)),
            failures: kwargs.fetch(:failures, [])
          )
        end

        def packable?
          failures.empty?
        end

        def merge!(other)
          self.instruction_count += other.instruction_count
          self.raw_i64_bytes += other.raw_i64_bytes
          self.packed_bytes += other.packed_bytes
          other.max_by_kind.each do |kind, value|
            self.max_by_kind[kind] = [self.max_by_kind[kind], value].max
          end
          other.count_by_kind.each do |kind, value|
            self.count_by_kind[kind] += value
          end
          self.failures.concat(other.failures)
          self
        end
      end

      def self.profile_packing(program)
        profile = PackingProfile.new
        program.instructions.each do |insn|
          profile.instruction_count += 1
          profile.raw_i64_bytes += insn.width * 8
          record_operand!(profile, :opcode, insn.opcode, insn.ip)
          profile.packed_bytes += Encoding::FIXED_BYTES.fetch(:opcode)

          schema = BY_CODE.fetch(insn.opcode).operands
          schema.each_with_index do |role, idx|
            next if role == :typed_args

            kind = Encoding::ROLE_KIND.fetch(role)
            value = insn.args.fetch(idx)
            record_operand!(profile, kind, value, insn.ip)
            profile.packed_bytes += Encoding::FIXED_BYTES.fetch(kind)
          end
          record_typed_args_for_packing!(profile, insn)
        end
        profile
      end

      def self.pack_ops(ops)
        instructions = decode_flat_ops(ops)
        profile = profile_packing(OpenStructProgram.new(instructions))
        unless profile.packable?
          raise ArgumentError, "register bytecode is not packable:\n#{profile.failures.join("\n")}"
        end

        bytes = Encoding::MAGIC.dup
        instructions.each do |insn|
          write_operand!(bytes, :opcode, insn.opcode)
          schema = BY_CODE.fetch(insn.opcode).operands
          schema.each_with_index do |role, idx|
            next if role == :typed_args

            write_operand!(bytes, Encoding::ROLE_KIND.fetch(role), insn.args.fetch(idx))
          end
          start = typed_args_start(schema)
          next unless start

          (insn.args[start..] || []).each_slice(2) do |kind, reg|
            write_operand!(bytes, :tag, kind)
            write_operand!(bytes, :reg, reg)
          end
        end
        bytes
      end

      def self.unpack_ops(bytes)
        raise ArgumentError, "packed register bytecode missing RBC1 header" unless bytes[0, 4] == Encoding::MAGIC

        ops = []
        cursor = 4
        while cursor < bytes.length
          opcode, cursor = read_operand(bytes, cursor, :opcode)
          insn_start = ops.length
          ops << opcode
          schema = BY_CODE.fetch(opcode).operands
          schema.each_with_index do |role, _idx|
            next if role == :typed_args

            value, cursor = read_operand(bytes, cursor, Encoding::ROLE_KIND.fetch(role))
            ops << value
          end
          start = typed_args_start(schema)
          next unless start

          argc = ops.fetch(insn_start + 1 + schema.index(:argc))
          argc.times do
            kind, cursor = read_operand(bytes, cursor, :tag)
            reg, cursor = read_operand(bytes, cursor, :reg)
            ops << kind << reg
          end
        end
        ops
      end

      OpenStructProgram = Struct.new(:instructions)
      PackedInstruction = Struct.new(:ip, :opcode, :args) do
        def width
          1 + args.length
        end
      end

      def self.decode_flat_ops(ops)
        instructions = []
        ip = 0
        while ip < ops.length
          opcode = ops.fetch(ip)
          arity = flat_arity_at(ops, ip)
          args = ops[(ip + 1)..(ip + arity)] || []
          instructions << PackedInstruction.new(ip, opcode, args)
          ip += 1 + arity
        end
        instructions
      end
      private_class_method :decode_flat_ops

      def self.flat_arity_at(ops, ip)
        opcode = ops.fetch(ip)
        case BY_CODE.fetch(opcode).arity
        when :call then 5 + ops.fetch(ip + 3).to_i * 2
        when :native_call then 4 + ops.fetch(ip + 4).to_i * 2
        else BY_CODE.fetch(opcode).arity
        end
      end
      private_class_method :flat_arity_at

      def self.write_operand!(bytes, kind, value)
        limit = Encoding::LIMITS.fetch(kind)
        raise ArgumentError, "#{kind}=#{value} exceeds packed limit #{limit}" unless value >= 0 && value <= limit

        case Encoding::FIXED_BYTES.fetch(kind)
        when 1
          bytes << value
        when 2
          bytes << (value & 0xff)
          bytes << ((value >> 8) & 0xff)
        when 4
          bytes << (value & 0xff)
          bytes << ((value >> 8) & 0xff)
          bytes << ((value >> 16) & 0xff)
          bytes << ((value >> 24) & 0xff)
        else
          raise ArgumentError, "unsupported packed width for #{kind}"
        end
      end
      private_class_method :write_operand!

      def self.read_operand(bytes, cursor, kind)
        width = Encoding::FIXED_BYTES.fetch(kind)
        value = 0
        width.times do |offset|
          value |= bytes.fetch(cursor + offset) << (offset * 8)
        end
        [value, cursor + width]
      end
      private_class_method :read_operand

      def self.record_operand!(profile, kind, value, ip)
        profile.count_by_kind[kind] += 1
        profile.max_by_kind[kind] = [profile.max_by_kind[kind], value].max
        limit = Encoding::LIMITS.fetch(kind)
        return if value >= 0 && value <= limit

        profile.failures << "ip=#{ip} #{kind}=#{value} exceeds packed limit #{limit}"
      end
      private_class_method :record_operand!

      def self.record_typed_args_for_packing!(profile, insn)
        schema = BY_CODE.fetch(insn.opcode).operands
        start = typed_args_start(schema)
        return unless start

        argc_idx = schema.index(:argc)
        argc = argc_idx ? insn.args.fetch(argc_idx) : 0
        record_operand!(profile, :argc, argc, insn.ip)
        typed_args = insn.args[start..] || []
        if typed_args.length != argc * 2
          profile.failures << "ip=#{insn.ip} typed arg count #{typed_args.length / 2} does not match argc #{argc}"
        end
        typed_args.each_slice(2) do |kind, reg|
          record_operand!(profile, :tag, kind, insn.ip)
          record_operand!(profile, :reg, reg, insn.ip)
          profile.packed_bytes += Encoding::VARIABLE_BYTES.fetch(:typed_arg_pair)
        end
      end
      private_class_method :record_typed_args_for_packing!

      def self.refs_from_schema(opcode, args, use:)
        schema = BY_CODE.fetch(opcode).operands
        refs = []
        schema.each_with_index do |role, idx|
          ref = ref_for_role(args, idx, role, use: use)
          refs << ref if ref
        end
        refs.concat(typed_arg_refs(args, typed_args_start(schema))) if use
        refs
      end
      private_class_method :refs_from_schema

      def self.ref_for_role(args, idx, role, use:)
        case role
        when :i_use then use ? [:i, args[idx]] : nil
        when :f_use then use ? [:f, args[idx]] : nil
        when :s_use then use ? [:s, args[idx]] : nil
        when :i_def then use ? nil : [:i, args[idx]]
        when :f_def then use ? nil : [:f, args[idx]]
        when :s_def then use ? nil : [:s, args[idx]]
        when :ret_dynamic_def then use ? nil : ret_dynamic_def(args)
        else nil
        end
      end
      private_class_method :ref_for_role

      def self.ret_dynamic_def(args)
        case args[0]
        when 1 then [:i, args[1]]
        when 2 then [:f, args[1]]
        when 3 then [:s, args[1]]
        end
      end
      private_class_method :ret_dynamic_def

      def self.typed_arg_refs(args, start)
        return [] unless start

        args[start..]&.each_slice(2)&.filter_map do |kind, reg|
          case kind
          when 1 then [:f, reg]
          when 2 then [:s, reg]
          else [:i, reg]
          end
        end || []
      end
      private_class_method :typed_arg_refs

      def self.typed_args_start(schema)
        idx = schema.index(:typed_args)
        return nil unless idx

        idx
      end
      private_class_method :typed_args_start

      def self.rewrite_role!(args, idx, role, mapping)
        case role
        when :i_use, :i_def then rewrite_reg!(args, idx, :i, mapping)
        when :f_use, :f_def then rewrite_reg!(args, idx, :f, mapping)
        when :s_use, :s_def then rewrite_reg!(args, idx, :s, mapping)
        when :ret_dynamic_def then rewrite_dynamic_ret!(args, mapping)
        end
      end
      private_class_method :rewrite_role!

      def self.rewrite_reg!(args, idx, kind, mapping)
        args[idx] = mapping.fetch(kind).fetch([kind, args[idx]], args[idx])
      end
      private_class_method :rewrite_reg!

      def self.rewrite_dynamic_ret!(args, mapping)
        case args[0]
        when 1 then rewrite_reg!(args, 1, :i, mapping)
        when 2 then rewrite_reg!(args, 1, :f, mapping)
        when 3 then rewrite_reg!(args, 1, :s, mapping)
        end
      end
      private_class_method :rewrite_dynamic_ret!

      def self.rewrite_typed_args!(args, start, mapping)
        return unless start

        idx = start
        while idx < args.length
          kind = case args[idx]
                 when 1 then :f
                 when 2 then :s
                 else :i
                 end
          rewrite_reg!(args, idx + 1, kind, mapping)
          idx += 2
        end
      end
      private_class_method :rewrite_typed_args!

      def self.validate_vm_enum!(vm_path = File.join(__dir__, "vm.cht"))
        source = File.read(vm_path)
        match = source.match(/ENUM\s+RegisterOp\s*\{(?<body>.*?)\}/m)
        raise "RegisterOp enum not found in #{vm_path}" unless match

        actual = match[:body].split(",").map(&:strip).reject(&:empty?)
        return true if actual == VM_ENUM_EXPECTED

        raise "RegisterOp enum drift:\nexpected: #{VM_ENUM_EXPECTED.join(', ')}\nactual:   #{actual.join(', ')}"
      end
    end
  end
end
