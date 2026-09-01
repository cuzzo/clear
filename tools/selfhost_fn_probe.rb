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

  # The stub package: every type in the group and a stub for every function,
  # written ONCE. `transpile_cached` is content-addressed, so all 3405 probes
  # share one compile of it instead of each paying for the whole group.
  def stub_package(group, cache)
    @stub_package ||= begin
      types = []
      stubs = []
      externals = Set.new
      seen = Set.new
      group.each do |rel|
        rq, ts, fns, = cache[File.join(SRC, rel)]
        # The group's own imports are stubbed here; everything BELOW it is real
        # and has to be required, or the target cannot see it.
        rq.each do |line|
          r = rewrite_require(line, rel)
          next unless r.is_a?(Array)
          next if group.include?(r[0])

          externals << %(REQUIRE "pkg:rtoc_#{r[0].unpack1('H*')}"\n)
        end
        ts.each do |d|
          name = d[/\A(?:PUB )?(?:STRUCT|UNION|ENUM) (\w+)/, 1]
          next if name && !seen.add?("T:#{name}")

          types << (d.start_with?('PUB ') ? d : "PUB #{d}")
        end
        fns.each do |f|
          next unless seen.add?("F:#{f.name}")
          s = stub(f) or next

          stubs << (s.start_with?('PUB ') ? s : "PUB #{s.sub(/\APRIVATE /, '')}")
        end
      end
      externals.to_a.join + "\n" + types.join + "\n" + stubs.join("\n")
    end
  end

  # A probe is then tiny: require the stubs, restate the target under a name
  # that cannot collide with its own stub, and call it.
  def probe_source(target, _group, _cache, pkg_name)
    body = target.text.sub(/\A(PUB |PRIVATE )?FN #{Regexp.escape(target.name)}/,
                           "FN probe__#{target.name.delete('?').delete('!')}")
    [%(REQUIRE "pkg:#{pkg_name}"\n),
     "\n# --- #{rel(target.file)} : #{target.name} ---\n", body,
     "\nFN main() RETURNS !Void ->\n  RETURN;\nEND\n"].join
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
      if stage == :clear
        env['CLEAR_TRANSPILE_ONLY'] = '1'
        env['CLEAR_DISABLE_BUILD_ZIG'] = '1'
      end
      cmd = [File.join(ROOT, 'clear'), 'build', source, '-o', File.join(dir, 'probe'),
             '--no-stack-check', '--main-tier', 'service',
             *ParserCompat.package_flags(SRC), *Array(extra_pkg)]
      out, err, status = Open3.capture3(env, *cmd, chdir: ROOT)
      msg = "#{out}\n#{err}"[/\[Compiler Error\][^\n]*|\[Parser Error\][^\n]*|error: [^\n]*/, 0]
      [status.success?, msg.to_s[0, 160]]
    end
  end

  def main(argv)
    only_file = nil
    jobs = [Etc.nprocessors - 4, 1].max
    stage = :clear
    limit = nil
    OptionParser.new do |p|
      p.on('--file REL') { |v| only_file = v }
      p.on('--all') { only_file = nil }
      p.on('--jobs N', Integer) { |v| jobs = v }
      p.on('--stage S') { |v| stage = v.to_sym }
      p.on('--limit N', Integer) { |v| limit = v }
    end.parse!(argv)

    group = members
    files = only_file ? [only_file] : group
    cache = {}
    group.each { |m| cache[File.join(SRC, m)] = dissect(File.join(SRC, m)) }

    targets = files.flat_map { |f| cache[File.join(SRC, f)][2] }
    targets = targets.first(limit) if limit
    warn "#{targets.length} functions across #{files.length} file(s); #{jobs} jobs; stage=#{stage}"

    stub_dir = File.join(ROOT, 'tmp', 'fnprobe')
    FileUtils.mkdir_p(stub_dir)
    stub_path = File.join(stub_dir, 'stubs.clear')
    File.write(stub_path, stub_package(group, cache))
    pkg_name = 'fnprobe_stubs'
    pkg_flag = ["--pkg", "#{pkg_name}=#{stub_path}"]
    warn "stub package: #{File.read(stub_path).lines.length} lines"

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
          ok, msg = compile(probe_source(target, group, cache, pkg_name), stage, pkg_flag)
          results[idx] = [rel(target.file), target.name, ok, msg]
          mutex.synchronize do
            done += 1
            if (done % 20).zero?
              good = results.count { |r| r && r[2] }
              warn "  #{done}/#{targets.length}  compiling: #{good} (#{(100.0 * good / done).round(1)}%)"
              File.write(File.join(ROOT, '.fn_probe.json'), JSON.pretty_generate(
                           results.compact.map { |f, n, o, m| { file: f, fn: n, ok: o, error: m } }))
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
                 results.compact.map { |f, n, o, m| { file: f, fn: n, ok: o, error: m } }
               ))
    warn "\nwrote .fn_probe.json"
    0
  end
end

exit(SelfhostFnProbe.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_fn_probe.rb')
