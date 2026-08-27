#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes that land on a discarded copy.
#
# Ruby's `program_state.source_dir = x` mutates the object the reader returns,
# because Ruby returns the object itself. CLEAR's generated reader returns
# `COPY self.state.program`, so rtoc's two-step form --
#
#     MUTABLE rtoc_writer_receiver_9: ProgramState = mIRLowering__program_state(v);
#     rtoc_writer_receiver_9.source_dir = prev;
#
# -- writes into a temporary that is immediately dropped. It compiles, and the
# mutation is silently lost. Inside a DEFER it is worse: only the first
# statement is deferred, so the restore also runs at the wrong time.
#
# The fix is to write through the field path the reader reads.
#
#   ruby tools/selfhost_writer_receivers.rb [--fix]
require 'optparse'

module SelfhostWriterReceivers
  extend self

  # `FN name(self: T) ... RETURN COPY <alias>.<path>;` -- a pure field reader.
  READER = /^(?:PUB |PRIVATE )?FN (\w+)\((?:MUTABLE )?(\w+): [\w@?]+\)/.freeze
  RETURN_COPY = /RETURN COPY (\w+)\.([\w.]+);/.freeze
  # A reader may go through another reader: `COPY lowering_state(v).program`.
  RETURN_VIA = /RETURN COPY (\w+)\((\w+)\)\.([\w.]+);/.freeze

  def field_readers(files)
    direct = {}
    via = {}
    files.each_value do |lines|
      lines.each_with_index do |line, index|
        next unless (decl = READER.match(line))

        window = lines[index, 8].to_a.join
        if (chain = RETURN_VIA.match(window))
          via[decl[1]] = [chain[1], chain[3]]
          next
        end
        next unless (body = RETURN_COPY.match(window))
        # The alias the WITH block binds, or the parameter itself.
        next unless window.include?("AS #{body[1]}") || body[1] == decl[2]

        direct[decl[1]] = body[2]
      end
    end

    # Resolve each chained reader down to a plain field path.
    loop do
      progressed = false
      via.each do |name, (inner, field)|
        next unless direct[inner]
        next if direct[name]

        direct[name] = "#{direct[inner]}.#{field}"
        progressed = true
      end
      break unless progressed
    end
    direct
  end

  def main(argv)
    root = File.expand_path('compiler/src', __dir__ + '/..')
    fix = false
    OptionParser.new do |parser|
      parser.on('--root DIR') { |v| root = File.expand_path(v) }
      parser.on('--fix', 'Write through the field path instead of a copy') { fix = true }
    end.parse!(argv)

    files = Dir.glob(File.join(root, '**', '*.clear')).sort.to_h { |p| [p, File.readlines(p)] }
    readers = field_readers(files)

    found = []
    files.each do |path, lines|
      lines.each_with_index do |line, index|
        # A previous pass on this file may have cleared the paired write line.
        next if line.nil?

        match = line.match(/^(\s*)(DEFER )?MUTABLE (rtoc_writer_receiver_\d+): [\w@?\[\]]+ = (\w+)\((\w+)\);\s*\z/)
        next unless match

        indent, deferred, temp, reader, receiver = match[1], match[2], match[3], match[4], match[5]
        path_expr = readers[reader]
        next unless path_expr

        follow = lines[index + 1].to_s
        next if follow.empty?
        write = follow.match(/^\s*#{Regexp.escape(temp)}\.([\w.]+) ?= ?(.*);\s*\z/)
        next unless write

        found << ["#{path.sub("#{root}/", '')}:#{index + 1}", reader, deferred ? 'DEFER' : '']
        next unless fix

        lines[index] = "#{indent}#{deferred}#{receiver}.#{path_expr}.#{write[1]} = #{write[2]};\n"
        lines[index + 1] = nil
      end
      next unless fix

      File.write(path, lines.compact.join)
    end

    found.first(12).each { |site, reader, kind| puts "  #{site}  #{reader} #{kind}" }
    puts "selfhost_writer_receivers: #{found.length} write(s) landing on a copy"
    found.empty? || fix ? 0 : 1
  end
end

exit(SelfhostWriterReceivers.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_writer_receivers.rb')
