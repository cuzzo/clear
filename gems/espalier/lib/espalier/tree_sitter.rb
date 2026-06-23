# frozen_string_literal: true

require "rbconfig"
require_relative "type_profile"

module Espalier
  module TreeSitter
    module_function

    def supported_exts(parser: "tree_sitter")
      FactMine::Syntax.supported_exts(parser: parser)
    end

    def language_for(path)
      FactMine::Syntax.language_for(path)
    end

    def parser_for(language)
      gem "tree_sitter", "~> 0.1"
      require "tree_sitter"

      lang_str = language.to_s.downcase
      lang_name = case lang_str
                  when "ruby" then "ruby"
                  when "python" then "python"
                  when "javascript" then "javascript"
                  when "typescript" then "typescript"
                  when "go" then "go"
                  when "rust" then "rust"
                  when "zig" then "zig"
                  when "c" then "c"
                  when "cpp" then "cpp"
                  when "csharp" then "c_sharp"
                  when "kotlin" then "kotlin"
                  else lang_str
                  end

      pkg_name = case lang_name
                 when "c_sharp" then "tree-sitter-c-sharp"
                 when "zig", "lua" then "@tree-sitter-grammars/tree-sitter-#{lang_name}"
                 else "tree-sitter-#{lang_name}"
                 end

      roots = [
        File.expand_path("../../../node_modules/#{pkg_name}", __dir__),
        File.expand_path("../../../../node_modules/#{pkg_name}", __dir__),
        File.expand_path("../../../../../node_modules/#{pkg_name}", __dir__)
      ]

      os = case RbConfig::CONFIG["host_os"]
           when /linux/i then "linux"
           when /darwin/i then "darwin"
           when /mswin|mingw|cygwin/i then "win32"
           end
      arch = case RbConfig::CONFIG["host_cpu"]
             when /x86_64|amd64/i then "x64"
             when /aarch64|arm64/i then "arm64"
             end

      stem = lang_name.tr("_", "-")
      
      names = [
        "#{stem}.so", "tree-sitter-#{stem}.so", "libtree-sitter-#{stem}.so",
        "#{stem}.node", "tree-sitter-#{stem}.node",
        "#{stem}_binding.node", "tree_sitter_#{lang_name}_binding.node"
      ]

      found_path = nil
      roots.each do |root|
        if os && arch
          prebuild_glob = File.join(root, "prebuilds", "#{os}-#{arch}", "*")
          prebuilds = Dir.glob(prebuild_glob).select { |p| File.file?(p) }
          found_path = prebuilds.first
          break if found_path
        end

        names.each do |name|
          p = File.join(root, name)
          if File.file?(p)
            found_path = p
            break
          end

          p2 = File.join(root, "build", "Release", name)
          if File.file?(p2)
            found_path = p2
            break
          end
        end
        break if found_path
      end

      env_var = "DECOMPLEX_TS_#{language.to_s.upcase}_PATH"
      found_path ||= ENV[env_var] if ENV[env_var] && File.file?(ENV[env_var])

      raise "Missing Tree-sitter grammar for #{language} (resolved as #{lang_name}). Roots checked: #{roots.join(', ')}" unless found_path

      @registered ||= {}
      unless @registered[lang_name]
        ::TreeSitter.register_language(lang_name, found_path)
        @registered[lang_name] = true
      end

      ::TreeSitter::Parser.new.tap { |parser| parser.language = lang_name }
    end
  end
end
