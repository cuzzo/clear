# frozen_string_literal: true

module Decomplex
  module Syntax
    SemanticEffectSite = Struct.new(:kind, :detail, :file, :function, :owner, :line, :span,
                                    keyword_init: true)
    EffectLexicon = Struct.new(
      :dispatch_mids, :meta_mids, :method_obj_mids, :io_consts,
      :io_bare, :dir_context, :context_pairs, :context_bare,
      :callback_set, :core_consts,
      keyword_init: true
    )

    def self.core_owner_names(language)
      profile = language_profile(language)
      return [] unless profile.respond_to?(:effect_lexicon, true)

      lexicon = profile.send(:effect_lexicon)
      Array(lexicon&.core_consts)
    rescue ArgumentError
      []
    end

    class Document
      def semantic_effect_sites
        @semantic_effect_sites ||= adapter.semantic_effect_sites(self)
      end
    end

    class TreeSitterLanguageAdapter
      def semantic_effect_sites(document)
        semantic_effect_sites_from_calls(document)
      end

      private

      def effect_lexicon
        nil
      end

      def semantic_effect_sites_from_calls(document)
        return [] unless effect_lexicon

        by_operation = {}
        document.call_sites.each do |call|
          site = semantic_effect_site_for_call(call)
          next unless site

          key = [site.kind, site.detail, site.file, site.function, site.owner,
                 site.line, call.receiver, call.message, call.arguments]
          current = by_operation[key]
          if current.nil? || span_width(site.span) > span_width(current.span)
            by_operation[key] = site
          end
        end
        by_operation.values
      end

      def span_width(span_value)
        ((span_value[2] - span_value[0]) * 100_000) + (span_value[3] - span_value[1])
      end

      def semantic_effect_site_for_call(call)
        lexicon = effect_lexicon
        message = call.message.to_s

        if effect_callback_call?(call, message)
          return semantic_effect_site_from_call(call, :callback_inversion, message)
        end
        return semantic_effect_site_from_call(call, :metaprogramming, message) if lexicon.meta_mids.include?(message)
        return semantic_effect_site_from_call(call, :dynamic_dispatch, message) if lexicon.dispatch_mids.include?(message)

        if message == "call" && !call.receiver.to_s.empty?
          return semantic_effect_site_from_call(call, :dynamic_dispatch, "method(...).call") if method_object_receiver?(call.receiver)
          return semantic_effect_site_from_call(call, :dynamic_dispatch, "#{call.receiver}.call") if variable_receiver?(call.receiver)
        end

        const_effect_site_for_call(call, message) ||
          bare_effect_site_for_call(call, message) ||
          mutation_effect_site_for_call(call, message)
      end

      def const_effect_site_for_call(call, message)
        receiver = call.receiver.to_s
        return nil if receiver.empty? || receiver == "self"

        lexicon = effect_lexicon
        base = receiver.sub(/\A::/, "").split("::").first
        return semantic_effect_site_from_call(call, :context_dependency, "Dir.#{message}") \
          if base == "Dir" && lexicon.dir_context.include?(message)

        if lexicon.io_consts.include?(base) || ruby_net_receiver?(receiver)
          return semantic_effect_site_from_call(call, :hidden_io, "#{receiver.sub(/\A::/, "")}.#{message}")
        end
        return semantic_effect_site_from_call(call, :context_dependency, "ENV") if receiver == "ENV"

        if lexicon.context_pairs[base]&.include?(message)
          return semantic_effect_site_from_call(call, :context_dependency, "#{base}.#{message}")
        end

        nil
      end

      def bare_effect_site_for_call(call, message)
        return nil unless call.receiver.to_s == "self"

        lexicon = effect_lexicon
        return semantic_effect_site_from_call(call, :hidden_io, message) \
          if lexicon.io_bare.include?(message) || GENERIC_SYSTEM_IO_BARE.include?(message)
        return semantic_effect_site_from_call(call, :context_dependency, message) if lexicon.context_bare.include?(message)

        nil
      end

      def mutation_effect_site_for_call(call, message)
        return semantic_effect_site_from_call(call, :hidden_mutation, message) \
          if message.length > 1 && message.end_with?("!") && !%w[!= !~].include?(message)

        nil
      end

      def effect_callback_call?(call, message)
        (call.block || call.arguments.to_a.any? { |arg| arg.to_s.start_with?("&") }) &&
          effect_callback_name?(message) &&
          !effect_lexicon.meta_mids.include?(message)
      end

      def effect_callback_name?(message)
        effect_lexicon.callback_set.include?(message) ||
          message.match?(/\A(with_|around_|on_|before_|after_)/) ||
          message.match?(/_hook\z/)
      end

      def method_object_receiver?(receiver)
        names = effect_lexicon.method_obj_mids.map(&:to_s).map { |name| Regexp.escape(name) }
        return false if names.empty?

        receiver.to_s.match?(/(?:\A|\.)(?:#{names.join("|")})\s*\(/)
      end

      def variable_receiver?(receiver)
        receiver.to_s.match?(/\A(?:[a-z_]\w*|[@$][A-Za-z_]\w*)\z/)
      end

      def ruby_net_receiver?(_receiver)
        false
      end

      def semantic_effect_site_from_call(call, kind, detail)
        SemanticEffectSite.new(
          kind: kind,
          detail: detail,
          file: call.file,
          function: call.function,
          owner: call.owner,
          line: call.line,
          span: call.span
        )
      end

      def semantic_effect_site(document, node, stack, kind, detail)
        SemanticEffectSite.new(
          kind: kind,
          detail: detail,
          file: document.file,
          function: current_function(stack),
          owner: current_owner(document, stack),
          line: line(node),
          span: span(node)
        )
      end
    end

    class TreeSitterAdapter
      def semantic_effect_sites(document)
        syntax_profile(document.language).semantic_effect_sites(document)
      end
    end

    GENERIC_SYSTEM_IO_BARE = %w[print println eprintln printf puts panic].freeze
    COMMON_CALLBACK_SET = %w[transaction synchronize lock with_lock unlock
                             mutex atomic subscribe callback hook].freeze

    GENERIC_SYSTEM_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: [].freeze,
      meta_mids: [].freeze,
      method_obj_mids: [].freeze,
      io_consts: [].freeze,
      io_bare: GENERIC_SYSTEM_IO_BARE,
      dir_context: [].freeze,
      context_pairs: {}.freeze,
      context_bare: [].freeze,
      callback_set: [].freeze,
      core_consts: [].freeze
    ).freeze

    PYTHON_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[getattr setattr hasattr __getattr__ __setattr__ import_module].freeze,
      meta_mids: %w[eval exec compile type globals locals vars setattr delattr].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[Path pathlib os sys subprocess socket shutil].freeze,
      io_bare: %w[print input open exec eval].freeze,
      dir_context: %w[getcwd home].freeze,
      context_pairs: {
        "time" => %w[time monotonic perf_counter],
        "datetime" => %w[now today utcnow],
        "random" => %w[random randint randrange choice]
      }.freeze,
      context_bare: %w[random randint randrange].freeze,
      callback_set: COMMON_CALLBACK_SET,
      core_consts: [].freeze
    ).freeze

    JAVASCRIPT_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[eval Function call apply bind].freeze,
      meta_mids: %w[eval Function defineProperty defineProperties setPrototypeOf].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[console Console fs process Deno Bun].freeze,
      io_bare: %w[setTimeout setInterval fetch require import].freeze,
      dir_context: [].freeze,
      context_pairs: {
        "Date" => %w[now],
        "Math" => %w[random],
        "performance" => %w[now]
      }.freeze,
      context_bare: [].freeze,
      callback_set: COMMON_CALLBACK_SET,
      core_consts: [].freeze
    ).freeze

    GO_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[Call CallSlice Method MethodByName ValueOf TypeOf].freeze,
      meta_mids: %w[Call CallSlice MethodByName New MakeFunc].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[os io ioutil fs net http exec syscall].freeze,
      io_bare: %w[panic print println recover].freeze,
      dir_context: %w[Getwd UserHomeDir].freeze,
      context_pairs: {
        "time" => %w[Now Since Until],
        "rand" => %w[Int Intn Float64 Read]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[Lock Unlock RLock RUnlock Do Go Add Done Wait]).freeze,
      core_consts: [].freeze
    ).freeze

    RUST_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[downcast downcast_ref downcast_mut call call_mut call_once].freeze,
      meta_mids: %w[transmute from_raw_parts from_raw_parts_mut].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[std tokio fs env process net io].freeze,
      io_bare: %w[panic todo unimplemented unreachable].freeze,
      dir_context: %w[current_dir home_dir].freeze,
      context_pairs: {
        "SystemTime" => %w[now],
        "Instant" => %w[now]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[read write spawn await]).freeze,
      core_consts: [].freeze
    ).freeze

    ZIG_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[field fieldParentPtr ptrCast alignCast call].freeze,
      meta_mids: %w[typeInfo TypeOf ptrCast intFromPtr ptrFromInt eval].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[std os fs process net Thread Mutex Atomic].freeze,
      io_bare: %w[panic unreachable].freeze,
      dir_context: [].freeze,
      context_pairs: {
        "time" => %w[timestamp nanoTimestamp milliTimestamp]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[spawn wait signal]).freeze,
      core_consts: [].freeze
    ).freeze

    LUA_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[load loadfile dofile require rawget rawset].freeze,
      meta_mids: %w[setmetatable getmetatable debug eval load loadfile].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[io os debug package].freeze,
      io_bare: %w[print error assert require collectgarbage].freeze,
      dir_context: [].freeze,
      context_pairs: {
        "os" => %w[time clock date getenv],
        "math" => %w[random]
      }.freeze,
      context_bare: [].freeze,
      callback_set: COMMON_CALLBACK_SET,
      core_consts: [].freeze
    ).freeze

    C_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[dlsym dlopen GetProcAddress].freeze,
      meta_mids: %w[setjmp longjmp va_start va_arg].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[FILE DIR pthread mutex atomic].freeze,
      io_bare: %w[printf fprintf fopen open read write close system exec abort exit assert].freeze,
      dir_context: %w[getcwd getenv].freeze,
      context_pairs: {}.freeze,
      context_bare: %w[rand time clock].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[pthread_mutex_lock pthread_mutex_unlock]).freeze,
      core_consts: [].freeze
    ).freeze

    CPP_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[dynamic_cast typeid any_cast get_if visit invoke].freeze,
      meta_mids: %w[reinterpret_cast const_cast dlsym dlopen].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[std filesystem fstream iostream thread mutex atomic].freeze,
      io_bare: %w[throw abort exit assert system].freeze,
      dir_context: %w[current_path].freeze,
      context_pairs: {
        "chrono" => %w[now],
        "random_device" => %w[operator()]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[try_lock wait notify_one notify_all]).freeze,
      core_consts: [].freeze
    ).freeze

    CSHARP_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[Invoke GetMethod GetProperty GetField Activator CreateInstance].freeze,
      meta_mids: %w[Invoke GetType Reflection Emit DynamicMethod].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[Console File Directory Path Process Socket HttpClient Environment].freeze,
      io_bare: %w[throw].freeze,
      dir_context: %w[CurrentDirectory GetEnvironmentVariable].freeze,
      context_pairs: {
        "DateTime" => %w[Now UtcNow Today],
        "Guid" => %w[NewGuid],
        "Random" => %w[Next NextDouble]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[Lock Monitor Enter Exit Wait Pulse]).freeze,
      core_consts: [].freeze
    ).freeze

    JAVA_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[invoke getMethod getDeclaredMethod getField getDeclaredField forName].freeze,
      meta_mids: %w[invoke setAccessible newInstance Proxy].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[System File Files Paths ProcessBuilder Socket HttpClient Thread Lock AtomicReference].freeze,
      io_bare: %w[throw].freeze,
      dir_context: %w[getProperty getenv].freeze,
      context_pairs: {
        "System" => %w[currentTimeMillis nanoTime getenv getProperty],
        "Instant" => %w[now],
        "UUID" => %w[randomUUID],
        "Math" => %w[random]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[wait notify notifyAll submit execute]).freeze,
      core_consts: [].freeze
    ).freeze

    SWIFT_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[perform value setValue selector NSClassFromString].freeze,
      meta_mids: %w[Mirror unsafeBitCast withUnsafePointer withUnsafeBytes].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[FileManager Process URLSession DispatchQueue Thread Lock NSLock].freeze,
      io_bare: %w[print fatalError preconditionFailure assertionFailure].freeze,
      dir_context: %w[currentDirectoryPath homeDirectoryForCurrentUser].freeze,
      context_pairs: {
        "Date" => %w[now],
        "UUID" => %w[init]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[async sync]).freeze,
      core_consts: [].freeze
    ).freeze

    KOTLIN_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[invoke call callBy memberProperties declaredMemberFunctions].freeze,
      meta_mids: %w[reflection javaClass Class forName setAccessible].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[System File Files Paths ProcessBuilder Socket HttpClient Thread Mutex AtomicReference].freeze,
      io_bare: %w[println print error check require TODO].freeze,
      dir_context: %w[getProperty getenv].freeze,
      context_pairs: {
        "System" => %w[currentTimeMillis nanoTime getenv getProperty],
        "Instant" => %w[now],
        "UUID" => %w[randomUUID],
        "Random" => %w[nextInt nextLong nextDouble]
      }.freeze,
      context_bare: [].freeze,
      callback_set: (COMMON_CALLBACK_SET + %w[synchronized launch async await]).freeze,
      core_consts: [].freeze
    ).freeze

    PHP_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[call_user_func call_user_func_array __call __callStatic].freeze,
      meta_mids: %w[eval ReflectionClass ReflectionMethod ReflectionFunction class_alias].freeze,
      method_obj_mids: %w[Closure fromCallable].freeze,
      io_consts: %w[FilesystemIterator DirectoryIterator PDO mysqli].freeze,
      io_bare: %w[print printf fopen file_get_contents file_put_contents exec shell_exec system passthru die exit trigger_error].freeze,
      dir_context: %w[getcwd getenv].freeze,
      context_pairs: {
        "DateTime" => %w[createFromFormat],
        "DateTimeImmutable" => %w[createFromFormat],
        "random_int" => %w[call]
      }.freeze,
      context_bare: %w[time microtime random_int rand mt_rand].freeze,
      callback_set: COMMON_CALLBACK_SET,
      core_consts: [].freeze
    ).freeze

    class TreeSitterLanguageAdapter
      private

      def effect_lexicon
        GENERIC_SYSTEM_EFFECT_LEXICON
      end
    end

    class RustSyntaxAdapter
      private

      def effect_lexicon
        RUST_EFFECT_LEXICON
      end
    end

    class ZigSyntaxAdapter
      private

      def effect_lexicon
        ZIG_EFFECT_LEXICON
      end
    end

    class PythonSyntaxAdapter
      private

      def effect_lexicon
        PYTHON_EFFECT_LEXICON
      end
    end

    class JavaScriptSyntaxAdapter
      private

      def effect_lexicon
        JAVASCRIPT_EFFECT_LEXICON
      end
    end

    class TypeScriptSyntaxAdapter
      private

      def effect_lexicon
        JAVASCRIPT_EFFECT_LEXICON
      end
    end

    class GoSyntaxAdapter
      private

      def effect_lexicon
        GO_EFFECT_LEXICON
      end
    end

    class LuaSyntaxAdapter
      private

      def effect_lexicon
        LUA_EFFECT_LEXICON
      end
    end

    class CSyntaxAdapter
      private

      def effect_lexicon
        C_EFFECT_LEXICON
      end
    end

    class CppSyntaxAdapter
      private

      def effect_lexicon
        CPP_EFFECT_LEXICON
      end
    end

    class CSharpSyntaxAdapter
      private

      def effect_lexicon
        CSHARP_EFFECT_LEXICON
      end
    end

    class JavaSyntaxAdapter
      private

      def effect_lexicon
        JAVA_EFFECT_LEXICON
      end
    end

    class SwiftSyntaxAdapter
      private

      def effect_lexicon
        SWIFT_EFFECT_LEXICON
      end
    end

    class KotlinSyntaxAdapter
      private

      def effect_lexicon
        KOTLIN_EFFECT_LEXICON
      end
    end

    class PhpSyntaxAdapter
      private

      def effect_lexicon
        PHP_EFFECT_LEXICON
      end
    end
  end
end

require_relative "ruby_effects"
