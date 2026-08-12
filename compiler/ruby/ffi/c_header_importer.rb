# typed: strict

require "open3"
require "set"
require "sorbet-runtime"

# Expands the deliberately small, target-aware C header directive into the
# same EXTERN declarations users can write by hand. Zig remains the C parser:
# this class only translates Zig's normalized ABI spellings into CLEAR's
# boundary types.
class CHeaderImporter
  extend T::Sig

  class Error < StandardError; end

  Directive = T.type_alias { T::Hash[Symbol, String] }

  DIRECTIVE = /EXTERN\s+FROM\s+HEADER\s+"([^"]+)"\s+LINK\s+"([^"]+)"\s+ABI\s+C\s*;/m
  SCALARS = T.let({
    "void" => "Void",
    "bool" => "Bool",
    "u8" => "UInt8", "u16" => "UInt16", "u32" => "UInt32", "u64" => "UInt64",
    "i8" => "Int8", "i16" => "Int16", "i32" => "Int32", "i64" => "Int64",
    "f32" => "Float32", "f64" => "Float64",
    "c_char" => "Int8", "c_schar" => "Int8", "c_uchar" => "UInt8",
    "c_short" => "Int16", "c_ushort" => "UInt16",
    "c_int" => "TargetInt", "c_uint" => "TargetUInt",
    "c_long" => "TargetLong", "c_ulong" => "TargetULong",
    "c_longlong" => "TargetLongLong", "c_ulonglong" => "TargetULongLong",
    "usize" => "TargetUInt@size", "isize" => "TargetInt@size",
  }.freeze, T::Hash[String, String])

  Param = Struct.new(:name, :type, :mutable)

  sig { params(source: String, source_dir: String).returns(String) }
  def self.expand(source, source_dir:)
    source.gsub(DIRECTIVE) do
      header = T.must(Regexp.last_match(1))
      library = T.must(Regexp.last_match(2))
      import(header, library, source_dir: source_dir)
    end
  end

  sig { params(header: String, library: String, source_dir: String).returns(String) }
  def self.import(header, library, source_dir:)
    header_path = File.expand_path(header, source_dir)
    raise Error, "C header not found: #{header_path}" unless File.file?(header_path)

    zig = zig_executable
    stdout = compiler_zig_translate_c(zig, source_dir, header_path)

    header_source = File.read(header_path)
    Translator.new(stdout, header: header, library: library,
      allowed_names: declaration_names(header_source)).declarations
  rescue Errno::ENOENT
    raise Error, "Zig is required to import C headers"
  end

  # Ruby shells out through Open3. The self-hosted compiler maps this adapter
  # onto compilerZigTranslateC in the compiler native support module.
  # ruby-to-clear: skip
  sig { params(zig: String, source_dir: String, header_path: String).returns(String) }
  def self.compiler_zig_translate_c(zig, source_dir, header_path)
    stdout, stderr, status = Open3.capture3(zig, "translate-c", "-I#{source_dir}", header_path)
    unless status.success?
      detail = stderr.split("\n").take(8).join("\n").strip
      raise Error, "Zig could not import C header #{header_path.inspect}: #{detail}"
    end

    stdout
  end

  # ruby-to-clear: skip
  sig { returns(String) }
  def self.zig_executable
    candidates = [
      ENV["CLEAR_ZIG"],
      File.expand_path("~/zig-x86_64-linux-0.16.0/zig"),
      File.expand_path("../../../../zig/zig-new/zig", __dir__),
      "zig",
    ].compact
    candidates.find { |candidate| candidate == "zig" || File.executable?(candidate) } || "zig"
  end

  sig { params(header_source: String).returns(T::Set[String]) }
  def self.declaration_names(header_source)
    clean = header_source.gsub(%r{/\*.*?\*/}m, " ").gsub(%r{//[^\n]*}, " ")
    names = T.let(Set.new, T::Set[String])
    clean.scan(/\btypedef\s+struct\b.*?\}\s*([A-Za-z_]\w*)\s*;/m) { |match| names.add(T.must(match[0])) }
    clean.scan(/\btypedef\s+struct\s+[A-Za-z_]\w*\s+([A-Za-z_]\w*)\s*;/) { |match| names.add(T.must(match[0])) }
    clean.scan(/\btypedef\b.*?\(\s*\*\s*([A-Za-z_]\w*)\s*\).*?;/m) { |match| names.add(T.must(match[0])) }
    clean.scan(/\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*;/m) { |match| names.add(T.must(match[0])) }
    names
  end

  class Translator
    extend T::Sig

    sig { params(zig_source: String, header: String, library: String, allowed_names: T::Set[String]).void }
    def initialize(zig_source, header:, library:, allowed_names:)
      @zig_source = zig_source
      @header = header
      @library = library
      @aliases = T.let({}, T::Hash[String, String])
      @type_names = T.let({}, T::Hash[String, String])
      @allowed_names = allowed_names
    end

    sig { returns(String) }
    def declarations
      collect_aliases!
      structs = translate_structs
      functions = translate_functions
      declarations = structs + functions
      if declarations.length == 0
        raise Error, "C header #{@header.inspect} contains no ABI declarations CLEAR can import"
      end
      (declarations + [""]).join("\n")
    end

    private

    sig { void }
    def collect_aliases!
      @zig_source.split("\n").each do |line|
        match = T.let(line.match(/^pub const ([A-Za-z_]\w*) = (.+);$/), T.nilable(MatchData))
        next unless match
        name = T.must(match[1])
        rhs = T.must(match[2]).strip
        @aliases[name] = rhs
      end
    end

    sig { returns(T::Array[String]) }
    def translate_structs
      output = T.let([], T::Array[String])
      @zig_source.scan(/^pub const ([A-Za-z_]\w*) = extern struct \{\n(.*?)^\};$/m) do |name, body|
        c_name = T.cast(name, String)
        next unless @allowed_names.include?(c_name)
        clear_name = clear_type_name(c_name)
        fields = T.let([], T::Array[String])
        T.cast(body, String).split("\n").each do |line|
          match = line.match(/^\s*([A-Za-z_]\w*):\s*(.+?)(?:\s*=\s*.+)?,$/)
          next unless match
          field_type = map_type(T.must(match[2]), position: :field)
          next unless field_type
          fields << "#{T.must(match[1])}: #{field_type}"
        end
        next if fields.empty? && !T.cast(body, String).strip.empty?
        output << %(EXTERN STRUCT #{clear_name} { #{fields.join(', ')} } AS "#{c_name}" FROM "#{@library}" ABI C HEADER "#{@header}";)
      end

      alias_names = @aliases.keys
      alias_index = T.let(0, Integer)
      while alias_index < alias_names.length
        name = alias_names.fetch(alias_index)
        rhs = @aliases.fetch(name)
        if @allowed_names.include?(name) &&
           rhs.start_with?("struct_") &&
           @zig_source.match?(/^pub const #{Regexp.escape(rhs)} = opaque \{/)
          output << %(EXTERN STRUCT #{clear_type_name(name)} {} AS "#{name}" FROM "#{@library}" ABI C HEADER "#{@header}";)
        end
        alias_index += 1
      end
      output.uniq
    end

    sig { returns(T::Array[String]) }
    def translate_functions
      output = T.let([], T::Array[String])
      @zig_source.split("\n").each do |line|
        parsed = parse_function_line(line)
        next unless parsed
        name, raw_params, raw_return = parsed
        next unless @allowed_names.include?(name)
        return_type = map_type(raw_return, position: :return)
        next unless return_type
        raw_param_parts = split_top_level(raw_params)
        params = T.let([], T::Array[Param])
        valid_params = T.let(true, T::Boolean)
        raw_param_parts.each_with_index do |raw, index|
          if raw.strip == "..."
            valid_params = false
            break
          else
            param_match = raw.match(/^([A-Za-z_]\w*):\s*(.+)$/)
            param_name = T.let("arg#{index}", String)
            raw_type = T.let(raw, String)
            if param_match
              param_name = T.must(param_match[1])
              raw_type = T.must(param_match[2])
            end
            param = map_param(param_name, raw_type)
            unless param
              valid_params = false
              break
            end
            params << T.must(param)
          end
        end
        next unless valid_params
        rendered_params = params.map do |param|
          prefix = param.mutable ? "MUTABLE " : ""
          "#{prefix}#{param.name}: #{param.type}"
        end
        output << %(EXTERN FN #{name}(#{rendered_params.join(', ')}) RETURNS #{return_type} AS "#{name}" FROM "#{@library}" ABI C HEADER "#{@header}";)
      end
      output
    end

    sig { params(line: String).returns(T.nilable([String, String, String])) }
    def parse_function_line(line)
      prefix = "pub extern fn "
      return nil unless line.start_with?(prefix)
      open_index = line.index("(", prefix.length)
      return nil unless open_index
      name = T.must(line[prefix.length...open_index])
      depth = 0
      close_index = T.let(nil, T.nilable(Integer))
      line.each_char.with_index do |char, index|
        next if index < open_index
        depth += 1 if char == "("
        depth -= 1 if char == ")"
        if depth.zero?
          close_index = index
          break
        end
      end
      return nil unless close_index
      params = T.must(line[(open_index + 1)...close_index])
      result = T.must(line[(close_index + 1)..]).strip
      return nil unless result.end_with?(";")
      [name, params, T.must(result[0...-1])]
    end

    sig { params(name: String, raw_type: String).returns(T.nilable(Param)) }
    def map_param(name, raw_type)
      raw = resolve_alias(raw_type.strip)
      if c_callback_type?(raw)
        callback = map_callback(raw)
        return callback ? Param.new(name, callback, false) : nil
      end
      if (match = raw.match(/^\[\*c\]\?\*(.+)$/))
        inner = map_type(T.must(match[1]), position: :param)
        return inner ? Param.new(name, "?#{inner}", true) : nil
      end
      if (match = raw.match(/^\[\*c\](?!const\s)(.+)$/))
        inner = map_type(T.must(match[1]), position: :param)
        return inner ? Param.new(name, inner, true) : nil
      end
      if raw == "[*c]const u8"
        return Param.new(name, "String@c", false)
      end
      if (match = raw.match(/^\[\*c\]const\s+(.+)$/))
        inner = map_type(T.must(match[1]), position: :param)
        return inner ? Param.new(name, "[]@c #{inner}", false) : nil
      end
      if (match = raw.match(/^\?\*(.+)$/))
        inner = map_type(T.must(match[1]), position: :param)
        return inner ? Param.new(name, inner, false) : nil
      end
      mapped = map_type(raw, position: :param)
      mapped ? Param.new(name, mapped, false) : nil
    end

    sig { params(raw_type: String, position: Symbol).returns(T.nilable(String)) }
    def map_type(raw_type, position:)
      original = raw_type.strip
      return clear_type_name(original) if opaque_alias?(original)

      raw = resolve_alias(original)
      return SCALARS[raw] if SCALARS.key?(raw)
      return map_callback(raw) if c_callback_type?(raw)
      if (match = raw.match(/^\[(\d+)\](.+)$/))
        item = map_type(T.must(match[2]), position: :field)
        return item ? "[#{T.must(match[1])}]#{item}" : nil
      end
      if raw == "[*c]const u8"
        return position == :return ? "?String@c" : "String@c"
      end
      if (match = raw.match(/^\[\*c\]const\s+(.+)$/))
        item = map_type(T.must(match[1]), position: :field)
        return item ? "?[]@c #{item}" : nil
      end
      if (match = raw.match(/^\?\*(.+)$/))
        item = map_type(T.must(match[1]), position: :field)
        return item ? "?#{item}" : nil
      end
      return clear_type_name(raw) if c_named_type?(raw)

      nil
    end

    sig { params(raw: String).returns(T::Boolean) }
    def opaque_alias?(raw)
      alias_chain(raw).any? { |target| target.start_with?("opaque {") }
    end

    sig { params(raw: String).returns(T.nilable(String)) }
    def map_callback(raw)
      match = raw.match(/^\?\*const fn \((.*)\) callconv\(\.c\) (.+)$/)
      return nil unless match
      raw_params = split_top_level(T.must(match[1]))
      # `filter_map` lowered this as `?String[]`, so `join` could not resolve
      # an overload even after its length check established success.
      params = T.let([], T::Array[String])
      raw_params.each do |item|
        type = item.sub(/^[A-Za-z_]\w*:\s*/, "")
        mapped = map_type(type, position: :param)
        params << mapped if mapped
      end
      return nil unless params.length == raw_params.length
      result = map_type(T.must(match[2]), position: :return)
      result ? "FN(#{params.join(', ')}) -> #{result} CALLCONV C" : nil
    end

    sig { params(raw: String).returns(String) }
    def resolve_alias(raw)
      alias_chain(raw).last || raw
    end

    sig { params(raw: String).returns(T::Array[String]) }
    def alias_chain(raw)
      seen = T.let({}, T::Hash[String, T::Boolean])
      current = raw
      chain = T.let([], T::Array[String])
      while @aliases.key?(current) && !seen[current]
        seen[current] = true
        current = T.must(@aliases[current])
        chain << current
      end
      chain
    end

    sig { params(raw: String).returns(T::Boolean) }
    def c_callback_type?(raw)
      raw.include?("callconv(.c)") && raw.include?("fn (")
    end

    sig { params(raw: String).returns(T::Boolean) }
    def c_named_type?(raw)
      return true if @type_names.key?(raw)
      @aliases.key?(raw) || raw.start_with?("struct_") || raw.match?(/\A[A-Za-z_]\w*\z/)
    end

    sig { params(c_name: String).returns(String) }
    def clear_type_name(c_name)
      existing = T.let(@type_names[c_name], T.nilable(String))
      return existing if existing

      words = T.let([], T::Array[String])
      c_name.sub(/^struct_/, "").split("_").each do |part|
        next if part.empty?

        # CLEAR has `upcase`/`downcase`, but no Ruby `capitalize` intrinsic.
        # Normalize both halves explicitly to retain Ruby's capitalization
        # semantics for mixed-case C spelling.
        first = T.must(part[0, 1]).upcase
        rest = T.must(part[1..]).downcase
        words << (first + rest)
      end
      clear_name = words.join
      @type_names[c_name] = clear_name
      clear_name
    end

    sig { params(text: String).returns(T::Array[String]) }
    def split_top_level(text)
      return [] if text.strip.empty? || text.strip == "void"
      depth = 0
      start = 0
      parts = T.let([], T::Array[String])
      text.each_char.with_index do |char, index|
        depth += 1 if ["(", "[", "{"].include?(char)
        depth -= 1 if [")", "]", "}"].include?(char)
        next unless char == "," && depth.zero?
        parts << T.must(text[start...index]).strip
        start = index + 1
      end
      parts << T.must(text[start..]).strip
      parts
    end
  end
end
