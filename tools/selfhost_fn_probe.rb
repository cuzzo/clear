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

  # One probe: the group's types, everything stubbed, the target verbatim.
  def probe_source(target, group, cache)
    own_requires, own_types, own_fns, own_loose = cache[target.file]
    kept = []
    dropped = []
    own_requires.each do |line|
      r = rewrite_require(line, rel(target.file))
      if r.is_a?(Array)
        group.include?(r[0]) && r[0] != rel(target.file) ? dropped << r[0] : kept << r[1]
      else
        kept << r
      end
    end

    sibling = dropped.uniq.flat_map do |d|
      _rq, types, fns, = cache[File.join(SRC, d)]
      types + fns.filter_map { |f| stub(f) }
    end

    here = own_fns.map { |f| f.name == target.name ? f.text : stub(f) }.compact

    [kept.join,
     "\n# --- stand-ins for imported group members ---\n", sibling.join("\n"),
     "\n# --- #{rel(target.file)} : #{target.name} ---\n",
     own_types.join, own_loose.join, here.join,
     "\nFN main() RETURNS !Void ->\n  RETURN;\nEND\n"].join
  end

  def rel(path) = path.sub("#{SRC}/", '')

  def compile(source_text, stage)
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
             *ParserCompat.package_flags(SRC)]
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
          ok, msg = compile(probe_source(target, group, cache), stage)
          results[idx] = [rel(target.file), target.name, ok, msg]
          mutex.synchronize do
            done += 1
            warn "  #{done}/#{targets.length}" if (done % 25).zero?
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
