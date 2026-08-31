#!/usr/bin/env ruby
# frozen_string_literal: true

# Compile one file of a cyclic package on its own.
#
# The annotator's 54 files form a single package: the compiler builds them
# together and reports ONE error, so the whole group moves at the pace of a
# serialized queue and there is no way to tell how far along it is.
#
# Only a handful of each file's imports point back into the group. Dropping
# those and supplying what they provided -- the siblings' type declarations
# verbatim, their functions as signature-only stubs -- lets a file compile by
# itself. That turns one queue into 54 independent ones, and turns "how close
# are we" into a number.
#
#   ruby tools/selfhost_scc_probe.rb --list
#   ruby tools/selfhost_scc_probe.rb annotator/domains/errors.clear
#   ruby tools/selfhost_scc_probe.rb --all --jobs 6
require 'open3'
require 'optparse'
require 'set'
require 'tmpdir'
require 'fileutils'

saved = $PROGRAM_NAME
$PROGRAM_NAME = 'selfhost_scc_probe_support'
require_relative 'parser_compat'
$PROGRAM_NAME = saved

module SelfhostSccProbe
  extend self

  ROOT = File.expand_path('..', __dir__)
  SRC = File.join(ROOT, 'compiler', 'src')

  def group(name = nil)
    groups = ParserCompat.package_groups(SRC)
    return groups[name] if name

    groups.max_by { |_n, m| m.length }.last
  end

  # A file's own declarations, and the spans of its functions.
  def dissect(text)
    lines = text.lines
    requires = []
    types = []
    others = []
    i = 0
    while i < lines.length
      line = lines[i]
      if line.start_with?('REQUIRE')
        requires << line
        i += 1
      elsif line =~ /^(?:PUB |PRIVATE )?(?:STRUCT|UNION|ENUM) /
        start = i
        i += 1 until i >= lines.length || lines[i].strip == '}' || line.rstrip.end_with?('}')
        i += 1 unless line.rstrip.end_with?('}')
        types << lines[start...i].join
      elsif line =~ /^(?:PUB |PRIVATE )?FN /
        start = i
        i += 1 while i < lines.length && lines[i].rstrip != 'END'
        i += 1
        others << lines[start...i].join
      else
        others << line
        i += 1
      end
    end
    [requires, types, others]
  end

  # Signature-only stand-ins for what a dropped sibling provided.
  def stubs_for(relative)
    text = File.read(File.join(SRC, relative))
    _reqs, types, _rest = dissect(text)
    out = types.dup
    text.scan(/^PUB FN ([\w?!]+)(<[^>]*>)?\(([^\n]*?)\)\s*(RETURNS\s+([\w@?!\[\]{}]+))?/) do |name, generics, params, _r, ret|
      ret ||= 'Void'
      body = ret.delete_prefix('!') == 'Void' ? '  RETURN;' : "  panic(\"stub: #{name}\");"
      out << "PUB FN #{name}#{generics}(#{params})#{" RETURNS #{ret}" if ret} ->\n#{body}\nEND\n"
    end
    out
  end

  def probe_source(relative, members)
    text = File.read(File.join(SRC, relative))
    requires, types, rest = dissect(text)
    dropped = []
    kept = requires.filter_map do |line|
      # A require is either the hex package name or a path relative to the
      # requiring file; the probe lives elsewhere, so everything it keeps is
      # restated in the location-independent form.
      target =
        if (hex = line[/pkg:rtoc_([0-9a-f]+)/, 1])
          [hex].pack('H*')
        elsif (path = line[/REQUIRE "([^"]+)"/, 1]) && !path.start_with?('pkg:')
          File.expand_path(path, "/#{File.dirname(relative)}").delete_prefix('/')
        end
      next line unless target

      if members.include?(target) && target != relative
        dropped << target
        next nil
      end
      alias_part = line[/\sAS\s+\w+/]
      %(REQUIRE "pkg:rtoc_#{target.unpack1('H*')}"#{alias_part}\n)
    end
    stubs = dropped.uniq.flat_map { |d| stubs_for(d) }
    [kept.join, "\n# --- stand-ins for the group members this file imports ---\n",
     stubs.join("\n"), "\n# --- #{relative} ---\n", types.join, rest.join,
     "\nFN main() RETURNS !Void ->\n  RETURN;\nEND\n"].join
  end

  # Three stages, because "compiles" means three different things: the CLEAR
  # front end accepting it, Zig accepting the code it emits, and a binary
  # actually linking.
  def check(relative, members, stage = :clear)
    Dir.mktmpdir('scc-probe') do |dir|
      source = File.join(dir, 'probe.clear')
      File.write(source, probe_source(relative, members))
      env = { 'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8', 'CLEAR_EXTRA_NATIVE_DIRS' => SRC }
      env['CLEAR_TRANSPILE_ONLY'] = '1' if stage == :clear
      env['CLEAR_DISABLE_BUILD_ZIG'] = '1' if stage == :clear
      cmd = [File.join(ROOT, 'clear'), 'build', source, '-o', File.join(dir, 'probe'),
             '--no-stack-check', '--main-tier', 'service', *ParserCompat.package_flags(SRC)]
      out, err, status = Open3.capture3(env, *cmd, chdir: ROOT)
      blob = "#{out}\n#{err}".gsub(/\e\[[0-9;]*m/, '')
      first = blob.lines.grep(/Compiler Error|Parser Error/).first.to_s.strip
      [status.success?, first[0, 150]]
    end
  end

  def main(argv)
    jobs = 4
    all = false
    list = false
    stage = :clear
    OptionParser.new do |p|
      p.on('--all') { all = true }
      p.on('--list') { list = true }
      p.on('--jobs N', Integer) { |v| jobs = v }
      p.on('--stage NAME', 'clear (default) or binary') { |v| stage = v.to_sym }
    end.parse!(argv)

    members = group
    return (puts members.sort) || 0 if list

    targets = all ? members.sort : argv
    return (warn 'usage: selfhost_scc_probe.rb [--all] [file...]') || 1 if targets.empty?

    results = {}
    warn "probing #{targets.length} file(s) with #{jobs} job(s)"
    targets.each_slice([targets.length.fdiv(jobs).ceil, 1].max).to_a.then do |batches|
      threads = batches.map do |batch|
        Thread.new do
          batch.each do |rel|
            results[rel] = check(rel, members)
            # A sweep this long has to say what it has found so far.
            warn format('  %-52s %s', rel, results[rel].first ? 'OK' : results[rel].last)
          end
        end
      end
      threads.each(&:join)
    end

    passed = results.count { |_r, (ok, _e)| ok }
    puts "#{passed}/#{results.length} file(s) of the group compile on their own"
    results.sort.each do |rel, (ok, err)|
      puts format('  %-52s %s', rel, ok ? 'OK' : err)
    end
    0
  end
end

exit(SelfhostSccProbe.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_scc_probe.rb')
