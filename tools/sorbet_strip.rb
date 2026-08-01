#!/usr/bin/env ruby
# frozen_string_literal: true

# Produce a Sorbet-free mirror of a Ruby tree, plus RBS sidecars carrying the
# type information the sigs expressed.
#
# sorbet-runtime is built on define_method/send/bind_call/class_eval, which an
# AOT compiler such as Spinel cannot compile, and its T::Props setters cost
# ~23% of our build time by re-validating whole collections on every write.
# The types themselves are valuable, so they are exported to RBS rather than
# discarded: `spinel --rbs DIR` seeds inference from them.
#
# The source tree is never modified. Run tools/sorbet_strip_test.rb to check
# the mirror against the same spec suite.

begin
  require "bundler/setup"
rescue LoadError
  nil
end

require "prism"
require "fileutils"
require "optparse"

module SorbetStrip
  module_function

  SENTINEL = "__sorbet_strip_unset"


  # `sig` and friends are declarations; deleting the whole statement is right.
  DECLARATION_CALLS = %w[sig abstract! interface! sealed! final! requires_ancestor mixes_in_class_methods].freeze
  # `T.x(value, ...)` forms whose runtime meaning is "return value unchanged".
  UNWRAP_FIRST_ARG = %w[let must cast unsafe must_because assert_type! nilable_of].freeze
  EXTEND_MODULES = %w[T::Sig T::Helpers T::Generic].freeze

  def main(argv)
    options = { source: "compiler/ruby", out: "compiler/.ruby-rbs", quiet: false }
    OptionParser.new do |o|
      o.banner = "Usage: ruby tools/sorbet_strip.rb [--source DIR] [--out DIR]"
      o.on("--source DIR", "Ruby tree to mirror (default compiler/ruby)") { |v| options[:source] = v }
      o.on("--out DIR", "Destination (default compiler/.ruby-rbs)") { |v| options[:out] = v }
      o.on("--quiet", "Only print the summary") { options[:quiet] = true }
    end.parse!(argv)

    source_root = File.expand_path(options[:source])
    out_root = File.expand_path(options[:out])

    # tools/sorbet_strip_test.rb swaps the mirror into place while it runs.
    # Stripping then would read already-stripped source and silently produce a
    # mirror with no types to export.
    stash = File.expand_path("compiler/.ruby-original", Dir.pwd)
    if Dir.exist?(stash)
      abort("refusing to run: compiler/.ruby-original exists, so the stripped mirror is currently swapped " \
            "into compiler/ruby (a sorbet_strip_test.rb run is in flight, or one died mid-swap)")
    end
    FileUtils.rm_rf(out_root)

    files = Dir[File.join(source_root, "**", "*.rb")].sort
    stats = { files: 0, sigs: 0, structs: 0, enums: 0, unwraps: 0, deletions: 0 }
    files.each do |path|
      relative = path.delete_prefix("#{source_root}/")
      result = strip_file(File.read(path), path)
      stats[:files] += 1
      %i[sigs structs enums unwraps deletions].each { |k| stats[k] += result[:stats][k] }

      write(File.join(out_root, relative), result[:ruby])
      next if result[:rbs].strip.empty?

      write(File.join(out_root, "sig", relative.sub(/\.rb\z/, ".rbs")), result[:rbs])
    end

    puts "stripped #{stats[:files]} files -> #{options[:out]}"
    puts "  sigs removed:      #{stats[:sigs]}"
    puts "  T::Struct rewrites: #{stats[:structs]}"
    puts "  T::Enum rewrites:   #{stats[:enums]}"
    puts "  T.* unwrapped:      #{stats[:unwraps]}"
    puts "  declarations removed: #{stats[:deletions]}"
    0
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # Returns { ruby:, rbs:, stats: }.
  def strip_file(source, path)
    result = Prism.parse(source)
    raise "parse failed: #{path}: #{result.errors.map(&:message).join(', ')}" if result.failure?

    edits = []
    rbs = RBSBuilder.new
    stats = Hash.new(0)
    Walker.new(source, edits, rbs, stats).visit(result.value)

    ruby = apply(source, edits)
    # Idempotent, so every file can declare it and load order does not matter.
    ruby = "module SorbetStripStruct; end\n" + ruby
    { ruby: ruby, rbs: rbs.render, stats: stats }
  end

  # Edits are [start, end, replacement]. An edit nested inside another (a T.let
  # within a deleted sig, say) is already accounted for by the outer one, so
  # keep the outermost and drop anything it covers; then apply back-to-front so
  # earlier offsets stay valid.
  def apply(source, edits)
    ordered = edits.sort_by { |s, e, _r| [s, -e] }
    kept = []
    covered_to = -1
    ordered.each do |start, finish, replacement|
      next if start < covered_to

      kept << [start, finish, replacement]
      covered_to = finish
    end

    # Prism reports BYTE offsets, so splice on a binary copy: on a UTF-8 string
    # String#[]= would index by character and corrupt any multibyte file.
    out = source.dup.force_encoding(Encoding::BINARY)
    kept.reverse_each do |start, finish, replacement|
      out[start...finish] = replacement.dup.force_encoding(Encoding::BINARY)
    end
    out.force_encoding(Encoding::UTF_8)
  end

  # Walks the AST collecting source edits and RBS declarations.
  class Walker
    def initialize(source, edits, rbs, stats)
      @source = source
      @source_bytes = source.dup.force_encoding(Encoding::BINARY)
      @edits = edits
      @rbs = rbs
      @stats = stats
      @scope = []
      @pending_sig = nil
    end

    def visit(node)
      return if node.nil?

      # `node.is_a?(T::Struct)` must keep working: the stripped classes include
      # SorbetStripStruct so the same branch is taken. (The `< T::Struct`
      # superclass occurrence is inside drop_superclass's larger edit and is
      # discarded by the outermost-wins merge.)
      if node.is_a?(Prism::ConstantPathNode) && slice(node).start_with?("T::")
        # T::Struct keeps a real marker so `is_a?` still discriminates; every
        # other T:: constant only ever named a type and has no runtime meaning.
        replace(node, slice(node) == "T::Struct" ? "SorbetStripStruct" : "Object")
        return
      end

      case node
      when Prism::IndexOrWriteNode then return visit_index_or_write(node)
      when Prism::ClassNode  then return visit_class(node)
      when Prism::ModuleNode then return visit_module(node)
      when Prism::DefNode    then return visit_def(node)
      when Prism::CallNode
        return if visit_call(node)
      end
      node.compact_child_nodes.each { |child| visit(child) }
    end

    # Spinel has no IndexOrWriteNode. Desugar `a[k] ||= v` to
    # `a[k] || (a[k] = v)`, which keeps the "assign only when falsy" semantics
    # (plain `a[k] = a[k] || v` would write unconditionally).
    def visit_index_or_write(node)
      receiver = node.receiver ? slice(node.receiver) : "self"
      index = node.arguments ? slice(node.arguments) : ""
      read = "#{receiver}[#{index}]"
      value = node.value
      # Edit AROUND the value rather than replacing the whole node, so any T.*
      # nested inside it is still rewritten in this pass.
      @edits << [node.location.start_offset, value.location.start_offset, "(#{read} || (#{read} = "]
      @edits << [value.location.end_offset, node.location.end_offset, "))"]
      visit(value)
      @stats[:deletions] += 1
    end

    def visit_module(node)
      @rbs.open_module(node.name.to_s)
      @scope.push(node.name.to_s)
      visit(node.body)
      @scope.pop
      @rbs.close
    end

    def visit_class(node)
      name = node.name.to_s
      superclass = node.superclass && slice(node.superclass)

      case superclass
      when "T::Struct", "T::InexactStruct", "T::ImmutableStruct"
        @stats[:structs] += 1
        # Open the class BEFORE rewriting: rewrite_struct emits the field
        # attributes, and they must land inside the class or the RBS is
        # rejected outright ("cannot start a declaration").
        @rbs.open_class(name, nil)
        rewrite_struct(node)
      when "T::Enum"
        @stats[:enums] += 1
        @rbs.open_class(name, nil)
        rewrite_enum(node)
      else
        @rbs.open_class(name, superclass)
      end

      @scope.push(name)
      visit(node.body)
      @scope.pop
      @rbs.close
    end

    def struct_like?(superclass)
      ["T::Struct", "T::InexactStruct", "T::ImmutableStruct", "T::Enum"].include?(superclass)
    end

    def visit_def(node)
      sig = @pending_sig
      @pending_sig = nil
      @rbs.method(node, sig, self)
      visit(node.body)
    end

    # Returns true when the node was consumed (children must not be walked).
    def visit_call(node)
      name = node.name.to_s

      if name == "sig" && node.receiver.nil?
        @stats[:sigs] += 1
        @pending_sig = node
        delete_statement(node)
        return true
      end

      if DECLARATION_CALLS_SET.include?(name) && node.receiver.nil?
        @stats[:deletions] += 1
        delete_statement(node)
        return true
      end

      # `K = type_member { ... }` is a T::Generic declaration; the constant is
      # only referenced from sigs, which are gone.
      if %w[type_member type_template].include?(name) && node.receiver.nil?
        @stats[:deletions] += 1
        replace(node, "nil")
        return true
      end

      # `T::Configuration.default_checked_level = ...` and friends configure a
      # runtime that is no longer present; the whole statement goes.
      if node.receiver.is_a?(Prism::ConstantPathNode) && slice(node.receiver).start_with?("T::")
        @stats[:deletions] += 1
        delete_statement(node)
        return true
      end

      if name == "extend" && node.receiver.nil? && extends_sorbet?(node)
        @stats[:deletions] += 1
        delete_statement(node)
        return true
      end

      if name == "require" && node.receiver.nil? && sorbet_require?(node)
        @stats[:deletions] += 1
        delete_statement(node)
        return true
      end

      if t_receiver?(node)
        return true if rewrite_t_call(node, name)
      end

      false
    end

    DECLARATION_CALLS_SET = SorbetStrip::DECLARATION_CALLS.to_set

    def extends_sorbet?(node)
      args = node.arguments&.arguments || []
      args.any? { |a| SorbetStrip::EXTEND_MODULES.include?(slice(a)) }
    end

    def sorbet_require?(node)
      args = node.arguments&.arguments || []
      args.any? { |a| a.is_a?(Prism::StringNode) && a.unescaped == "sorbet-runtime" }
    end

    def t_receiver?(node)
      node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name.to_s == "T"
    end

    def rewrite_t_call(node, name)
      args = node.arguments&.arguments || []

      if SorbetStrip::UNWRAP_FIRST_ARG.include?(name) && args.first
        @stats[:unwraps] += 1
        # Delete only the wrapper either side of the value, so any T.* nested
        # inside it keeps its own offsets and is rewritten in the same pass.
        value = args.first
        @edits << [node.location.start_offset, value.location.start_offset, ""]
        @edits << [value.location.end_offset, node.location.end_offset, ""]
        visit(value)
        return true
      end

      case name
      when "bind"
        # `T.bind(self, X)` is a pure annotation statement.
        @stats[:unwraps] += 1
        delete_statement(node)
        true
      when "absurd"
        # Sorbet raises TypeError here; callers rescue on that class.
        replace(node, %(raise TypeError, "T.absurd"))
        true
      when "type_alias"
        # Aliases are NOT sig-only: `AST::Node = T.type_alias { Locatable }` is
        # used at runtime (`x.is_a?(Node)`). Resolve a single-constant alias to
        # that constant; anything structural (T.any, T::Hash[...]) has no single
        # runtime class, so fall back to Object, which keeps `is_a?` answering
        # instead of raising on nil.
        body = node.block&.body
        inner = body&.compact_child_nodes&.first
        if inner.is_a?(Prism::ConstantReadNode) || inner.is_a?(Prism::ConstantPathNode)
          replace(node, slice(inner))
        else
          replace(node, "Object")
        end
        true
      when "unsafe", "untyped", "nilable", "any", "proc", "noreturn", "anything", "type_parameter", "class_of", "self_type", "attached_class"
        replace(node, "nil")
        true
      else
        false
      end
    end

    def rewrite_struct(node)
      fields = []
      @struct_decl_nodes = []
      each_body_call(node) do |call|
        kind = call.name.to_s
        next unless %w[const prop].include?(kind)

        @struct_decl_nodes << call

        args = call.arguments&.arguments || []
        sym = args[0]
        next unless sym.is_a?(Prism::SymbolNode)

        type_source = args[1] ? slice(args[1]) : "nil"
        opts = args[2].is_a?(Prism::KeywordHashNode) ? args[2] : nil
        default = keyword_value(opts, "default")
        factory = keyword_value(opts, "factory")
        fields << {
          name: sym.unescaped,
          kind: kind,
          type: type_source,
          default: default,
          factory: factory,
          nilable: type_source.include?("T.nilable"),
        }
      end

      fields.each { |f| @rbs.attribute(f[:name], f[:type]) }
      drop_superclass(node)
      # Replace the FIRST const/prop with the generated accessors and
      # constructor, delete the rest, and leave every other member of the class
      # (constants, methods, nested classes) exactly where it was.
      first, *rest = @struct_decl_nodes
      if first
        @edits << [first.location.start_offset, first.location.end_offset, struct_body(fields).strip]
        rest.each { |call| delete_statement(call) }
      else
        insert_after_header(node, struct_body(fields))
      end
    end

    def drop_superclass(node)
      return unless node.superclass

      @edits << [node.constant_path.location.end_offset, node.superclass.location.end_offset, ""]
    end

    def insert_after_header(node, text)
      at = node.constant_path.location.end_offset
      @edits << [at, at, "\n#{text}"]
    end

    def struct_body(fields)
      readers = fields.select { |f| f[:kind] == "const" }.map { |f| f[:name] }
      writers = fields.select { |f| f[:kind] == "prop" }.map { |f| f[:name] }
      lines = []
      lines << "  include SorbetStripStruct"
      lines << "  attr_reader #{readers.map { |n| ":#{n}" }.join(', ')}" unless readers.empty?
      lines << "  attr_accessor #{writers.map { |n| ":#{n}" }.join(', ')}" unless writers.empty?
      # T::Struct's constructor is `initialize(hash = {})`, so callers pass
      # either a positional Hash or keywords. Accept both.
      lines << "  def initialize(attrs = nil, **keywords)"
      lines << "    kwargs = attrs ? attrs.merge(keywords) : keywords"
      fields.each do |f|
        fallback =
          if f[:factory] then "(#{f[:factory]}).call"
          elsif f[:default] then f[:default]
          elsif f[:nilable] then "nil"
          else %(raise ArgumentError, "missing keyword: :#{f[:name]}")
          end
        lines << "    @#{f[:name]} = kwargs.key?(:#{f[:name]}) ? kwargs[:#{f[:name]}] : (#{fallback})"
      end
      lines << "  end"
      lines << "  def to_h"
      lines << "    { #{fields.map { |f| "#{f[:name]}: @#{f[:name]}" }.join(', ')} }"
      lines << "  end"
      # Real T::Struct answers `props`, NOT Ruby Struct's `members`. Adding
      # `members` makes reflective walkers take the Ruby-Struct branch these
      # classes were never meant to satisfy (measured: 39 failures vs 11), so
      # only `props` is provided.
      names = fields.map { |f| ":#{f[:name]}" }.join(", ")
      lines << "  FIELDS = [#{names}].freeze"
      lines << "  def self.props = FIELDS.to_h { |f| [f, {}] }"
      lines.join("\n")
    end

    def rewrite_enum(node)
      members = []
      @enum_block_node = nil
      each_body_call(node) do |call|
        next unless call.name.to_s == "enums" && call.block

        @enum_block_node = call

        body = call.block.body
        next unless body

        body.compact_child_nodes.each do |stmt|
          next unless stmt.is_a?(Prism::ConstantWriteNode)

          value = stmt.value
          serialized =
            if value.is_a?(Prism::CallNode) && value.name.to_s == "new"
              arg = value.arguments&.arguments&.first
              arg.is_a?(Prism::StringNode) ? arg.unescaped : stmt.name.to_s.downcase
            else
              stmt.name.to_s.downcase
            end
          members << { const: stmt.name.to_s, serialized: serialized }
        end
      end

      drop_superclass(node)
      if @enum_block_node
        @edits << [@enum_block_node.location.start_offset, @enum_block_node.location.end_offset,
                   enum_body(members).strip]
      else
        insert_after_header(node, enum_body(members))
      end
    end

    # Members are instances of the enum class ITSELF, not of a nested value
    # type: a T::Enum may define instance methods that its members answer, and
    # those live in this same class body.
    def enum_body(members)
      lines = []
      lines << "  attr_reader :serialized"
      lines << "  def initialize(serialized)"
      lines << "    @serialized = serialized"
      lines << "  end"
      lines << "  def serialize = @serialized"
      lines << "  def to_s = @serialized"
      lines << "  def inspect = \"#<\#{self.class}::\#{@serialized}>\""
      members.each { |m| lines << "  #{m[:const]} = new(#{m[:serialized].inspect})" }
      lines << "  ALL = [#{members.map { |m| m[:const] }.join(', ')}].freeze"
      lines << "  def self.values = ALL"
      lines << "  def self.deserialize(raw) = ALL.find { |v| v.serialize == raw }"
      lines << "  def self.from_serialized(raw) = deserialize(raw)"
      lines.join("\n")
    end

    def each_body_call(node)
      body = node.body
      return unless body

      body.compact_child_nodes.each do |stmt|
        yield stmt if stmt.is_a?(Prism::CallNode)
      end
    end

    def keyword_value(opts, key)
      return nil unless opts

      pair = opts.elements.find do |e|
        e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode) && e.key.unescaped == key
      end
      pair && slice(pair.value)
    end

    def replace_class_body(node, replacement)
      # Drop `< T::Struct` and swap the whole body for the generated one.
      if node.superclass
        @edits << [node.constant_path.location.end_offset, node.superclass.location.end_offset, ""]
      end
      body = node.body
      if body
        @edits << [body.location.start_offset, body.location.end_offset, replacement.strip]
      else
        @edits << [node.constant_path.location.end_offset, node.constant_path.location.end_offset,
                   "\n#{replacement}\n"]
      end
    end

    def slice(node)
      start = node.location.start_offset
      @source.byteslice(start, node.location.end_offset - start)
    end

    def replace(node, text)
      @edits << [node.location.start_offset, node.location.end_offset, text]
    end

    # Remove the statement and the blank line it leaves behind.
    def delete_statement(node)
      start = node.location.start_offset
      finish = node.location.end_offset
      bytes = @source_bytes
      line_start = bytes.rindex("\n", start - 1)
      if line_start && bytes.byteslice(line_start + 1, start - line_start - 1).to_s.strip.empty?
        start = line_start + 1
      end
      # These are standalone statements, so take the rest of the line with them:
      # `T.bind(self, X) rescue nil` would otherwise leave a dangling modifier.
      newline = bytes.index("\n", finish)
      finish = newline if newline
      finish += 1 if finish < bytes.bytesize && bytes.byteslice(finish, 1) == "\n"
      @edits << [start, finish, ""]
    end
  end

  # Accumulates RBS declarations mirroring the removed sigs.
  # Emits FLAT, fully-qualified declarations (`class AST::Param`) rather than
  # nested ones. Spinel names a nested class `Outer::Inner`; a nested RBS
  # declaration is flattened by its extractor to `Outer_Inner`, which then
  # matches nothing -- measured at 43 of 231 names before this, so nearly all
  # of the type information was being discarded on a naming detail.
  class RBSBuilder
    def initialize
      @stack = []
      @blocks = {}
      @order = []
      @open = []
    end

    def open_module(name)
      @stack.push(name)
      @open.push(:module)
    end

    def open_class(name, superclass)
      @stack.push(name)
      @open.push(:class)
      key = @stack.join("::")
      unless @blocks.key?(key)
        @blocks[key] = { superclass: superclass, lines: [] }
        @order << key
      end
    end

    def close
      @stack.pop
      @open.pop
    end

    def attribute(name, type_source)
      add("attr_reader #{name}: #{RBSType.convert(type_source)}")
    end

    def method(def_node, sig_node, walker)
      name = def_node.name.to_s
      prefix = def_node.receiver ? "self." : ""
      types = sig_node ? RBSType.from_sig(sig_node, walker) : nil
      add("def #{prefix}#{name}: #{RBSType.signature(def_node.parameters, types, walker)}")
    end

    # Declarations only attach to an enclosing CLASS; a bare module namespace
    # has no instances for Spinel to type.
    def add(line)
      return if @open.empty? || !@open.include?(:class)

      key = @stack.join("::")
      unless @blocks.key?(key)
        @blocks[key] = { superclass: nil, lines: [] }
        @order << key
      end
      @blocks[key][:lines] << line
    end

    def rbs_const(name)
      name.sub(/\AT::/, "")
    end

    def render
      return "" if @order.empty?

      out = []
      @order.each do |key|
        block = @blocks[key]
        next if block[:lines].empty?

        head = block[:superclass] ? "class #{key} < #{rbs_const(block[:superclass])}" : "class #{key}"
        out << head
        block[:lines].each { |l| out << "  #{l}" }
        out << "end"
      end
      out.empty? ? "" : out.join("\n") + "\n"
    end
  end

  # Sorbet type expression -> RBS type. Advisory seeds, so unknown forms
  # degrade to `untyped` rather than guessing.
  module RBSType
    module_function

    def convert(source)
      return "untyped" if source.nil?

      s = source.strip
      case s
      when /\AT\.nilable\((.*)\)\z/m
        inner = convert(::Regexp.last_match(1))
        # `A | B?` is ambiguous in RBS; a nilable union has to be parenthesised.
        inner.include?(" | ") ? "(#{inner})?" : "#{inner}?"
      when /\AT::Array\[(.*)\]\z/m         then "Array[#{convert(::Regexp.last_match(1))}]"
      when /\AT::Set\[(.*)\]\z/m           then "Set[#{convert(::Regexp.last_match(1))}]"
      when /\AT::Hash\[(.*)\]\z/m
        k, v = split_pair(::Regexp.last_match(1))
        v ? "Hash[#{convert(k)}, #{convert(v)}]" : "untyped"
      when /\AT::Boolean\z/                then "bool"
      when /\AT\.untyped\z/, /\AT\.anything\z/ then "untyped"
      when /\AT\.noreturn\z/               then "bot"
      when /\AT\.any\((.*)\)\z/m           then union(::Regexp.last_match(1))
      when /\AT\.proc/                     then "^(*untyped) -> untyped"
      when /\AT\.type_parameter/           then "untyped"
      when /\AT\.class_of\((.*)\)\z/m      then "singleton(#{convert(::Regexp.last_match(1))})"
      when "Integer", "Float", "String", "Symbol", "NilClass", "TrueClass", "FalseClass" then s
      when /\A[A-Z][A-Za-z0-9_:]*\z/       then s
      else "untyped"
      end
    end

    def union(inner)
      parts = split_top(inner)
      return "untyped" if parts.length < 2

      # Parenthesise members that are themselves unions, so nesting stays
      # unambiguous however the result is embedded.
      parts.map { |p| c = convert(p); c.include?(" | ") ? "(#{c})" : c }.join(" | ")
    end

    def split_pair(inner)
      parts = split_top(inner)
      parts.length == 2 ? parts : [inner, nil]
    end

    # Split on top-level commas only.
    def split_top(inner)
      depth = 0
      parts = [+""]
      inner.each_char do |ch|
        case ch
        when "[", "(", "{" then depth += 1
        when "]", ")", "}" then depth -= 1
        end
        if ch == "," && depth.zero?
          parts << +""
        else
          parts.last << ch
        end
      end
      parts.map(&:strip).reject(&:empty?)
    end

    def from_sig(sig_node, walker)
      block = sig_node.block
      return nil unless block

      body = walker.send(:slice, block)
      params = {}
      if (m = body.match(/params\((.*?)\)\s*(?:\.|\z)/m))
        split_top(m[1]).each do |entry|
          k, v = entry.split(":", 2)
          params[k.to_s.strip] = v.to_s.strip if v
        end
      end
      returns =
        if body.include?(".void")
          "void"
        elsif (r = body.match(/returns\((.*?)\)\s*(?:\.|\}|\z)/m))
          convert(r[1])
        else
          "untyped"
        end
      { params: params, returns: returns }
    end

    def signature(parameters, types, _walker)
      return "(*untyped) -> untyped" unless types

      names = []
      if parameters
        parameters.requireds.each { |p| names << [:req, p.respond_to?(:name) ? p.name.to_s : "arg"] }
        parameters.optionals.each { |p| names << [:opt, p.name.to_s] }
        names << [:rest, parameters.rest.name.to_s] if parameters.rest.respond_to?(:name) && parameters.rest&.name
        parameters.keywords.each { |p| names << [:key, p.name.to_s] }
      end

      rendered = names.map do |kind, name|
        t = convert(types[:params][name])
        case kind
        when :req  then t
        when :opt  then "?#{t}"
        when :rest then "*#{t}"
        when :key  then "#{name}: #{t}"
        end
      end
      # A union return has to be parenthesised: `-> A | B` does not parse.
      ret = types[:returns]
      ret = "(#{ret})" if ret.include?(" | ")
      "(#{rendered.join(', ')}) -> #{ret}"
    end
  end
end

require "set"
exit(SorbetStrip.main(ARGV)) if $PROGRAM_NAME == __FILE__
