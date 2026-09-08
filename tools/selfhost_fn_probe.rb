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

    %(  panic("stub");)
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
          next if name && !seen.add?(name)

          # The package has fields typed by EXTERN structs, so it needs the
          # declarations itself. Transpiling only checks names and passes
          # without them; compiling the package's Zig does not.
          out << (d.start_with?('EXTERN') || d.start_with?('PUB ') ? d : "PUB #{d}")
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
  def module_consts(target)
    decls = File.read(target.file).lines.select do |line|
      line.match?(/\A[a-z_]\w*(?:: [^=\n]+)? = /)
    end
    return '' if decls.empty?

    "\n# --- module-level constants from #{rel(target.file)} ---\n" + decls.join
  end

  def probe_source(target, _group, cache, pkg_name)
    idx = fn_index(cache)
    safe = "probe__#{target.name.delete('?').delete('!')}"
    # A stub keeps its signature, and a parameter's DEFAULT value can call
    # something -- so the call set has to close over the stubs themselves or
    # the probe reports an undefined function the target never mentions.
    want = target.text.scan(/(?<![\w.])([a-zA-Z_]\w*[?!]?)\(/).flatten.uniq
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

    head = [stdlib_requires, %(REQUIRE "pkg:#{pkg_name}"\n), "\n", extern_decls(cache),
            module_consts(target), "\n# --- stand-ins for what it calls ---\n", stubs.join,
            "\n# --- #{rel(target.file)} : #{target.name} ---\n"].join
    @probe_offset = head.lines.length
    # Stage 3 supplies a main() that runs recorded inputs through the target
    # and asserts Ruby's answers; without one the probe only proves it links.
    main_body = ENV['FN_PROBE_MAIN'] && File.exist?(ENV['FN_PROBE_MAIN']) ? File.read(ENV['FN_PROBE_MAIN']) : "  RETURN;\n"
    head + body + "\nFN main() RETURNS !Void ->\n#{main_body}END\n"
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
      msg = text[/\[Compiler Error\][^\n]*|\[Parser Error\][^\n]*|error: [^\n]*/, 0]
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
      [status.success?, msg.to_s.gsub(/\e\[[0-9;]*m/, '')[0, 200], probe_line, probe_col]
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
    end.parse!(argv)

    group = members
    files = only_file ? Array(only_file) : group
    cache = {}
    group.each { |m| cache[File.join(SRC, m)] = dissect(File.join(SRC, m)) }

    targets = files.flat_map { |f| cache[File.join(SRC, f)][2] }
    if passing
      allow = JSON.parse(File.read(passing)).select { |r| r['ok'] }
                  .map { |r| [r['file'], r['fn']] }.to_set
      targets = targets.select { |t| allow.include?([rel(t.file), t.name]) }
    end
    targets = targets.select { |t| only_fns.include?(t.name) } if only_fns
    targets = targets.first(limit) if limit
    warn "#{targets.length} functions across #{files.length} file(s); #{jobs} jobs; stage=#{stage}"

    stub_dir = File.join(ROOT, 'tmp', 'fnprobe')
    FileUtils.mkdir_p(stub_dir)
    stub_path = File.join(stub_dir, 'types.clear')
    File.write(stub_path, types_package(cache))
    pkg_name = 'fnprobe_types'
    pkg_flag = ["--pkg", "#{pkg_name}=#{stub_path}"]
    warn "types package: #{File.read(stub_path).lines.length} lines"

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
