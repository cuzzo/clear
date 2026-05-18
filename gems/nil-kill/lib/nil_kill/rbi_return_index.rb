# typed: false
# frozen_string_literal: true

module NilKill
  class RbiReturnIndex
    AMBIGUOUS_GLOBAL_METHODS = Set.new(%w[
      __send__ method public_send send
    ]).freeze

    def self.build
      index = new
      index.load_sorbet_payload
      index.load_paths(Dir.glob(File.join(ROOT, "sorbet", "rbi", "**", "*.rbi")).sort)
      index
    end

    def initialize
      @returns = Hash.new { |hash, key| hash[key] = [] }
      @owner_returns = Hash.new { |hash, key| hash[key] = Hash.new { |inner, method| inner[method] = [] } }
      # return_type / concrete_return_type? are PURE over the immutable
      # post-build index (@returns/@owner_returns written only during
      # `build`, read-only after) and this is a process-global
      # singleton (NilKill.rbi_return_index). They are recomputed
      # identically for every call site across every SourceIndex pass
      # (index_sources re-walks all files ~3-7x for the noreturn
      # fixpoint). Memoizing on the singleton collapses that to one
      # computation per distinct argument for the whole infer run.
      # Byte-identical by construction: same inputs -> same outputs;
      # the only "mutation" is the Hash default-block inserting a benign
      # empty [] for unknown keys, which never changes a result.
      @rt_memo = {}
      @crt_memo = {}
    end

    def return_type(method_name, receiver_type = nil)
      @rt_memo.fetch([method_name.to_s, receiver_type]) do |k|
        @rt_memo[k] = return_type_uncached(method_name, receiver_type)
      end
    end

    def return_type_uncached(method_name, receiver_type = nil)
      owner_candidates_for(receiver_type).each do |owner|
        types = @owner_returns[owner][method_name.to_s].compact.uniq.select { |type| concrete_return_type?(type) }
        candidate = normalize_candidate_set(types)
        return candidate if NilKill.useful_type?(candidate)
      end
      return nil if AMBIGUOUS_GLOBAL_METHODS.include?(method_name.to_s)
      types = @returns[method_name.to_s].compact.uniq.select { |type| concrete_return_type?(type) }
      normalize_candidate_set(types)
    end

    def load_sorbet_payload
      return if ENV["NIL_KILL_NO_SORBET_PAYLOAD_RBI"] == "1"
      if Dir.glob(File.join(SORBET_PAYLOAD_DIR, "**", "*.rbi")).empty?
        FileUtils.rm_rf(SORBET_PAYLOAD_DIR)
        FileUtils.mkdir_p(SORBET_PAYLOAD_DIR)
        _out, _err, status = Open3.capture3("bundle", "exec", "srb", "tc", "--no-config",
          "--print=payload-sources:#{SORBET_PAYLOAD_DIR}", "--stop-after", "init", chdir: ROOT)
        return unless status.success?
      end
      load_paths(Dir.glob(File.join(SORBET_PAYLOAD_DIR, "**", "*.rbi")).sort)
    rescue StandardError
      nil
    end

    def load_paths(paths)
      paths.each { |path| load_path(path) }
    end

    def load_path(path)
      pending_sigs = []
      current_sig = nil
      owner_stack = []
      File.readlines(path).each do |line|
        stripped = line.strip
        if current_sig
          current_sig << " " << stripped
          if stripped == "end" || stripped.end_with?("}")
            pending_sigs << current_sig
            current_sig = nil
          end
          next
        end

        if (match = stripped.match(/\A(?:class|module)\s+([^\s<;]+)/))
          owner_stack << normalize_owner_name(match[1])
          next
        end

        if stripped.start_with?("sig ")
          if stripped.include?("{") && stripped.include?("}")
            pending_sigs << stripped
          else
            current_sig = stripped.dup
          end
          next
        end

        if (match = stripped.match(/\Adef\s+(?:self\.)?([^\s(;]+)/))
          method_name = match[1]
          owner = owner_stack.last
          pending_sigs.each do |sig|
            type = extract_rbi_return_type(sig)
            next unless NilKill.useful_type?(type)
            normalized = normalize_return_type(type)
            @returns[method_name] << normalized
            @owner_returns[owner][method_name] << normalized if owner
          end
          pending_sigs = []
        elsif stripped == "end"
          owner_stack.pop
        elsif !stripped.empty? && !stripped.start_with?("#")
          pending_sigs = []
        end
      end
    rescue StandardError
      nil
    end

    def normalize_return_type(type)
      type.to_s
        .gsub(/\bT\.self_type\b/, "T.self_type")
        .gsub(/T\.type_parameter\(:\w+\)/, "T.untyped")
        .gsub(/\b(?:Elem|K|V)\b/, "T.untyped")
        .sub(/\A::T\./, "T.")
        .strip
    end

    def normalize_owner_name(owner)
      owner.to_s.delete_prefix("::").gsub(/\A(::)?/, "")
    end

    def owner_name_for(type)
      raw = type.to_s
      return nil if raw.empty?
      case raw
      when /\AT::Array\b/ then "Array"
      when /\AT::Hash\b/ then "Hash"
      when /\AT::Enumerable\b/ then "Enumerable"
      when /\AT::Set\b/ then "Set"
      when "T::Boolean" then nil
      else
        raw.delete_prefix("::")
      end
    end

    def owner_candidates_for(type)
      owner = owner_name_for(type)
      return [] unless owner
      candidates = [owner]
      candidates << "Enumerable" if %w[Array Hash Set Range Enumerator].include?(owner)
      candidates << "Object"
      candidates << "BasicObject"
      candidates.uniq
    end

    def extract_rbi_return_type(sig)
      matches = sig.to_s.enum_for(:scan, /returns\(/).map { Regexp.last_match.begin(0) }
      matches.reverse_each do |idx|
        ret = extract_call_args_at(sig, idx, "returns")
        return ret if ret
      end
      nil
    end

    def extract_call_args_at(source, idx, name)
      start = idx + name.length + 1
      depth = 1
      i = start
      while i < source.length
        case source[i]
        when "(" then depth += 1
        when ")"
          depth -= 1
          return source[start...i] if depth.zero?
        end
        i += 1
      end
      nil
    end

    # Stdlib RBI classes that aren't project types but happen to have common
    # method names. When the static analyser can't resolve a receiver and
    # falls back to the global RBI lookup, these classes contaminate the
    # candidate set (e.g. `obj.name` -> `Resolv::DNS::Name` purely because
    # Resolv::DNS::Name defines a `name` method). Strip them so the bare-
    # receiver fallback can't produce wrong narrowings.
    AMBIGUOUS_RBI_OWNERS = %w[
      Resolv:: URI:: OpenSSL:: Net:: WEBrick:: CGI:: REXML:: DRb::
      Gem:: Bundler:: RubyVM:: ObjectSpace Logger:: Thread:: Mutex
      Tempfile Pathname FileUtils:: FileTest
    ].freeze

    def concrete_return_type?(type)
      @crt_memo.fetch(type) { |k| @crt_memo[k] = concrete_return_type_uncached?(type) }
    end

    def concrete_return_type_uncached?(type)
      return false unless NilKill.useful_type?(type)
      str = type.to_s
      return false if AMBIGUOUS_RBI_OWNERS.any? { |prefix| str.include?(prefix) }
      !str.match?(/\b(?:Return|Args)\b/) &&
        !str.include?("T.self_type") &&
        !str.include?("T.attached_class") &&
        !str.include?("Sorbet::Private::") &&
        str != "BasicObject"
    end

    def normalize_candidate_set(types)
      normalized = Array(types).compact.map { |type| normalize_return_candidate(type) }.uniq
      arrays = normalized.select { |type| type.start_with?("T::Array[") }
      enumerators = normalized.select { |type| type.start_with?("T::Enumerator[") }
      if !arrays.empty? && (normalized - arrays - enumerators).empty?
        return arrays.uniq.first if arrays.uniq.size == 1
      end
      return nil if normalized.empty?
      return "T::Boolean" if normalized.all? { |type| type == "T::Boolean" }
      return normalized.first if normalized.size == 1 && NilKill.useful_type?(normalized.first)
      nil
    end

    def normalize_return_candidate(type)
      case type.to_s
      when "TrueClass", "FalseClass" then "T::Boolean"
      else type.to_s
      end
    end
  end
end
