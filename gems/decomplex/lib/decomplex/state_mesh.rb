# frozen_string_literal: true

require_relative "ast"
require_relative "semantic_alias"
require "json"

module Decomplex
  # StateMesh -- visualize the most important state and how messy it is.
  #
  # Tracks BOTH writers and readers of every state field (attr/ivar),
  # computes messiness metrics, and produces a hierarchical JSON graph
  # organized by dir -> file -> function.
  #
  # Phases:
  #   1. Discover state fields (ATTRASGN + IASGN with >= min_writes)
  #   2. Find all write sites (reusing CoUpdate's walk logic)
  #   3. Find all read sites (new walker: CALL/IVAR matching field names)
  #   4. Find re-derivation sites via SemanticAlias reification misses
  #   5. Compute messiness per field
  #   6. Render hierarchical JSON graph
  class StateMesh
    Write = Struct.new(:attr, :norm, :recv, :file, :defn, :line, :span,
                       keyword_init: true)
    Read  = Struct.new(:attr, :norm, :recv, :file, :defn, :line, :span,
                       keyword_init: true)
    ReDerivation = Struct.new(:field, :file, :defn, :line, :raw,
                              :predicate, :canon, keyword_init: true)

    attr_reader :writes, :reads, :re_derivations

    # scan :: [String] -> StateMesh
    # `custom_fields` overrides field discovery with an explicit list.
    # `min_writes` is the threshold for auto-discovered fields (default 2).
    def self.scan(files, min_writes: 2, custom_fields: nil)
      src_map = {}
      files.each do |f|
        root, lines = Ast.parse(f)
        src_map[f] = { root: root, lines: lines }
      end
      new(src_map, min_writes: min_writes, custom_fields: custom_fields)
    end

    def initialize(src_map, min_writes: 2, custom_fields: nil)
      @src_map = src_map
      @min_writes = min_writes
      @custom_fields = custom_fields
      @writes = []
      @reads = []
      @re_derivations = []
    end

    # ---- Phase 1+2: discover fields and walk write sites ---------------

    def discover_fields!
      @src_map.each do |file, data|
        walk_writes(data[:root], data[:lines], [], file)
      end
    end

    def walk_writes(node, lines, defstack, file)
      return unless Ast.node?(node)

      case node.type
      when :DEFN then defstack = defstack + [node.children[0].to_s]
      when :DEFS then defstack = defstack + [node.children[1].to_s]
      when :ATTRASGN
        recv, msg, = node.children
        if msg == :[]=
          node.children.each { |c| walk_writes(c, lines, defstack, file) }
          return
        end
        attr = msg.to_s.sub(/=$/, "")
        norm = normalize(attr)
        span = [node.first_lineno, node.first_column,
                node.last_lineno, node.last_column]
        @writes << Write.new(attr: attr, norm: norm,
                             recv: recv_slice(node.children[0], lines),
                             file: file,
                             defn: defstack.last || "(top-level)",
                             line: node.first_lineno, span: span)
      when :IASGN
        attr = node.children[0].to_s  # "@storage"
        norm = normalize(attr)
        span = [node.first_lineno, node.first_column,
                node.last_lineno, node.last_column]
        @writes << Write.new(attr: attr, norm: norm, recv: "self",
                             file: file,
                             defn: defstack.last || "(top-level)",
                             line: node.first_lineno, span: span)
      end

      node.children.each { |c| walk_writes(c, lines, defstack, file) }
    end

    # ---- Phase 3: walk read sites -------------------------------------

    def find_reads!
      # Build the set of normalized field names we care about.
      field_norms = known_field_norms

      @src_map.each do |file, data|
        walk_reads(data[:root], data[:lines], [], file, field_norms)
      end
    end

    def walk_reads(node, lines, defstack, file, field_norms)
      return unless Ast.node?(node)

      case node.type
      when :DEFN then defstack = defstack + [node.children[0].to_s]
      when :DEFS then defstack = defstack + [node.children[1].to_s]
      when :CALL, :OPCALL
        # CALL(recv, :method, args) - attribute reads have no args
        recv = node.children[0]
        mid  = node.children[1]
        args = node.children[2]

        # Skip if called with arguments (it's a method call, not attr read)
        if args.nil? || (Ast.node?(args) && args.type == :LIST && args.children.compact.empty?)
          name = mid.to_s
          if field_norms.include?(name)
            span = [node.first_lineno, node.first_column,
                    node.last_lineno, node.last_column]
            @reads << Read.new(attr: name, norm: name,
                               recv: recv_slice(recv, lines),
                               file: file,
                               defn: defstack.last || "(top-level)",
                               line: node.first_lineno, span: span)
          end
        end
      when :IVAR
        name = node.children[0].to_s  # e.g. "@storage"
        norm = normalize(name)
        if field_norms.include?(norm)
          span = [node.first_lineno, node.first_column,
                  node.last_lineno, node.last_column]
          @reads << Read.new(attr: name, norm: norm, recv: "self",
                             file: file,
                             defn: defstack.last || "(top-level)",
                             line: node.first_lineno, span: span)
        end
      end

      node.children.each { |c| walk_reads(c, lines, defstack, file, field_norms) }
    end

    # ---- Phase 4: re-derivation sites ---------------------------------

    def find_re_derivations!(reification_misses = nil)
      field_norms = known_field_norms
      return if field_norms.empty?

      # Accept pre-computed misses (for testing) or compute them.
      if reification_misses.nil?
        files = @src_map.keys
        sa = SemanticAlias.scan(files)
        reification_misses = sa.reification_misses
      end

      # A reification miss is a re-derivation of a state field if the
      # canonical form or raw text references the field name.
      reification_misses.each do |m|
        raw  = m[:raw].to_s
        can  = m[:canon].to_s
        pred = m[:predicate]
        loc  = m[:at]  # "file:defn:line"

        parts = loc.to_s.split(":")
        line_s = parts.pop
        meth   = parts.pop
        file   = parts.join(":")
        line   = line_s.to_i

        # Match: does this reification miss involve a known state field?
        matched = field_norms.find { |fn| raw.include?(fn) || can.include?(fn) }
        next unless matched

        @re_derivations << ReDerivation.new(
          field: matched, file: file, defn: meth, line: line,
          raw: raw, predicate: pred, canon: can
        )
      end
    end

    # ---- Phase 5: metrics per field -----------------------------------

    FieldMetrics = Struct.new(
      :name, :writes, :reads, :re_derivations,
      :scatter, :write_scatter, :read_scatter,
      :receiver_types, :messiness, :pressure,
      :percentiles, :rank,
      keyword_init: true
    )

    def metrics
      field_norms = known_field_norms
      return [] if field_norms.empty?

      # Group sites by normalized field name.
      writes_by_field = @writes.group_by(&:norm)
      reads_by_field  = @reads.group_by(&:norm)
      reder_by_field  = @re_derivations.group_by(&:field)

      metrics = field_norms.map do |fn|
        ws = writes_by_field[fn] || []
        rs = reads_by_field[fn] || []
        ds = reder_by_field[fn] || []

        n_writes = ws.size
        n_reads  = rs.size
        n_reder  = ds.size

        # Scatter: distinct (file, defn) across write+read+re-derive.
        all_sites = ws.map { |s| [s.file, s.defn] } +
                    rs.map { |s| [s.file, s.defn] } +
                    ds.map { |s| [s.file, s.defn] }
        scatter = all_sites.uniq.size

        write_scatter = ws.map { |s| [s.file, s.defn] }.uniq.size
        read_scatter  = rs.map { |s| [s.file, s.defn] }.uniq.size

        # Distinct receiver patterns.
        recv_types = (ws.map(&:recv) + rs.map(&:recv)).uniq.size

        # Fix churn: default 1 (no boobytrap data available yet).
        fix_churn = 1.0

        # Messiness = (writes + reads + re_derivations) * scatter * fix_churn
        messiness = (n_writes + n_reads + n_reder) * scatter * fix_churn

        # Pressure: downstream consumers that themselves produce state.
        # For v0, this is the read scatter (approximation).
        pressure = read_scatter

        FieldMetrics.new(
          name: fn, writes: n_writes, reads: n_reads,
          re_derivations: n_reder, scatter: scatter,
          write_scatter: write_scatter, read_scatter: read_scatter,
          receiver_types: recv_types, messiness: messiness,
          pressure: pressure, percentiles: {}, rank: 0
        )
      end

      # Compute percentiles and rank.
      sorted = metrics.sort_by { |m| -m.messiness }
      sorted.each_with_index { |m, i| m.rank = i + 1 }

      total = metrics.size
      if total > 1
        [:writes, :reads, :re_derivations, :scatter, :messiness, :pressure].each do |attr|
          vals = metrics.map { |m| m.send(attr) }.sort
          metrics.each do |m|
            v = m.send(attr)
            pctl = vals.count { |x| x <= v } * 100 / total
            m.percentiles[attr] = pctl
          end
        end
      end

      metrics
    end

    # ---- Phase 6: hierarchical JSON graph -----------------------------

    def to_json_graph
      field_norms = known_field_norms
      fm = metrics
      fm_index = fm.each_with_object({}) { |m, h| h[m.name] = m }

      # Build per-field site lists.
      writes_by_field = @writes.group_by(&:norm)
      reads_by_field  = @reads.group_by(&:norm)
      reder_by_field  = @re_derivations.group_by(&:field)

      fields_obj = {}
      field_norms.sort.each do |fn|
        ws = (writes_by_field[fn] || []).map { |w|
          { "file" => w.file, "defn" => w.defn, "line" => w.line,
            "recv" => w.recv, "span" => w.span }
        }
        rs = (reads_by_field[fn] || []).map { |r|
          { "file" => r.file, "defn" => r.defn, "line" => r.line,
            "recv" => r.recv, "span" => r.span }
        }
        ds = (reder_by_field[fn] || []).map { |d|
          { "file" => d.file, "defn" => d.defn, "line" => d.line,
            "raw" => d.raw, "predicate" => d.predicate, "canon" => d.canon }
        }

        m = fm_index[fn]
        fields_obj[fn] = {
          "messiness" => m.messiness,
          "rank" => m.rank,
          "metrics" => {
            "writes" => m.writes, "reads" => m.reads,
            "re_derivations" => m.re_derivations,
            "scatter" => m.scatter, "write_scatter" => m.write_scatter,
            "read_scatter" => m.read_scatter,
            "receiver_types" => m.receiver_types,
            "fix_churn" => 1.0, "pressure" => m.pressure,
            "percentiles" => m.percentiles
          },
          "writers" => ws,
          "readers" => rs,
          "re_derivations" => ds
        }
      end

      # Build hierarchy: directory -> file -> function.
      all_sites = {}
      @writes.each do |w|
        all_sites[[w.file, w.defn]] ||= { writes: [], reads: [] }
        all_sites[[w.file, w.defn]][:writes] << w.norm
      end
      @reads.each do |r|
        all_sites[[r.file, r.defn]] ||= { writes: [], reads: [] }
        all_sites[[r.file, r.defn]][:reads] << r.norm
      end

      # Group by dir -> file -> defn.
      dirs = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = {} } }
      all_sites.each do |(file, defn), info|
        dir = File.dirname(file)
        dir = "." if dir == "."
        base = File.basename(file)
        dirs[dir][base][defn] = {
          "writers" => info[:writes].uniq.size,
          "readers" => info[:reads].uniq.size,
          "fields" => {
            "written" => info[:writes].uniq.sort,
            "read" => info[:reads].uniq.sort
          }
        }
      end

      hierarchy = dirs.sort.map do |dir, files_hash|
        dir_obj = { "name" => dir, "writers" => 0, "readers" => 0, "files" => [] }
        files_hash.sort.each do |fname, defns_hash|
          file_obj = { "name" => fname, "writers" => 0, "readers" => 0, "defns" => [] }
          defns_hash.sort.each do |dname, d_info|
            file_obj["writers"] += d_info["writers"]
            file_obj["readers"] += d_info["readers"]
            file_obj["defns"] << {
              "name" => dname,
              "writers" => d_info["writers"],
              "readers" => d_info["readers"],
              "fields" => d_info["fields"]
            }
          end
          dir_obj["writers"] += file_obj["writers"]
          dir_obj["readers"] += file_obj["readers"]
          dir_obj["files"] << file_obj
        end
        dir_obj
      end

      {
        "state_mesh" => {
          "total_fields" => field_norms.size,
          "total_writes" => @writes.size,
          "total_reads" => @reads.size,
          "total_re_derivations" => @re_derivations.size,
          "min_writes" => @min_writes,
          "custom_fields" => @custom_fields
        },
        "fields" => fields_obj,
        "hierarchy" => hierarchy
      }
    end

    def findings(limit_sites: 12)
      writes_by_field = @writes.group_by(&:norm)
      reads_by_field  = @reads.group_by(&:norm)
      reder_by_field  = @re_derivations.group_by(&:field)

      metrics.map do |m|
        ws = writes_by_field[m.name] || []
        rs = reads_by_field[m.name] || []
        ds = reder_by_field[m.name] || []
        sites = (ws + rs).map { |s| "#{s.file}:#{s.defn}:#{s.line}" } +
                ds.map { |s| "#{s.file}:#{s.defn}:#{s.line}" }
        spans = (ws + rs).to_h do |s|
          ["#{s.file}:#{s.defn}:#{s.line}", s.span]
        end
        {
          at: sites.first,
          field: m.name,
          writes: m.writes,
          reads: m.reads,
          re_derivations: m.re_derivations,
          scatter: m.scatter,
          write_scatter: m.write_scatter,
          read_scatter: m.read_scatter,
          receiver_types: m.receiver_types,
          messiness: m.messiness,
          pressure: m.pressure,
          top_writers: ws.first(4).map { |s| "#{s.file}:#{s.defn}:#{s.line}" },
          top_readers: rs.first(4).map { |s| "#{s.file}:#{s.defn}:#{s.line}" },
          sites: sites.first(limit_sites),
          spans: spans
        }
      end
    end

    # ---- Run all phases ------------------------------------------------

    def run
      discover_fields!
      return if known_field_norms.empty?

      find_reads!
      find_re_derivations!
    end

    # ---- Helpers -------------------------------------------------------

    # Normalize: strip leading @, normalize whitespace.
    def normalize(attr)
      attr.to_s.sub(/\A@/, "").strip
    end

    # Known field names (normalized) from discovered writes + custom list.
    def known_field_norms
      @known_field_norms ||= begin
        discovered = @writes.group_by(&:norm).select { |_, ws| ws.size >= @min_writes }.keys
        custom = @custom_fields || []
        (discovered + custom).uniq.sort
      end
    end

    def recv_slice(node, lines)
      return "?" unless Ast.node?(node)

      sl = node.first_lineno
      el = node.last_lineno
      t = sl == el ? lines[sl - 1][node.first_column...node.last_column] : lines[sl - 1][node.first_column..]
      t.to_s.strip.gsub(/\s+/, " ")
    end
  end
end
