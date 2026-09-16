#!/usr/bin/env ruby
# frozen_string_literal: true

# Compile ONE function at a time with every call it makes stubbed out.
#
# The 54-file annotator SCC compiles as a single all-or-nothing package, so
# "what percentage compiles" has no answer at group level -- it is 0 until the
# whole thing type-checks. Per-function isolation is the only way to get a real
# number before then.
#
# Each probe keeps one function's body verbatim and replaces EVERY other
# function -- siblings in its own file included -- with a signature-matching
# stub. What remains to compile is exactly the target's own code.
#
#   ruby tools/selfhost_fn_probe.rb --file mir/mir_lowering.clear      # one file
#   ruby tools/selfhost_fn_probe.rb --all --jobs 24                    # the SCC
#   ruby tools/selfhost_fn_probe.rb --all --stage zig                  # through Zig
require 'open3'
require 'timeout'
require 'optparse'
require 'tmpdir'
require 'json'
require 'etc'
require 'fileutils'
require 'set'

saved = $PROGRAM_NAME
$PROGRAM_NAME = 'selfhost_fn_probe_support'
require_relative 'parser_compat'
$PROGRAM_NAME = saved

module SelfhostFnProbe
  extend self

  ROOT = File.expand_path('..', __dir__)
  # A measurement run needs to edit the tree it probes (neutralise a blocking
  # line to reveal the next error) without disturbing the real one, and needs
  # to do it in parallel -- so the source root is selectable.
  SRC = File.join(ROOT, ENV.fetch('CLEAR_PROBE_SRC', 'compiler/src'))

  Fn = Struct.new(:name, :file, :start, :finish, :text, :ret)

  def members
    ParserCompat.package_groups(SRC).max_by { |_n, m| m.length }.last
  end

  # The largest SCC is one package of many: the lexer, the parser and every
  # singleton file live outside it, so a run over `members` alone reports a
  # percentage of a subset. This is every translated file.
  def all_files
    Dir.glob(File.join(SRC, '**', '*.clear')).sort.map { |p| p.delete_prefix("#{SRC}/") }
  end

  # Split a file into its requires, its type declarations, and its functions.
  def dissect(path)
    lines = File.readlines(path)
    requires = []
    types = []
    fns = []
    loose = []
    i = 0
    while i < lines.length
      line = lines[i]
      if line.start_with?('REQUIRE')
        requires << line
        i += 1
      elsif line =~ /^EXTERN /
        # An EXTERN declaration is a type or symbol the Zig side provides; the
        # probe needs it or codegen fails on an undeclared identifier.
        start = i
        if line.rstrip.end_with?(';') || line.include?('}')
          i += 1
        else
          i += 1 until i >= lines.length || lines[i].strip == '}' || lines[i].rstrip.end_with?(';')
          i += 1
        end
        types << lines[start...i].join
      elsif line =~ /^(?:PUB |PRIVATE )?IMPLEMENTATION /
        # A struct's METHODs live in an IMPLEMENTATION block, not in the struct
        # declaration. Leaving it out of the type set made every call on one
        # report "no inherent METHOD" for a method the source defines.
        start = i
        depth = 0
        loop do
          depth += lines[i].count('{') - lines[i].count('}')
          i += 1
          break if i >= lines.length || depth <= 0
        end
        types << lines[start...i].join
      elsif line =~ /^(?:PUB |PRIVATE )?(?:STRUCT|UNION|ENUM) /
        start = i
        if line.rstrip.end_with?('}')
          i += 1
        else
          i += 1 until i >= lines.length || lines[i].strip == '}'
          i += 1
        end
        types << lines[start...i].join
      elsif (m = line.match(/^(?:PUB |PRIVATE )?FN ([\w?!]+)/))
        start = i
        i += 1 while i < lines.length && lines[i].rstrip != 'END'
        i += 1
        body = lines[start...i].join
        fns << Fn.new(m[1], path, start, i, body, return_type(body))
      else
        loose << line
        i += 1
      end
    end
    [requires, types, fns, loose]
  end

  def return_type(text)
    # A generic return (`[]Tuple<String, SymbolEntry@multiowned>`) has to come
    # back WHOLE: a truncated type reads as a different one and the stub then
    # fails its own RETURN.
    text[/\)\s*(?:\n\s*REQUIRES[^\n]*)*\s*RETURNS\s+([\w@?!\[\]{}]+(?:<[^>\n]*>)?)/m, 1] ||
      text[/RETURNS\s+([\w@?!\[\]{}]+(?:<[^>\n]*>)?)/, 1] || 'Void'
  end

  # A stub keeps the signature and drops the body. Everything the target calls
  # becomes one of these, so a failure can only come from the target itself.
  def stub(fn)
    # The signature ends at the first line that ENDS with `->`; a parameter
    # typed `FN(T) -> U` carries an arrow of its own mid-line.
    lines = fn.text.lines
    cut = lines.index { |l| l.rstrip.end_with?('->') } or return nil
    head = lines[0..cut].join.rstrip
    # A stub has no body, so a self-call is gone and REENTRANT no longer
    # describes it. Leaving the effect in makes the compiler reject the stub
    # for not being recursive -- a property of the stub, not of the caller.
    head = head.gsub(/\s*EFFECTS\s+REENTRANT(?::\w+)?/, '')
    ret = fn.ret.to_s.delete_prefix('!')
    body = stub_body(ret)
    "#{head}\n#{body}\nEND\n"
  end

  # `panic("stub")` is a NoReturn: assigning it to a cleanup-bearing local
  # leaves the ownership checker with no operand provenance, so the TARGET
  # gets blamed for a hole the stub introduced. A real value of the declared
  # shape carries provenance and keeps the probe measuring the target.
  STUB_VALUES = {
    'Void' => nil, 'String' => '""', 'String@symbol' => ':stub',
    'Int64' => '0', 'UInt64' => '0', 'Float64' => '0.0', 'Bool' => 'FALSE'
  }.freeze

  def stub_body(ret)
    return '  RETURN;' if ret == 'Void'
    # A String return has to be OWNED. A literal is rodata, so a caller that
    # binds the result to a cleanup-bearing local gets an ownership error that
    # belongs to the stub, not to the target. Interpolation allocates.
    payload = ret.delete_prefix('?')
    return %(  MUTABLE rtoc_stub_s = "stub${1.toString()}";\n  RETURN rtoc_stub_s;) if payload == 'String'
    return "  RETURN #{STUB_VALUES[ret]};" if STUB_VALUES[ret]
    return '  RETURN NIL;' if ret.start_with?('?')

    # A bare `Set[]` is a Set of Any and fails the declared return type, so the
    # empty collection is named before it is returned.
    empty = if payload.start_with?('[Set]') then 'Set[]'
            elsif payload.start_with?('[]') then 'List[]'
            elsif payload.start_with?('{') then '{}'
            end
    return %(  MUTABLE rtoc_stub_v: #{payload} = #{empty};\n  RETURN rtoc_stub_v;) if empty

    # A stub that panics gives its caller no provenance: a value transferred
    # out of it carries no AllocMark and the checker blames the TARGET for a
    # hole the stub introduced (TRANSFER_WITHOUT_ALLOC). Build a real value of
    # the declared shape whenever the shape is known.
    # A capability-wrapped return (`T@multiowned`) built from a struct literal
    # crashes the compiler's cleanup hoist. That is a real gap, but it is not
    # what the probe is measuring, so those stubs keep the panic body.
    if !payload.include?('@') && (built = default_value(payload, Set.new))
      return %(  MUTABLE rtoc_stub_v: #{payload} = #{built};\n  RETURN rtoc_stub_v;)
    end

    %(  panic("stub");)
  end

  # A literal of `type_str`, or nil when the shape cannot be built (a fixed
  # array, a cycle through a required field, or a type the probe cannot see).
  # Containers are decided BEFORE scalars: `[Set]String@symbol` is a set, not a
  # symbol, and reading the suffix first turned every such field into `:stub`.
  def default_value(type_str, seen)
    bare = type_str.to_s.strip
    return 'NIL' if bare.start_with?('?')
    return 'Set[]' if bare.start_with?('[Set]')
    return 'List[]' if bare.start_with?('[]')
    return '{}' if bare.start_with?('{') || bare.start_with?('HashMap<')
    return nil if bare =~ /\A\[\d+\]/

    bare = bare.sub(/@\w+(?::\w+)*\z/, '')
    return ':stub' if type_str.to_s.include?('@symbol')
    return '0' if %w[Int64 UInt64 Int32 UInt32 Int8 UInt8 Int16 UInt16 USize].include?(bare)
    return '0.0' if %w[Float64 Float32].include?(bare)
    return 'FALSE' if bare == 'Bool'
    # An owned String has to be ALLOCATED: a literal is rodata, and a caller
    # that transfers the field onward has no allocation to point at.
    return '"stub${1.toString()}"' if bare == 'String'
    return nil if seen.include?(bare)

    decl = type_index(@probe_cache || {})[bare] or return nil

    seen = seen + [bare]
    if (m = decl.match(/\A(?:PUB |PRIVATE )?ENUM #{Regexp.escape(bare)}\s*\{(.*?)\}/m))
      first = m[1].split(',').map(&:strip).reject(&:empty?).first or return nil
      return "#{bare}.#{first.split(/\s/).first}"
    end
    if (m = decl.match(/\A(?:PUB |PRIVATE )?UNION #{Regexp.escape(bare)}\s*\{(.*?)\}/m))
      variant, vtype = m[1].split(',').map(&:strip).reject(&:empty?).first.to_s.split(':', 2)
      return nil unless variant && vtype

      inner = default_value(vtype.strip, seen) or return nil
      return "#{bare}{ #{variant.strip}: #{inner} }"
    end
    if (m = decl.match(/\A(?:PUB |PRIVATE )?STRUCT #{Regexp.escape(bare)}\s*\{(.*?)^\}/m))
      fields = m[1].split("\n").map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
      pairs = fields.map do |line|
        fname, ftype = line.chomp(',').split(':', 2)
        return nil unless fname && ftype

        value = default_value(ftype.split('=').first.to_s.strip, seen) or return nil
        "#{fname.strip}: #{value}"
      end
      return "#{bare}{ #{pairs.join(', ')} }"
    end
    nil
  end

  def rewrite_require(line, relative)
    target =
      if (hex = line[/pkg:rtoc_([0-9a-f]+)/, 1])
        [hex].pack('H*')
      elsif (path = line[/REQUIRE "([^"]+)"/, 1]) && !path.start_with?('pkg:')
        File.expand_path(path, "/#{File.dirname(relative)}").delete_prefix('/')
      end
    return line unless target

    alias_part = line[/\sAS\s+\w+/]
    [target, %(REQUIRE "pkg:rtoc_#{target.unpack1('H*')}"#{alias_part}\n)]
  end

  # EXTERN declarations name what the Zig side provides. A package does not
  # re-export them, so the probe restates them itself.
  def extern_decls(cache)
    @extern_decls ||= begin
      seen = Set.new
      out = []
      all_files.each do |rel|
        path = File.join(SRC, rel)
        cache[path] ||= dissect(path)
        cache[path][1].each do |d|
          next unless d.start_with?('EXTERN')

          name = d[/\AEXTERN (?:STRUCT|UNION|ENUM|FN) ([\w?!]+)/, 1]
          next if name && !seen.add?(name)

          out << d
        end
      end
      out.join
    end
  end

  # The EXTERN FN declarations a file makes at its own top: a package does not
  # export them, so the probe module needs its own copy. EXTERN TYPES come from
  # the types package -- declaring those twice breaks the backend.
  def own_externs(path, cache)
    cache[path] ||= dissect(path)
    own = cache[path][1].select { |d| d.start_with?('EXTERN FN') }
    return '' if own.empty?

    "\n# --- EXTERN block from #{rel(path)} ---\n" + own.join
  end

  def stdlib_requires
    @stdlib_requires ||= begin
      seen = Set.new
      all_files.each do |rel|
        File.foreach(File.join(SRC, rel)) do |line|
          break unless line.start_with?('REQUIRE') || line.strip.empty?

          seen << line if line =~ /REQUIRE "pkg:[a-z_]+"/
        end
      end
      seen.to_a.sort.join
    end
  end

  def all_files
    @all_files ||= Dir.glob(File.join(SRC, '**', '*.clear')).sort.map { |p| p.sub("#{SRC}/", '') }
  end

  # A shared package of every TYPE in the tree, requiring nothing. Compiled
  # once -- `transpile_cached` is content-addressed -- and required by all
  # 3405 probes. Function stubs are NOT in here: a probe only needs stand-ins
  # for what its own target calls, which is a few dozen names, so putting all
  # 10228 of them in the shared package would make every probe pay for them.
  def types_package(cache)
    @types_package ||= begin
      out = []
      seen = Set.new
      all_files.each do |rel|
        path = File.join(SRC, rel)
        cache[path] ||= dissect(path)
        cache[path][1].each do |d|
          # EXTERN FN declarations repeat across files too, so dedupe on
          # whatever a declaration names, not just on struct/union/enum.
          name = d[/\A(?:PUB |EXTERN )*(?:STRUCT|UNION|ENUM|FN) ([\w?!]+)/, 1]
          impl_owner = d[/\AIMPLEMENTATION ([\w?!]+)/, 1]
          next if impl_owner
          # An EXTERN FN is not PUB, so the package does not export it and the
          # probe module cannot call it; the head carries the target file's own
          # instead. EXTERN TYPES stay here: a stub signature can name one, and
          # declaring the same EXTERN struct in both modules leaves the backend
          # referencing a name neither exports.
          next if d.start_with?('EXTERN FN')
          # A type with an IMPLEMENTATION block keeps its methods out of the
          # package, but its DECLARATION still has to be here: other structs
          # have fields typed by it, and dropping it leaves the backend
          # emitting a reference to a name nothing declares.
          next if name && inherent_owners(cache).include?(name) &&
                  !d[/\A(?:PUB )?(?:STRUCT|UNION|ENUM) /]
          next if name && !seen.add?(name)

          # The package has fields typed by EXTERN structs, so it needs the
          # declarations itself. Transpiling only checks names and passes
          # without them; compiling the package's Zig does not.
          # An IMPLEMENTATION block takes no visibility modifier.
          out << if d.start_with?('EXTERN') || d.start_with?('PUB ') || d.start_with?('IMPLEMENTATION')
                   d
                 else
                   "PUB #{d}"
                 end
        end
      end
      # Non-rtoc requires name real external packages (stdlib path, fs, regex).
      # Dropping them makes the probe report `Undefined function 'expand'` for
      # a file that does require it.
      externals = Set.new
      all_files.each do |rel|
        cache[File.join(SRC, rel)][0].each { |line| externals << line if line =~ /REQUIRE "pkg:[a-z_]+"/ }
      end
      externals.to_a.sort.join + out.join
    end
  end

  # Every function in the tree, by name, so a probe can stand in for whatever
  # its target calls.
  def fn_index(cache)
    @fn_index ||= begin
      idx = {}
      all_files.each do |rel|
        path = File.join(SRC, rel)
        cache[path] ||= dissect(path)
        cache[path][2].each { |f| idx[f.name] ||= f }
      end
      idx
    end
  end

  # A probe is then tiny: require the types, stub exactly what the target
  # calls, and restate the target under a name that cannot collide with its
  # own stub.
  # A file's module-level constants are as much a part of a function's context
  # as the functions it calls: `FOR c IN conflicts` reads one. Without them the
  # probe reports "Undefined variable" for something the real build resolves --
  # a harness artifact, not a translation defect.
  # A file's module scope is its constants AND its module-level MUTABLE
  # variables. Carrying only the constants made every function that reads a
  # file-level mutable (`enabled`, a registry cache) report an undefined
  # variable the source does not have -- a probe artifact counted as a blocker.
  def module_consts(target)
    # dissect already separated what sits OUTSIDE a function; a regex over raw
    # lines cannot, and swept up the body of every function the corpus does not
    # indent -- carrying its locals in as module declarations.
    @module_scope ||= {}
    loose = (@module_scope[target.file] ||= dissect(target.file)[3])
    decls = loose.select do |line|
      line.match?(/\A(?:PUB )?MUTABLE [a-z_]\w*(?:: [^=\n]+)? = /) ||
        line.match?(/\A[a-z_]\w*(?:: [^=\n]+)? = /)
    end
    return '' if decls.empty?

    "\n# --- module scope from #{rel(target.file)} ---\n" + decls.join
  end

  # An IMPLEMENTATION block carries no visibility modifier, so its inherent
  # METHODs are not reachable across the package boundary the probe puts
  # between the target and the types package. The target's OWN file declares
  # them, so repeat those blocks beside it -- otherwise every call on such a
  # method reports an undefined `__inherent_*` dispatcher the source defines.
  def own_implementations(target, cache)
    cache[target.file] ||= dissect(target.file)
    decls = cache[target.file][1]
    own = decls.select { |d| d.start_with?('IMPLEMENTATION') }
    return '' if own.empty?

    # An inherent METHOD may only be added to a type declared in the same file,
    # so the owning STRUCT has to come along. Those pairs are excluded from the
    # shared types package for exactly this reason.
    owners = own.filter_map { |d| d[/\AIMPLEMENTATION ([\w?!]+)/, 1] }
    structs = decls.select { |d| owners.any? { |o| d =~ /\A(?:PUB |PRIVATE )?STRUCT #{Regexp.escape(o)}\b/ } }
    "\n# --- inherent METHODs from #{rel(target.file)} ---\n" + structs.join + own.join
  end

  # The names of types whose METHODs live in an IMPLEMENTATION in the same
  # file: file-local by the language's rule, so the shared package must not
  # declare them.
  def inherent_owners(cache)
    @inherent_owners ||= all_files.each_with_object(Set.new) do |rel_path, set|
      path = File.join(SRC, rel_path)
      cache[path] ||= dissect(path)
      cache[path][1].each do |d|
        name = d[/\AIMPLEMENTATION ([\w?!]+)/, 1]
        set << name if name
      end
    end
  end

  def probe_source(target, _group, cache, pkg_name)
    idx = fn_index(cache)
    safe = "probe__#{target.name.delete('?').delete('!')}"
    # A stub keeps its signature, and a parameter's DEFAULT value can call
    # something -- so the call set has to close over the stubs themselves or
    # the probe reports an undefined function the target never mentions.
    # The module scope is emitted alongside the target, so whatever ITS
    # initializers call needs a stand-in too -- otherwise carrying a file-level
    # MUTABLE whose value comes from another unit reports that unit's function
    # as undefined.
    scope = module_consts(target)
    want = (target.text + scope).scan(/(?<![\w.])([a-zA-Z_]\w*[?!]?)\(/).flatten.uniq
    emitted = {}
    until want.empty?
      name = want.shift
      next if name == target.name || emitted.key?(name)

      f = idx[name] or next
      s = stub(f) or next

      emitted[name] = s.sub(/\A(PUB |PRIVATE )?FN /, 'FN ')
      want.concat(s.scan(/(?<![\w.])([a-zA-Z_]\w*[?!]?)\(/).flatten)
    end
    stubs = emitted.values
    body = target.text.sub(/\A(PUB |PRIVATE )?FN #{Regexp.escape(target.name)}/, "FN #{safe}")
    # A recursive call names the target, which the probe has just renamed and
    # which is deliberately absent from the stub set. Point it at the copy.
    body = body.gsub(/(?<![\w.])#{Regexp.escape(target.name)}\(/, "#{safe}(")

    # The types package already carries the EXTERN block, and the probe
    # requires it. Declaring the same EXTERN struct in both modules makes the
    # backend emit a reference to a name neither module exports.
    head = [stdlib_requires, %(REQUIRE "pkg:#{pkg_name}"\n), "\n",
            own_externs(target.file, cache),
            own_implementations(target, cache),
            module_consts(target), "\n# --- stand-ins for what it calls ---\n", stubs.join,
            "\n# --- #{rel(target.file)} : #{target.name} ---\n"].join
    @probe_offset = head.lines.length
    # Stage 3 supplies a main() that runs recorded inputs through the target
    # and asserts Ruby's answers; without one the probe only proves it links.
    main_body = ENV['FN_PROBE_MAIN'] && File.exist?(ENV['FN_PROBE_MAIN']) ? File.read(ENV['FN_PROBE_MAIN']) : "  RETURN;\n"
    head + body + "\nFN main() RETURNS !Void ->\n#{main_body}END\n"
  end

  # Whole-file mode: every function of ONE file, verbatim, with only the calls
  # that LEAVE the file stubbed. A clean build settles the entire file at 2c in
  # a single compile instead of one per function -- 177 builds for the corpus
  # rather than ~17k -- and a failing build's position maps back to the
  # function that contains it.
  def whole_file_source(path, cache, pkg_name)
    cache[path] ||= dissect(path)
    fns = cache[path][2]
    return nil if fns.empty?

    seed = fns.first
    idx = fn_index(cache)
    own = fns.map(&:name).to_set
    scope = module_consts(seed)
    want = (fns.map(&:text).join + scope).scan(/(?<![\w.])([a-zA-Z_]\w*[?!]?)\(/).flatten.uniq
    emitted = {}
    until want.empty?
      name = want.shift
      next if own.include?(name) || emitted.key?(name)

      f = idx[name] or next
      s = stub(f) or next

      emitted[name] = s.sub(/\A(PUB |PRIVATE )?FN /, 'FN ')
      want.concat(s.scan(/(?<![\w.])([a-zA-Z_]\w*[?!]?)\(/).flatten)
    end

    head = [stdlib_requires, %(REQUIRE "pkg:#{pkg_name}"\n), "\n",
            own_externs(path, cache),
            own_implementations(seed, cache), scope,
            "\n# --- stand-ins for what it calls ---\n", emitted.values.join,
            "\n# --- #{rel(path)} ---\n"].join
    at = head.lines.length + 1
    spans = []
    body = +''
    fns.each do |f|
      spans << [at, at + f.text.lines.length - 1, f]
      body << f.text
      at += f.text.lines.length
    end
    [head + body + "\nFN main() RETURNS !Void ->\n  RETURN;\nEND\n", spans]
  end

  def rel(path) = path.sub("#{SRC}/", '')

  # Every type declaration in the group, by the name it declares.
  def type_index(cache)
    @type_index ||= begin
      idx = {}
      cache.each_value do |(_rq, types, _fns, _loose)|
        types.each do |decl|
          name = decl[/\A(?:PUB )?(?:STRUCT|UNION|ENUM) (\w+)/, 1] or next
          idx[name] ||= decl
        end
      end
      idx
    end
  end

  # The declarations a probe needs: what the target names, plus what those
  # declarations name, to a fixed point. Including all of them instead makes a
  # mir_lowering probe 287 KB and ten minutes; this keeps it to what is used.
  def needed_types(seed_text, cache)
    idx = type_index(cache)
    want = Set.new
    queue = seed_text.scan(/\b([A-Z]\w*)\b/).flatten.uniq
    until queue.empty?
      name = queue.pop
      next if want.include?(name)
      decl = idx[name] or next

      want << name
      queue.concat(decl.scan(/\b([A-Z]\w*)\b/).flatten)
    end
    idx.select { |n, _| want.include?(n) }
  end

  # Open3.capture3 with a real deadline. A `timeout` wrapper is not enough: it
  # kills its own child, but the zig grandchildren survive holding the pipe, so
  # the read blocks forever anyway. Run the build in its own process GROUP and
  # let a watchdog kill the group, which is the only thing that reaches them.
  def capture3_with_group_timeout(env, cmd, seconds)
    Open3.popen3(env, *cmd, chdir: ROOT, pgroup: true) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      pid = wait_thr.pid
      # Capture the group NOW. Looking it up after the deadline can find a
      # RECYCLED pid's group -- which is how a timeout came to kill this
      # process's own workers and leave the parent asleep in waitpid.
      pgid = begin
        Process.getpgid(pid)
      rescue StandardError
        nil
      end
      watchdog = Thread.new do
        unless wait_thr.join(seconds)
          begin
            Process.kill('-KILL', pgid) if pgid && pgid != Process.getpgid(0)
          rescue StandardError
            nil
          end
        end
      end
      out = stdout.read.to_s
      err = stderr.read.to_s
      status = wait_thr.value
      watchdog.kill
      [out, err, status]
    end
  end

  # A probe build's cache entry is never reused -- every probe is a different
  # module -- but `clear` only prunes entries older than an hour, so a corpus
  # run accumulates gigabytes and ends in ENOSPC. Drop entries old enough that
  # no concurrent build can still be using them.
  def prune_probe_cache!
    cutoff = Time.now - 120
    Dir.glob(File.join(ROOT, 'zig', '.clear-cache', '*')).each do |path|
      next unless File.directory?(path)
      next if File.mtime(path) > cutoff

      FileUtils.rm_rf(path)
    end
  rescue StandardError
    nil
  end

  def compile(source_text, stage, extra_pkg = nil)
    Dir.mktmpdir('fn-probe') do |dir|
      source = File.join(dir, 'probe.clear')
      File.write(source, source_text)
      # A failing probe is worth reading; the temp dir is gone by the time the
      # error is reported.
      if ENV['CLEAR_PROBE_KEEP']
        FileUtils.mkdir_p(ENV['CLEAR_PROBE_KEEP'])
        FileUtils.cp(source, File.join(ENV['CLEAR_PROBE_KEEP'], 'probe.clear'))
      end
      # Sibling .zig modules an EXTERN names live beside the CLEAR sources and
      # in the runtime tree; without both dirs the link stage reports
      # FileNotFound for alloc-profile.zig and compiler_regex.zig.
      native_dirs = [SRC, File.join(ROOT, 'zig'), File.join(ROOT, 'zig', 'runtime')].join(File::PATH_SEPARATOR)
      env = { 'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8', 'CLEAR_EXTRA_NATIVE_DIRS' => native_dirs }
      # Zig's local cache is not safe to share across concurrent builds: at high
      # job counts probes clobber each other's entries and the link stage
      # reports FileNotFound for runtime modules that are plainly present.
      # Each probe gets its own.
      env['ZIG_LOCAL_CACHE_DIR'] = File.join(dir, 'zig-cache')
      case stage
      when :clear
        env['CLEAR_TRANSPILE_ONLY'] = '1'
        env['CLEAR_DISABLE_BUILD_ZIG'] = '1'
      when :zig, :binary, :run
        # no flags: emit Zig, compile it, and link an executable
      end
      cmd = [File.join(ROOT, 'clear'), 'build', source, '-o', File.join(dir, 'probe'),
             '--no-stack-check', '--main-tier', 'service',
             *ParserCompat.package_flags(SRC), *Array(extra_pkg)]
      # One pathological function can hang the compiler; without a cap it takes
      # the whole sweep with it (observed twice, stalling a 3443-function run).
      out, err, status = capture3_with_group_timeout(env, cmd, 300)
      if stage == :run && status.success?
        # Stage 3 needs what the function actually produced, not just that it
        # linked.
        rout, rerr, rstatus = Open3.capture3('timeout', '60', File.join(dir, 'probe'))
        # `print` writes to stderr, so stage 3 was comparing an always-empty
        # stdout against Ruby's recorded result.
        return [rstatus.success?, "#{rout}#{rerr}".strip, nil]
      end
      text = "#{out}\n#{err}"
      msg = text[/\[Compiler Error\][^\n]*|\[Parser Error\][^\n]*|[^\n]*\berror: [^\n]*/, 0]
      # A Zig diagnostic says almost nothing without the source line under it,
      # and its position is in the EMITTED file, which no CLEAR line maps to.
      # Zig reports every error it finds, and each one is a real codegen defect
      # -- keeping only the first makes a file look one fix away when it is
      # several, and hides whole classes behind whichever came first.
      zig_errors = text.scan(/^[^\n]*\.zig:\d+:\d+: error: [^\n]*(?:\n[^\n]*){0,2}/)
                       .map { |chunk| chunk.lines.map(&:strip).reject(&:empty?).join(' | ') }
                       .uniq
      msg = zig_errors.join("\n") unless zig_errors.empty?
      # A guidance run wants every diagnostic the compiler could reach, not the
      # first one. Measurement never sets this, so the recorded number is
      # unchanged.
      if ENV['CLEAR_PROBE_ALL_ERRORS'] == '1'
        all = text.scan(/\[Compiler Error\][^\n]*|\[Parser Error\][^\n]*/).uniq
        msg = all.join("\n") unless all.empty?
      end
      # The extras carry their own position (the banner only describes the
      # first), so a guidance run can anchor each one.
      extras = text.scan(/\[Compiler Error\][^\n]*@@PL=(\d+)@@PC=(\d+)/)
      probe_line = text[/^\s*(\d+) \|/, 1] || text[/line (\d+)/, 1]
      # The column is what makes a positional diagnostic anchorable: several
      # rules otherwise have to guess which argument on the line the compiler
      # meant, and refuse whenever the guess is ambiguous.
      probe_col = text[/Column (\d+)/, 1]
      # Not every failure announces itself with one of those banners -- a Ruby
      # backtrace out of the compiler, a Zig error, an ENOSPC. Fall back to the
      # last lines that are not warnings, so no failure lands without a reason.
      msg ||= text.lines.grep(/Error|error/).reject { |l| l.include?('[Warning]') }
                  .reject { |l| l =~ /\A\s*(from|\t)/ }.last.to_s.strip
      msg = text.lines.reject { |l| l.include?('[Warning]') || l.strip.empty? }.last(2).join(' ').strip if msg.empty?
      # The MIR checker prints its violations after the banner, and the banner
      # alone says nothing about which invariant broke.
      if (violations = text[/MIR ownership verification failed[^\n]*\n\n(.+)/m, 1])
        msg = "MIR ownership: #{violations.lines.first(2).join(' ').strip}"
      end
      [status.success?, msg.to_s.gsub(/\e\[[0-9;]*m/, '')[0, 4000], probe_line, probe_col]
    end
  end

  def main(argv)
    only_file = nil
    only_fns = nil
    out_path = nil
    jobs = [Etc.nprocessors - 4, 1].max
    stage = :clear
    limit = nil
    passing = nil
    all_files_mode = false
    stub_census = nil
    whole_file = false
    OptionParser.new do |p|
      # Several files at once: the annotator is three of them, and measuring
      # just those skips a hang in an unrelated file that has killed whole runs.
      p.on('--file REL') { |v| (only_file ||= []).concat(v.split(',')) }
      # Probing one function is the fast edit/measure loop; a full file is minutes.
      p.on('--fn NAMES') { |v| only_fns = v.split(',').to_set }
      p.on('--all') { only_file = nil }
      # Depth workers run one per file at once; a shared result path would
      # have them clobbering each other's JSON.
      p.on('--out PATH') { |v| out_path = v }
      p.on('--jobs N', Integer) { |v| jobs = v }
      p.on('--stage S') { |v| stage = v.to_sym }
      p.on('--limit N', Integer) { |v| limit = v }
      # Stage 2 only makes sense for what already passed stage 1.
      p.on('--passing FILE') { |v| passing = v }
      p.on('--all-files', 'Probe every translated file, not just the largest package group') { all_files_mode = true }
      # Which functions call nothing internal: those are the ones a recorded-
      # input run can execute today, because they have no stub to trap on.
      p.on('--stub-census PATH') { |v| stub_census = v }
      p.on('--whole-file', 'One build per FILE with outside calls stubbed') { whole_file = true }
    end.parse!(argv)

    group = all_files_mode ? all_files : members
    files = only_file ? Array(only_file) : group
    cache = {}
    # --file may name a file outside the package group; dissect whatever is
    # actually going to be probed, not just the group.
    (group | files).each { |m| cache[File.join(SRC, m)] = dissect(File.join(SRC, m)) }

    # Stub bodies need the type declarations to build a value of the declared
    # shape; warm the index here so worker threads never race to build it.
    @probe_cache = cache
    type_index(cache)

    targets = files.flat_map { |f| cache[File.join(SRC, f)][2] }
    if passing
      allow = JSON.parse(File.read(passing)).select { |r| r['ok'] }
                  .map { |r| [r['file'], r['fn']] }.to_set
      targets = targets.select { |t| allow.include?([rel(t.file), t.name]) }
    end
    targets = targets.select { |t| only_fns.include?(t.name) } if only_fns
    targets = targets.first(limit) if limit
    warn "#{targets.length} functions across #{files.length} file(s); #{jobs} jobs; stage=#{stage}"

    if stub_census
      rows = targets.map do |t|
        src = probe_source(t, nil, cache, 'fnprobe_types')
        names = src[/# --- stand-ins for what it calls ---\n(.*?)\n# --- /m, 1].to_s
                   .scan(/^FN ([\w?!]+)\(/).flatten
        { 'file' => rel(t.file), 'fn' => t.name, 'stubs' => names.length, 'stub_names' => names }
      end
      File.write(stub_census, JSON.pretty_generate(rows))
      empty = rows.count { |r| r['stubs'].zero? }
      warn "stub census: #{empty}/#{rows.length} functions call nothing internal"
      return 0
    end

    stub_dir = File.join(ROOT, 'tmp', 'fnprobe')
    FileUtils.mkdir_p(stub_dir)
    stub_path = File.join(stub_dir, 'types.clear')
    File.write(stub_path, types_package(cache))
    pkg_name = 'fnprobe_types'
    pkg_flag = ["--pkg", "#{pkg_name}=#{stub_path}"]
    warn "types package: #{File.read(stub_path).lines.length} lines"

    if whole_file
      paths = files.map { |f| File.join(SRC, f) }
      warn "whole-file: #{paths.length} file(s); #{jobs} jobs; stage=#{stage}"
      wf_queue = Queue.new
      paths.each_with_index { |pth, i| wf_queue << [i, pth] }
      rows = Array.new(paths.length)
      wf_done = 0
      wf_mutex = Mutex.new
      wf_out = out_path || File.join(ROOT, '.fn_probe_whole.json')
      wf_workers = Array.new(jobs) do
        Thread.new do
          loop do
            i, path = begin
              wf_queue.pop(true)
            rescue ThreadError
              break
            end
            ok, msg, pcol, fn_name, src_line = begin
              built = whole_file_source(path, cache, pkg_name)
              if built.nil?
                [true, nil, nil, nil, nil]
              else
                src, spans = built
                o, m, l, c = compile(src, stage, pkg_flag)
                # A probe line sits inside exactly one function's span, and the
                # function is restated verbatim, so the offset carries straight
                # back to its line in the real file.
                span = l ? spans.find { |s, e, _f| l.to_i >= s && l.to_i <= e } : nil
                [o, m, c, span && span[2].name, span ? span[2].start + (l.to_i - span[0]) : nil]
              end
            rescue StandardError => e
              [false, "probe harness: #{e.class}: #{e.message}"[0, 200], nil, nil, nil]
            end
            rows[i] = { 'file' => rel(path), 'fn' => fn_name, 'ok' => ok,
                        'error' => msg, 'line' => src_line, 'col' => pcol&.to_i }
            wf_mutex.synchronize do
              wf_done += 1
              warn format('  %3d/%-3d %-50s %s', wf_done, paths.length, rel(path),
                          ok ? 'clean' : "#{fn_name || '?'}: #{msg.to_s.lines.first.to_s.strip[0, 78]}")
              File.write(wf_out, JSON.pretty_generate(rows.compact))
            end
            # Each stage-zig build leaves a cache behind; unswept they fill the
            # disk mid-run and every later build fails for a reason that has
            # nothing to do with the file being probed.
            if stage != :clear
              free = begin
                Timeout.timeout(20) { `df -P #{ROOT} | tail -1`.split[3].to_i }
              rescue StandardError
                nil
              end
              # The transpile cache has no age-based prune of its own.
              if free && free < 2_000_000
                FileUtils.rm_rf(File.join(ROOT, 'zig', '.clear-transpile-cache'))
              end
              prune_probe_cache!
            end
          end
        end
      end
      wf_workers.each(&:join)
      got = rows.compact
      File.write(wf_out, JSON.pretty_generate(got))
      puts
      puts "#{got.count { |r| r['ok'] }}/#{got.length} files compile whole with outside calls stubbed"
      return 0
    end

    queue = Queue.new
    targets.each_with_index { |t, i| queue << [i, t] }
    results = Array.new(targets.length)
    done = 0
    mutex = Mutex.new
    workers = Array.new(jobs) do
      Thread.new do
        until queue.empty?
          idx, target = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          # A raise ANYWHERE in here used to kill the worker thread silently:
          # Ruby swallows it, the pool drains to nothing, and the run hangs
          # with the parent asleep in waitpid. Building the source counts --
          # it reads the target's file -- so the rescue has to cover that too.
          offset = @probe_offset
          ok, msg, probe_line, probe_col = begin
            src = probe_source(target, group, cache, pkg_name)
            offset = @probe_offset
            compile(src, stage, pkg_flag)
          rescue StandardError => e
            [false, "probe harness: #{e.class}: #{e.message}"[0, 200], nil, nil]
          end
          # The target is restated verbatim, so a probe line maps straight back.
          line = probe_line ? target.start + (probe_line.to_i - offset) : nil
          # A guidance run tags each extra diagnostic with its own probe
          # position; map those the same way so every one is anchorable.
          if msg && msg.include?('@@PL=')
            msg = msg.gsub(/@@PL=(\d+)@@PC=(\d+)/) do
              "@@L=#{target.start + (::Regexp.last_match(1).to_i - offset)}@@C=#{::Regexp.last_match(2)}"
            end
          end
          results[idx] = [rel(target.file), target.name, ok, msg, line, probe_col&.to_i]
          # Only the counter and the progress write belong under the lock. The
          # cache sweep used to run here too -- including a `df` BACKTICK, whose
          # waitpid held the mutex and stalled every worker behind it.
          sweep_now = false
          mutex.synchronize do
            done += 1
            sweep_now = (done % (stage == :clear ? 200 : 15)).zero?
            if (done % 20).zero?
              good = results.count { |r| r && r[2] }
              warn "  #{done}/#{targets.length}  compiling: #{good} (#{(100.0 * good / done).round(1)}%)"
              File.write((out_path || File.join(ROOT, (only_file || only_fns) ? '.fn_probe_file.json' : '.fn_probe.json')),
                         JSON.generate(
                           results.compact.map { |f, n, o, m, l, c| { file: f, fn: n, ok: o, error: m, line: l, col: c } }))
            end
          end
          if sweep_now
            # Only entries no in-flight build is using: deleting the whole cache
            # mid-build removes the runtime modules other workers staged.
            cutoff = Time.now - 300
            Dir.glob(File.join(ROOT, 'zig', '.clear-cache', '*')).each do |entry|
              FileUtils.rm_rf(entry) if File.mtime(entry) < cutoff
            rescue Errno::ENOENT
              next
            end
            stat = begin
              Timeout.timeout(20) { `df -P #{ROOT} | tail -1`.split[3].to_i }
            rescue StandardError
              nil
            end
            FileUtils.rm_rf(File.join(ROOT, 'zig', '.clear-transpile-cache')) if stat && stat < 2_000_000
          end
        end
      end
    end
    workers.each(&:join)

    ok = results.count { |r| r && r[2] }
    puts
    puts "#{ok}/#{results.length} functions compile with their calls stubbed " \
         "(#{(100.0 * ok / results.length).round(1)}%)"
    by_file = results.compact.group_by(&:first)
    puts
    by_file.sort_by { |_f, rs| rs.count { |r| !r[2] } }.reverse.first(15).each do |f, rs|
      bad = rs.count { |r| !r[2] }
      next if bad.zero?

      puts format('  %3d/%3d fail  %s', bad, rs.length, f)
    end
    File.write((out_path || File.join(ROOT, (only_file || only_fns) ? '.fn_probe_file.json' : '.fn_probe.json')), JSON.pretty_generate(
                 results.compact.map { |f, n, o, m, l, c| { file: f, fn: n, ok: o, error: m, line: l, col: c } }
               ))
    warn "\nwrote .fn_probe.json"
    0
  end
end

exit(SelfhostFnProbe.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_fn_probe.rb')
