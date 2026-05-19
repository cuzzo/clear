# frozen_string_literal: true

module Decomplex
  # Co-update / inconsistent-update mining (cf. Lu et al., DynaMine).
  #
  # Plague targeted: "redundant state that drifts" and "the same path
  # in many places, one place misses the step." If attribute `.storage`
  # and attribute `.provenance` are assigned together in N methods, a
  # method that assigns one without the other is a probable desync --
  # exactly the documented invariant-#16 pairing whose violation is a
  # latent UAF.
  #
  # Unit of mutation = the ATTRIBUTE / ivar NAME (not the full receiver
  # chain): `node.storage =` and `decl.storage =` are the same logical
  # state edit, so they must cluster regardless of receiver. lvar
  # assignment is deliberately NOT mined (loop temps etc. are noise).
  #
  # Output is a ranked CANDIDATE list, not a verdict (Engler's
  # discipline): FP is acceptable, the receiver is printed so triage is
  # a one-line read.
  class CoUpdate
    Write = Struct.new(:attr, :recv, :file, :defn, :line, :span,
                       keyword_init: true)

    def self.scan(files)
      writes = []
      files.each do |f|
        src = File.read(f)
        root = RubyVM::AbstractSyntaxTree.parse(src, keep_script_lines: true)
        new(f, src.lines).tap { |c| c.walk(root, []) }.writes.each { |w| writes << w }
      end
      Report.new(writes)
    end

    attr_reader :writes

    def initialize(file, lines)
      @file = file
      @lines = lines
      @writes = []
    end

    def walk(node, defstack)
      return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      case node.type
      when :DEFN then defstack += [node.children[0].to_s]
      when :DEFS then defstack += [node.children[1].to_s]
      when :ATTRASGN
        recv, msg, = node.children
        # `obj[k] = v` is indexed-container mutation, not a named-attribute
        # state edit -- same noise class as the lvar exclusion above; left
        # in, its `[]` "attribute" manufactures spurious pairs with every
        # real attr.
        if msg == :[]=
          node.children.each { |c| walk(c, defstack) }
          return
        end

        attr = msg.to_s.sub(/=$/, "")
        @writes << Write.new(attr: attr, recv: slice(recv), file: @file,
                             defn: defstack.last || "(top-level)",
                             line: node.first_lineno,
                             span: [node.first_lineno, node.first_column,
                                    node.last_lineno, node.last_column])
      when :IASGN
        @writes << Write.new(attr: node.children[0].to_s, recv: "self",
                             file: @file, defn: defstack.last || "(top-level)",
                             line: node.first_lineno,
                             span: [node.first_lineno, node.first_column,
                                    node.last_lineno, node.last_column])
      end

      node.children.each { |c| walk(c, defstack) }
    end

    private

    def slice(node)
      return "?" unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      sl = node.first_lineno
      el = node.last_lineno
      t = sl == el ? @lines[sl - 1][node.first_column...node.last_column] : @lines[sl - 1][node.first_column..]
      t.to_s.strip.gsub(/\s+/, " ")
    end

    # Frequent co-written attribute pairs + the methods that break them.
    class Report
      def initialize(writes)
        @writes = writes
        @by_unit = writes.group_by { |w| [w.file, w.defn] }
      end

      # [{ pair:, support:, sites:[...] }, ...]
      def co_written_pairs(min_support: 3)
        counts = Hash.new { |h, k| h[k] = [] }
        @by_unit.each do |unit, ws|
          attrs = ws.map(&:attr).uniq.sort
          attrs.combination(2).each { |pair| counts[pair] << unit }
        end
        counts.filter_map do |pair, units|
          next if units.size < min_support

          { pair: pair, support: units.size,
            sites: units.map { |f, d| "#{f}:#{d}" } }
        end.sort_by { |h| -h[:support] }
      end

      # A method writing exactly one of a high-support pair. The other
      # attribute's absence next to a same-receiver write is the desync.
      # [{ pair:, support:, has:, missing:, at:, recv: }, ...]
      def neglected_updates(min_support: 3)
        pairs = co_written_pairs(min_support: min_support)
        out = []
        @by_unit.each do |(file, defn), ws|
          attrs = ws.map(&:attr).uniq
          pairs.each do |h|
            a, b = h[:pair]
            has, miss = if attrs.include?(a) && !attrs.include?(b)
                          [a, b]
                        elsif attrs.include?(b) && !attrs.include?(a)
                          [b, a]
                        end
            next unless has

            w = ws.find { |x| x.attr == has }
            out << { pair: h[:pair], support: h[:support], has: has,
                     missing: miss, at: "#{file}:#{defn}:#{w.line}",
                     spans: { "#{file}:#{defn}:#{w.line}" => w.span },
                     recv: w.recv }
          end
        end
        out.sort_by { |h| -h[:support] }
      end
    end
  end
end
