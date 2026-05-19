# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # False simplicity: code whose local syntax understates its non-local
  # behaviour -- hidden dynamic dispatch, hidden mutation, hidden
  # global/context dependency, hidden IO/effects, callback/control
  # inversion, metaprogramming/reflection, monkeypatch/reopen. Seven
  # sub-detectors, one category, ranked support x scatter (same
  # blast-radius thesis as Missing Abstractions: one trigger reinvented
  # across N methods is one missing abstraction).
  #
  # #8 (protocol-pair names: open/close, lock/unlock) is NOT here -- it
  # is already Broken Protocols (SequenceMine, Engler co-call mining).
  #
  # Pure RubyVM::AST node matching. No dataflow, no CFG, no points-to.
  # Lexicons mined from RuboCop/Reek/stdlib as reference DATA (copied
  # once at authoring time), never a runtime dependency (principle 1).
  # See docs/false-simplicity.md.
  class FalseSimplicity
    Hit = Struct.new(:kind, :detail, :file, :defn, :line, :span,
                     keyword_init: true)
    ClassRec = Struct.new(:name, :file, :line, :core, :span,
                          keyword_init: true)

    DISPATCH_MIDS = %w[send __send__ public_send const_get constantize
                       instance_variable_get].freeze
    META_MIDS = %w[define_method define_singleton_method alias_method
                   class_eval module_eval instance_eval class_exec
                   module_exec instance_exec eval const_set
                   instance_variable_set remove_method undef_method
                   prepend singleton_class binding].freeze
    METHOD_OBJ_MIDS = %i[method public_method instance_method].freeze
    IO_CONSTS = %w[File IO Dir FileUtils Open3 Socket TCPSocket UDPSocket
                   TCPServer UNIXSocket Tempfile Pathname Marshal].freeze
    # bare `p`/`pp` deliberately excluded: single/double-letter, too
    # often a local-var bareword (VCALL) to flag as Kernel#p.
    IO_BARE = %w[puts print warn gets readline readlines system
                 exec spawn fork sleep open abort exit exit!].freeze
    DIR_CONTEXT = %w[pwd getwd home].freeze
    # const => methods that make the call ambient (context-sensitive).
    CONTEXT_PAIRS = {
      "Time" => %w[now current], "Date" => %w[today current],
      "DateTime" => %w[now current], "Process" => %w[pid ppid uid gid euid],
      "Thread" => %w[current list main], "Fiber" => %w[current],
      "Random" => %w[rand bytes], "GC" => %w[stat count],
      "ObjectSpace" => %w[each_object count_objects]
    }.freeze
    CONTEXT_BARE = %w[rand srand].freeze
    CALLBACK_SET = %w[transaction synchronize lock with_lock unlock
                      mutex atomic reentrant subscribe callback hook].freeze
    CORE = %w[String Symbol Integer Float Numeric Rational Complex
              Array Hash Set Range Struct Object BasicObject Kernel
              Module Class Comparable Enumerable Enumerator Proc Method
              UnboundMethod NilClass TrueClass FalseClass Exception
              StandardError RuntimeError ArgumentError TypeError
              NameError NoMethodError IO File Dir Time Date DateTime
              Regexp MatchData Thread Mutex Fiber Process Math GC
              ObjectSpace Marshal Random Encoding].freeze

    def self.scan(files)
      hits = []
      recs = []
      files.each do |f|
        root, lines = Ast.parse(f)
        e = new(f, lines)
        e.walk(root, [], [])
        hits.concat(e.hits)
        recs.concat(e.classrecs)
      end
      Report.new(hits, recs)
    end

    attr_reader :hits, :classrecs

    def initialize(file, lines)
      @file = file
      @lines = lines
      @hits = []
      @classrecs = []
    end

    def walk(node, defs, cls)
      return unless Ast.node?(node)

      case node.type
      when :CLASS, :MODULE
        return walk_class(node, defs, cls)
      when :SCLASS
        recv = node.children[0]
        emit(:metaprogramming, "class << #{Ast.slice(recv, @lines)}",
             dn(defs), node) unless recv.type == :SELF
      when :DEFN, :DEFS
        nm = (node.type == :DEFN ? node.children[0] : node.children[1])
        emit(:metaprogramming, "def #{nm}", dn(defs), node) \
          if %i[method_missing respond_to_missing?].include?(nm)
        nd = Ast.def_push(node, defs)
        return node.children.each { |c| walk(c, nd, cls) }
      when :CALL, :FCALL, :VCALL, :OPCALL
        classify_call(node, defs)
      when :ATTRASGN
        emit(:hidden_mutation, node.children[1].to_s, dn(defs), node)
      when :OP_ASGN1, :OP_ASGN2
        emit(:hidden_mutation, "op-assign", dn(defs), node)
      when :GVAR, :GASGN
        emit(:context_dependency, node.children[0].to_s, dn(defs), node)
      when :XSTR, :DXSTR
        emit(:hidden_io, "backtick", dn(defs), node)
      when :YIELD
        emit(:dynamic_dispatch, "yield", dn(defs), node)
      when :ITER
        cm = callee_mid(node.children[0])
        emit(:callback_inversion, cm.to_s, dn(defs), node) \
          if cm && callback?(cm.to_s) && !META_MIDS.include?(cm.to_s)
      end

      node.children.each { |c| walk(c, defs, cls) }
    end

    private

    def dn(defs)
      defs.last || "(top-level)"
    end

    # Takes the triggering node so line AND span come from one place.
    def emit(kind, detail, defn, node)
      @hits << Hit.new(kind: kind, detail: detail, file: @file,
                       defn: defn, line: node.first_lineno,
                       span: [node.first_lineno, node.first_column,
                              node.last_lineno, node.last_column])
    end

    def walk_class(node, defs, cls)
      cpath = node.children[0]
      body  = node.children[node.type == :CLASS ? 2 : 1]
      simple = const_simple(cpath)
      based  = cpath.is_a?(RubyVM::AbstractSyntaxTree::Node) &&
               cpath.type == :COLON2 && !cpath.children[0].nil?
      fqn = (cls + [const_text(cpath)]).join("::")
      if has_def?(body)
        core = cls.empty? && !based && CORE.include?(simple)
        @classrecs << ClassRec.new(name: fqn, file: @file,
                                   line: node.first_lineno, core: core,
                                   span: [node.first_lineno, node.first_column,
                                          node.last_lineno, node.last_column])
        emit(:monkeypatch, simple, simple, node) if core
      end
      newcls = cls + [const_text(cpath)]
      node.children.each { |c| walk(c, defs, newcls) }
    end

    # Exactly one hit per call node, highest-signal kind first, so
    # counts are not inflated by a node matching two lexicons.
    def classify_call(call, defs)
      recv, mid =
        case call.type
        when :CALL, :OPCALL then [call.children[0], call.children[1]]
        else [nil, call.children[0]]
        end
      m = mid.to_s

      if block_pass?(call) && callback?(m) && !META_MIDS.include?(m)
        return emit(:callback_inversion, m, dn(defs), call)
      end
      return emit(:metaprogramming, m, dn(defs), call) if META_MIDS.include?(m)
      return emit(:dynamic_dispatch, m, dn(defs), call) if DISPATCH_MIDS.include?(m)

      if m == "call" && recv
        return emit(:dynamic_dispatch, "method(...).call", dn(defs), call) \
          if method_obj?(recv)
        return emit(:dynamic_dispatch, "#{Ast.slice(recv, @lines)}.call",
                    dn(defs), call) if var_recv?(recv)
      end

      cp = const_recv(recv)
      if cp
        base = cp.sub(/\A::/, "").split("::").first
        if base == "Dir" && DIR_CONTEXT.include?(m)
          return emit(:context_dependency, "Dir.#{m}", dn(defs), call)
        end
        if IO_CONSTS.include?(base) || cp.start_with?("Net::")
          return emit(:hidden_io, "#{cp}.#{m}", dn(defs), call)
        end
        return emit(:hidden_io, "URI.open", dn(defs), call) \
          if base == "URI" && m == "open"
        return emit(:context_dependency, "ENV", dn(defs), call) if cp == "ENV"
        if CONTEXT_PAIRS[base]&.include?(m)
          return emit(:context_dependency, "#{base}.#{m}", dn(defs), call)
        end
      end

      if recv.nil?
        return emit(:hidden_io, m, dn(defs), call) if IO_BARE.include?(m)
        return emit(:context_dependency, m, dn(defs), call) \
          if CONTEXT_BARE.include?(m)
      end

      if m.length > 1 && m.end_with?("!") && !%w[!= !~].include?(m)
        return emit(:hidden_mutation, m, dn(defs), call)
      end
      emit(:hidden_mutation, "<<", dn(defs), call) \
        if call.type == :OPCALL && m == "<<"
    end

    def callback?(str)
      CALLBACK_SET.include?(str) ||
        str =~ /\A(with_|around_|on_|before_|after_)/ ||
        str =~ /_hook\z/
    end

    def callee_mid(call)
      return nil unless Ast.node?(call)

      case call.type
      when :CALL, :OPCALL then call.children[1]
      when :FCALL, :VCALL then call.children[0]
      end
    end

    def block_pass?(call)
      args =
        case call.type
        when :CALL, :OPCALL then call.children[2]
        when :FCALL then call.children[1]
        end
      return false unless Ast.node?(args)
      # `f(&b)` -> args IS the BLOCK_PASS; `f(a, &b)` -> LIST[..., BLOCK_PASS].
      return true if args.type == :BLOCK_PASS

      args.type == :LIST &&
        args.children.any? { |c| Ast.node?(c) && c.type == :BLOCK_PASS }
    end

    def method_obj?(recv)
      Ast.node?(recv) && %i[CALL FCALL].include?(recv.type) &&
        METHOD_OBJ_MIDS.include?(
          recv.type == :CALL ? recv.children[1] : recv.children[0]
        )
    end

    def var_recv?(recv)
      Ast.node?(recv) &&
        %i[VCALL LVAR DVAR IVAR CVAR GVAR].include?(recv.type)
    end

    def const_recv(recv)
      return nil unless Ast.node?(recv) &&
                        %i[CONST COLON2 COLON3].include?(recv.type)

      const_text(recv)
    end

    def const_text(n)
      return n.to_s unless Ast.node?(n)

      case n.type
      when :CONST then n.children[0].to_s
      when :COLON3 then "::#{n.children[0]}"
      when :COLON2
        b = n.children[0]
        b ? "#{const_text(b)}::#{n.children[1]}" : n.children[1].to_s
      else Ast.slice(n, @lines)
      end
    end

    def const_simple(n)
      return n.to_s unless Ast.node?(n)

      case n.type
      when :CONST, :COLON3 then n.children[0].to_s
      when :COLON2 then n.children[1].to_s
      else const_text(n)
      end
    end

    # A def reachable without crossing a nested namespace -- methods
    # added to THIS class/module. SCLASS is descended (its defs attach
    # to the enclosing object); CLASS/MODULE prune (separate namespace).
    def has_def?(n)
      return false unless Ast.node?(n)
      return true if %i[DEFN DEFS].include?(n.type)
      return false if %i[CLASS MODULE].include?(n.type)

      n.children.any? { |c| has_def?(c) }
    end

    # Groups hits by [kind, detail] and ranks by blast radius:
    # scatter = distinct (file, method) units, support = occurrences.
    # Cross-file project-class reopen (same FQN with methods in >=2
    # files) becomes monkeypatch hits here; core reopens were already
    # emitted per occurrence during the walk.
    class Report
      def initialize(hits, classrecs)
        @hits = hits.dup
        classrecs.group_by(&:name).each_value do |recs|
          next if recs.first.core
          next if recs.map(&:file).uniq.size < 2

          recs.each do |r|
            @hits << Hit.new(kind: :monkeypatch, detail: "reopen #{r.name}",
                             file: r.file, defn: r.name, line: r.line,
                             span: r.span)
          end
        end
      end

      attr_reader :hits

      def findings
        @hits.group_by { |h| [h.kind, h.detail] }.map do |(kind, detail), hs|
          units = hs.map { |h| [h.file, h.defn] }.uniq
          sites = hs.map { |h| "#{h.file}:#{h.defn}:#{h.line}" }.uniq
          spans = {}
          hs.each { |h| spans["#{h.file}:#{h.defn}:#{h.line}"] ||= h.span }
          { kind: kind, detail: detail, support: hs.size,
            scatter: units.size, at: sites.first, sites: sites, spans: spans }
        end.sort_by { |h| [-h[:scatter], -h[:support], h[:kind].to_s, h[:detail]] }
      end
    end
  end
end
