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
  SRC = File.join(ROOT, 'compiler', 'src')

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
    text[/\)\s*(?:\n\s*REQUIRES[^\n]*)*\s*RETURNS\s+([\w@?!\[\]{}]+)/m, 1] ||
      text[/RETURNS\s+([\w@?!\[\]{}]+)/, 1] || 'Void'
  end

  # A stub keeps the signature and drops the body. Everything the target calls
  # becomes one of these, so a failure can only come from the target itself.
  def stub(fn)
    # The signature ends at the first line that ENDS with `->`; a parameter
    # typed `FN(T) -> U` carries an arrow of its own mid-line.
    lines = fn.text.lines
    cut = lines.index { |l| l.rstrip.end_with?('->') } or return nil
    head = lines[0..cut].join.rstrip
    ret = fn.ret.to_s.delete_prefix('!')
    body = ret == 'Void' ? '  RETURN;' : %(  panic("stub");)
    "#{head}\n#{body}\nEND\n"
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

          out << (d.start_with?('PUB ', 'EXTERN') ? d : "PUB #{d}")
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

    head = [%(REQUIRE "pkg:#{pkg_name}"\n),
            "\n# --- stand-ins for what it calls ---\n", stubs.join,
            "\n# --- #{rel(target.file)} : #{target.name} ---\n"].join
    @probe_offset = head.lines.length
    head + body + "\nFN main() RETURNS !Void ->\n  RETURN;\nEND\n"
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

  def compile(source_text, stage, extra_pkg = nil)
    Dir.mktmpdir('fn-probe') do |dir|
      source = File.join(dir, 'probe.clear')
      File.write(source, source_text)
      env = { 'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8', 'CLEAR_EXTRA_NATIVE_DIRS' => SRC }
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
      out, err, status = Open3.capture3(env, *cmd, chdir: ROOT)
      if stage == :run && status.success?
        # Stage 3 needs what the function actually produced, not just that it
        # linked.
        rout, rerr, rstatus = Open3.capture3(File.join(dir, 'probe'))
        return [rstatus.success?, rout.to_s.strip, rerr.to_s[0, 120]]
      end
      text = "#{out}\n#{err}"
      msg = text[/\[Compiler Error\][^\n]*|\[Parser Error\][^\n]*|error: [^\n]*/, 0]
      probe_line = text[/^\s*(\d+) \|/, 1] || text[/line (\d+)/, 1]
      # Not every failure announces itself with one of those banners -- a Ruby
      # backtrace out of the compiler, a Zig error, an ENOSPC. Fall back to the
      # last lines that are not warnings, so no failure lands without a reason.
      msg ||= text.lines.grep(/Error|error/).reject { |l| l.include?('[Warning]') }
                  .reject { |l| l =~ /\A\s*(from|\t)/ }.last.to_s.strip
      msg = text.lines.reject { |l| l.include?('[Warning]') || l.strip.empty? }.last(2).join(' ').strip if msg.empty?
      [status.success?, msg.to_s.gsub(/\e\[[0-9;]*m/, '')[0, 200], probe_line]
    end
  end

  def main(argv)
    only_file = nil
    jobs = [Etc.nprocessors - 4, 1].max
    stage = :clear
    limit = nil
    passing = nil
    OptionParser.new do |p|
      p.on('--file REL') { |v| only_file = v }
      p.on('--all') { only_file = nil }
      p.on('--jobs N', Integer) { |v| jobs = v }
      p.on('--stage S') { |v| stage = v.to_sym }
      p.on('--limit N', Integer) { |v| limit = v }
      # Stage 2 only makes sense for what already passed stage 1.
      p.on('--passing FILE') { |v| passing = v }
    end.parse!(argv)

    group = members
    files = only_file ? [only_file] : group
    cache = {}
    group.each { |m| cache[File.join(SRC, m)] = dissect(File.join(SRC, m)) }

    targets = files.flat_map { |f| cache[File.join(SRC, f)][2] }
    if passing
      allow = JSON.parse(File.read(passing)).select { |r| r['ok'] }
                  .map { |r| [r['file'], r['fn']] }.to_set
      targets = targets.select { |t| allow.include?([rel(t.file), t.name]) }
    end
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
          src = probe_source(target, group, cache, pkg_name)
          offset = @probe_offset
          ok, msg, probe_line = compile(src, stage, pkg_flag)
          # The target is restated verbatim, so a probe line maps straight back.
          line = probe_line ? target.start + (probe_line.to_i - offset) : nil
          results[idx] = [rel(target.file), target.name, ok, msg, line]
          mutex.synchronize do
            done += 1
            # Each build leaves Zig cache entries behind; 3405 of them fill the
            # disk and every probe after that fails for the wrong reason.
            if (done % (stage == :clear ? 300 : 15)).zero?
              FileUtils.rm_rf(File.join(ROOT, 'zig', '.clear-cache'))
            end
            if (done % 20).zero?
              good = results.count { |r| r && r[2] }
              warn "  #{done}/#{targets.length}  compiling: #{good} (#{(100.0 * good / done).round(1)}%)"
              File.write(File.join(ROOT, '.fn_probe.json'), JSON.pretty_generate(
                           results.compact.map { |f, n, o, m, l| { file: f, fn: n, ok: o, error: m, line: l } }))
            end
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
    File.write(File.join(ROOT, '.fn_probe.json'), JSON.pretty_generate(
                 results.compact.map { |f, n, o, m, l| { file: f, fn: n, ok: o, error: m, line: l } }
               ))
    warn "\nwrote .fn_probe.json"
    0
  end
end

exit(SelfhostFnProbe.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_fn_probe.rb')
