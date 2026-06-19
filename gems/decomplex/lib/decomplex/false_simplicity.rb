# frozen_string_literal: true

require_relative "ast"
require_relative "syntax"

module Decomplex
  # False simplicity: code whose local syntax understates its non-local
  # behaviour -- hidden dynamic dispatch, hidden mutation, hidden
  # global/context dependency, hidden IO/effects, callback/control
  # inversion, runtime reflection, monkeypatch/reopen. Seven
  # sub-detectors, one category, ranked support x scatter (same
  # blast-radius thesis as Missing Abstractions: one trigger reinvented
  # across N methods is one missing abstraction).
  #
  # #8 (protocol-pair names: open/close, lock/unlock) is NOT here -- it
  # is already Broken Protocols (SequenceMine, Engler co-call mining).
  #
  # Pure normalized syntax-tree matching. No dataflow, no CFG, no points-to.
  # Language lexicons are provider data: Ruby's was mined from
  # RuboCop/Reek/stdlib, while other languages use their own effectful
  # runtime surfaces instead of inheriting Ruby's.
  # See docs/agents/false-simplicity.md.
  class FalseSimplicity
    Hit = Struct.new(:kind, :detail, :file, :defn, :line, :span,
                     keyword_init: true)
    ClassRec = Struct.new(:name, :file, :line, :core, :span,
                          keyword_init: true)
    Lexicon = Struct.new(
      :dispatch_mids, :meta_mids, :method_obj_mids, :io_consts,
      :io_bare, :dir_context, :context_pairs, :context_bare,
      :callback_set, :core_consts,
      keyword_init: true
    )

    EMPTY_PAIRS = {}.freeze
    COMMON_CALLBACK_SET = %w[
      transaction synchronize lock with_lock unlock mutex atomic subscribe
      callback hook
    ].freeze
    RUBY_LEXICON = Lexicon.new(
      dispatch_mids: %w[send __send__ public_send const_get constantize
                        instance_variable_get].freeze,
      meta_mids: %w[define_method define_singleton_method alias_method
                    class_eval module_eval instance_eval class_exec
                    module_exec instance_exec eval const_set
                    instance_variable_set remove_method undef_method
                    prepend singleton_class binding].freeze,
      method_obj_mids: %i[method public_method instance_method].freeze,
      io_consts: %w[File IO Dir FileUtils Open3 Socket TCPSocket UDPSocket
                    TCPServer UNIXSocket Tempfile Pathname Marshal].freeze,
      io_bare: %w[puts print warn gets readline readlines system
                  exec spawn fork sleep open abort exit exit!].freeze,
      dir_context: %w[pwd getwd home].freeze,
      context_pairs: {
        "Time" => %w[now current], "Date" => %w[today current],
        "DateTime" => %w[now current], "Process" => %w[pid ppid uid gid euid],
        "Thread" => %w[current list main], "Fiber" => %w[current],
        "Random" => %w[rand bytes], "GC" => %w[stat count],
        "ObjectSpace" => %w[each_object count_objects]
      }.freeze,
      context_bare: %w[rand srand].freeze,
      callback_set: %w[transaction synchronize lock with_lock unlock
                       mutex atomic reentrant subscribe callback hook].freeze,
      core_consts: %w[String Symbol Integer Float Numeric Rational Complex
                      Array Hash Set Range Struct Object BasicObject Kernel
                      Module Class Comparable Enumerable Enumerator Proc Method
                      UnboundMethod NilClass TrueClass FalseClass Exception
                      StandardError RuntimeError ArgumentError TypeError
                      NameError NoMethodError IO File Dir Time Date DateTime
                      Regexp MatchData Thread Mutex Fiber Process Math GC
                      ObjectSpace Marshal Random Encoding].freeze
    ).freeze
    PYTHON_LEXICON = Lexicon.new(
      dispatch_mids: %w[getattr setattr hasattr __getattr__ __setattr__ import_module].freeze,
      meta_mids: %w[eval exec compile type globals locals vars setattr delattr].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[Path pathlib os sys subprocess socket shutil].freeze,
      io_bare: %w[print input open exec eval].freeze,
      dir_context: %w[getcwd home].freeze,
      context_pairs: {
        "time" => %w[time monotonic perf_counter],
        "datetime" => %w[now today utcnow],
        "random" => %w[random randint randrange choice]
      }.freeze,
      context_bare: %w[random randint randrange].freeze,
      callback_set: COMMON_CALLBACK_SET,
      core_consts: [].freeze
    ).freeze
    JS_LEXICON = Lexicon.new(
      dispatch_mids: %w[eval Function call apply bind].freeze,
      meta_mids: %w[eval Function defineProperty defineProperties setPrototypeOf].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[console Console fs process Deno Bun].freeze,
      io_bare: %w[setTimeout setInterval fetch require import].freeze,
      dir_context: [].freeze,
      context_pairs: {
        "Date" => %w[now],
        "Math" => %w[random],
        "performance" => %w[now]
      }.freeze,
      context_bare: [].freeze,
      callback_set: COMMON_CALLBACK_SET,
      core_consts: [].freeze
    ).freeze
    GO_LEXICON = Lexicon.new(
      dispatch_mids: %w[Call CallSlice Method MethodByName ValueOf TypeOf].freeze,
      meta_mids: %w[Call CallSlice MethodByName New MakeFunc].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[os io ioutil fs net http exec syscall].freeze,
      io_bare: %w[panic print println recover].freeze,
      dir_context: %w[Getwd UserHomeDir].freeze,
      context_pairs: {
        "time" => %w[Now Since Until],
        "rand" => %w[Int Intn Float64 Read]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[Lock Unlock RLock RUnlock Do Go Add Done Wait]).uniq.freeze,
      core_consts: [].freeze
    ).freeze
    RUST_LEXICON = Lexicon.new(
      dispatch_mids: %w[downcast downcast_ref downcast_mut call call_mut call_once].freeze,
      meta_mids: %w[transmute from_raw_parts from_raw_parts_mut].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[std tokio fs env process net io].freeze,
      io_bare: %w[panic todo unimplemented unreachable].freeze,
      dir_context: %w[current_dir home_dir].freeze,
      context_pairs: {
        "SystemTime" => %w[now],
        "Instant" => %w[now]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[lock read write spawn await]).uniq.freeze,
      core_consts: [].freeze
    ).freeze
    ZIG_LEXICON = Lexicon.new(
      dispatch_mids: %w[field fieldParentPtr ptrCast alignCast call].freeze,
      meta_mids: %w[typeInfo TypeOf ptrCast intFromPtr ptrFromInt eval].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[std os fs process net Thread Mutex Atomic].freeze,
      io_bare: %w[panic unreachable].freeze,
      dir_context: [].freeze,
      context_pairs: {
        "time" => %w[timestamp nanoTimestamp milliTimestamp]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[lock unlock spawn wait signal]).uniq.freeze,
      core_consts: [].freeze
    ).freeze
    LUA_LEXICON = Lexicon.new(
      dispatch_mids: %w[load loadfile dofile require rawget rawset].freeze,
      meta_mids: %w[setmetatable getmetatable debug eval load loadfile].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[io os debug package].freeze,
      io_bare: %w[print error assert require collectgarbage].freeze,
      dir_context: [].freeze,
      context_pairs: {
        "os" => %w[time clock date getenv],
        "math" => %w[random]
      }.freeze,
      context_bare: [].freeze,
      callback_set: COMMON_CALLBACK_SET,
      core_consts: [].freeze
    ).freeze
    C_LEXICON = Lexicon.new(
      dispatch_mids: %w[dlsym dlopen GetProcAddress].freeze,
      meta_mids: %w[setjmp longjmp va_start va_arg].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[FILE DIR pthread mutex atomic].freeze,
      io_bare: %w[printf fprintf fopen open read write close system exec abort exit assert].freeze,
      dir_context: %w[getcwd getenv].freeze,
      context_pairs: EMPTY_PAIRS,
      context_bare: %w[rand time clock].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[pthread_mutex_lock pthread_mutex_unlock]).uniq.freeze,
      core_consts: [].freeze
    ).freeze
    CPP_LEXICON = Lexicon.new(
      dispatch_mids: %w[dynamic_cast typeid any_cast get_if visit invoke].freeze,
      meta_mids: %w[reinterpret_cast const_cast dlsym dlopen].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[std filesystem fstream iostream thread mutex atomic].freeze,
      io_bare: %w[throw abort exit assert system].freeze,
      dir_context: %w[current_path].freeze,
      context_pairs: {
        "chrono" => %w[now],
        "random_device" => %w[operator()]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[lock unlock try_lock wait notify_one notify_all]).uniq.freeze,
      core_consts: [].freeze
    ).freeze
    CSHARP_LEXICON = Lexicon.new(
      dispatch_mids: %w[Invoke GetMethod GetProperty GetField Activator CreateInstance].freeze,
      meta_mids: %w[Invoke GetType Reflection Emit DynamicMethod].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[Console File Directory Path Process Socket HttpClient Environment].freeze,
      io_bare: %w[throw].freeze,
      dir_context: %w[CurrentDirectory GetEnvironmentVariable].freeze,
      context_pairs: {
        "DateTime" => %w[Now UtcNow Today],
        "Guid" => %w[NewGuid],
        "Random" => %w[Next NextDouble]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[Lock Monitor Enter Exit Wait Pulse]).uniq.freeze,
      core_consts: [].freeze
    ).freeze
    JAVA_LEXICON = Lexicon.new(
      dispatch_mids: %w[invoke getMethod getDeclaredMethod getField getDeclaredField forName].freeze,
      meta_mids: %w[invoke setAccessible newInstance Proxy].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[System File Files Paths ProcessBuilder Socket HttpClient Thread Lock AtomicReference].freeze,
      io_bare: %w[throw].freeze,
      dir_context: %w[getProperty getenv].freeze,
      context_pairs: {
        "System" => %w[currentTimeMillis nanoTime getenv getProperty],
        "Instant" => %w[now],
        "UUID" => %w[randomUUID],
        "Math" => %w[random]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[lock unlock wait notify notifyAll submit execute]).uniq.freeze,
      core_consts: [].freeze
    ).freeze
    SWIFT_LEXICON = Lexicon.new(
      dispatch_mids: %w[perform value setValue selector NSClassFromString].freeze,
      meta_mids: %w[Mirror unsafeBitCast withUnsafePointer withUnsafeBytes].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[FileManager Process URLSession DispatchQueue Thread Lock NSLock].freeze,
      io_bare: %w[print fatalError preconditionFailure assertionFailure].freeze,
      dir_context: %w[currentDirectoryPath homeDirectoryForCurrentUser].freeze,
      context_pairs: {
        "Date" => %w[now],
        "UUID" => %w[init]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[lock unlock async sync]).uniq.freeze,
      core_consts: [].freeze
    ).freeze
    KOTLIN_LEXICON = Lexicon.new(
      dispatch_mids: %w[invoke call callBy memberProperties declaredMemberFunctions].freeze,
      meta_mids: %w[reflection javaClass Class forName setAccessible].freeze,
      method_obj_mids: %i[method].freeze,
      io_consts: %w[System File Files Paths ProcessBuilder Socket HttpClient Thread Mutex AtomicReference].freeze,
      io_bare: %w[println print error check require TODO].freeze,
      dir_context: %w[getProperty getenv].freeze,
      context_pairs: {
        "System" => %w[currentTimeMillis nanoTime getenv getProperty],
        "Instant" => %w[now],
        "UUID" => %w[randomUUID],
        "Random" => %w[nextInt nextLong nextDouble]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[lock unlock synchronized launch async await]).uniq.freeze,
      core_consts: [].freeze
    ).freeze
    LANGUAGE_LEXICONS = {
      ruby: RUBY_LEXICON,
      python: PYTHON_LEXICON,
      javascript: JS_LEXICON,
      typescript: JS_LEXICON,
      go: GO_LEXICON,
      rust: RUST_LEXICON,
      zig: ZIG_LEXICON,
      lua: LUA_LEXICON,
      c: C_LEXICON,
      cpp: CPP_LEXICON,
      csharp: CSHARP_LEXICON,
      java: JAVA_LEXICON,
      swift: SWIFT_LEXICON,
      kotlin: KOTLIN_LEXICON
    }.freeze

    # Compatibility aliases for tests and downstream code that inspect
    # detector constants directly.
    DISPATCH_MIDS = RUBY_LEXICON.dispatch_mids
    META_MIDS = RUBY_LEXICON.meta_mids
    METHOD_OBJ_MIDS = RUBY_LEXICON.method_obj_mids
    IO_CONSTS = RUBY_LEXICON.io_consts
    # bare `p`/`pp` deliberately excluded: single/double-letter, too
    # often a local-var bareword (VCALL) to flag as Kernel#p.
    IO_BARE = RUBY_LEXICON.io_bare
    DIR_CONTEXT = RUBY_LEXICON.dir_context
    CONTEXT_PAIRS = RUBY_LEXICON.context_pairs
    CONTEXT_BARE = RUBY_LEXICON.context_bare
    CALLBACK_SET = RUBY_LEXICON.callback_set
    CORE = RUBY_LEXICON.core_consts

    def self.scan(files)
      hits = []
      recs = []
      files.each do |f|
        root, lines = Ast.parse(f)
        e = new(f, lines, language: Syntax.language_for(f))
        e.walk(root, [], [])
        hits.concat(e.hits)
        recs.concat(e.classrecs)
      end
      Report.new(hits, recs)
    end

    attr_reader :hits, :classrecs

    def initialize(file, lines, language: :ruby, lexicon: nil)
      @file = file
      @lines = lines
      @language = language.to_sym
      @lexicon = lexicon || self.class.lexicon_for(@language)
      @hits = []
      @classrecs = []
    end

    def self.lexicon_for(language)
      LANGUAGE_LEXICONS.fetch(language.to_sym)
    end

    def walk(node, defs, cls)
      return unless Ast.node?(node)

      case node.type
      when :CLASS, :MODULE
        return walk_class(node, defs, cls)
      when :SCLASS
        return unless @language == :ruby

        recv = node.children[0]
        emit(:metaprogramming, "class << #{Ast.slice(recv, @lines)}",
             dn(defs), node) unless recv.type == :SELF
      when :DEFN, :DEFS
        nm = (node.type == :DEFN ? node.children[0] : node.children[1])
        emit(:metaprogramming, "def #{nm}", dn(defs), node) \
          if @language == :ruby && %i[method_missing respond_to_missing?].include?(nm)
        nd = Ast.def_push(node, defs)
        return node.children.each { |c| walk(c, nd, cls) }
      when :CALL, :FCALL, :VCALL, :OPCALL
        classify_call(node, defs)
      when :ATTRASGN
        emit(:hidden_mutation, node.children[1].to_s, dn(defs), node)
      when :OP_ASGN1, :OP_ASGN2
        emit(:hidden_mutation, "op-assign", dn(defs), node)
      when :GVAR, :GASGN
        emit(:context_dependency, node.children[0].to_s, dn(defs), node) if @language == :ruby
      when :XSTR, :DXSTR
        emit(:hidden_io, "backtick", dn(defs), node) if @language == :ruby
      when :YIELD
        emit(:dynamic_dispatch, "yield", dn(defs), node) if @language == :ruby
      when :ITER
        cm = callee_mid(node.children[0])
        emit(:callback_inversion, cm.to_s, dn(defs), node) \
          if cm && callback?(cm.to_s) && !@lexicon.meta_mids.include?(cm.to_s)
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
      based = Ast.node?(cpath) && cpath.type == :COLON2 &&
              !cpath.children[0].nil? && !cpath.text.to_s.start_with?("::")
      fqn = (cls + [const_text(cpath)]).join("::")
      if has_def?(body)
        core = cls.empty? && !based && @lexicon.core_consts.include?(simple)
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

      if (block_pass?(call) || block_literal_call?(call)) &&
          callback?(m) && !@lexicon.meta_mids.include?(m)
        return emit(:callback_inversion, m, dn(defs), call)
      end
      return emit(:metaprogramming, m, dn(defs), call) if @lexicon.meta_mids.include?(m)
      return emit(:dynamic_dispatch, m, dn(defs), call) if @lexicon.dispatch_mids.include?(m)

      if m == "call" && recv
        return emit(:dynamic_dispatch, "method(...).call", dn(defs), call) \
          if method_obj?(recv)
        return emit(:dynamic_dispatch, "#{Ast.slice(recv, @lines)}.call",
                    dn(defs), call) if var_recv?(recv)
      end

      cp = const_recv(recv)
      if cp
        base = cp.sub(/\A::/, "").split("::").first
        if base == "Dir" && @lexicon.dir_context.include?(m)
          return emit(:context_dependency, "Dir.#{m}", dn(defs), call)
        end
        if @lexicon.io_consts.include?(base) || (@language == :ruby && cp.start_with?("Net::"))
          return emit(:hidden_io, "#{cp}.#{m}", dn(defs), call)
        end
        if @language == :ruby
          return emit(:hidden_io, "URI.open", dn(defs), call) \
            if base == "URI" && m == "open"
          return emit(:context_dependency, "ENV", dn(defs), call) if cp == "ENV"
        end
        if @lexicon.context_pairs[base]&.include?(m)
          return emit(:context_dependency, "#{base}.#{m}", dn(defs), call)
        end
      end

      if recv.nil?
        return emit(:hidden_io, m, dn(defs), call) if @lexicon.io_bare.include?(m)
        return emit(:context_dependency, m, dn(defs), call) \
          if @lexicon.context_bare.include?(m)
      end

      if m.length > 1 && m.end_with?("!") && !%w[!= !~].include?(m)
        return emit(:hidden_mutation, m, dn(defs), call)
      end
      emit(:hidden_mutation, "<<", dn(defs), call) \
        if call.type == :OPCALL && m == "<<"
    end

    def callback?(str)
      @lexicon.callback_set.include?(str) ||
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

    def block_literal_call?(call)
      text = call.text.to_s
      text.include?("{") || text.match?(/\bdo\b/)
    end

    def method_obj?(recv)
      Ast.node?(recv) && %i[CALL FCALL].include?(recv.type) &&
        @lexicon.method_obj_mids.include?(
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
        return "::#{n.children[1]}" if n.text.to_s.start_with?("::")

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
