require 'fileutils'
require 'open3'
require 'tmpdir'

require_relative '../ruby/backends/transpiler' unless defined?(ZigTranspiler)
require_relative '../../tools/fuzz/semantic_equivalence'
require_relative '../../transpile-tests/gen' unless defined?(TestGenerator)

RSpec.describe 'semantic equivalence compiler integration', mutant_expression: [
  'ClearParser',
  'MIRLowering',
  'ZigTranspiler'
] do
  def semantic_zig
    candidates = [
      File.join(File.expand_path('~'), 'zig-x86_64-linux-0.16.0', 'zig'),
      File.expand_path('../../zig/zig-new/zig', __dir__),
      File.expand_path('../../zig/zig/zig', __dir__),
    ]
    candidates.find { |path| File.executable?(path) } || 'zig'
  end

  def link_semantic_runtime(build_dir)
    root = File.expand_path('../..', __dir__)
    %w[runtime lib experimental].each do |name|
      File.symlink(File.join(root, 'zig', name), File.join(build_dir, name))
    end
    File.symlink(File.join(root, 'testdata'), File.join(build_dir, 'testdata'))
  end

  it 'preserves the mutation representative set through compatible consumers' do
    parser_path = File.expand_path('../ruby/ast/parser.rb', __dir__)
    # The ordinary fuzz lanes execute all 390 cases. Mutation runs execute this
    # coverage-preserving representative set hundreds of times, once per
    # mutant; bounding it avoids turning slow/pathological mutants into false
    # timeout results while retaining all production/consumer/edge witnesses.
    mutation_limit = Integer(ENV.fetch('SEMANTIC_MUTATION_LIMIT', '148'))
    suite = SemanticEquivalence::Suite.mvp(
      parser_path: parser_path,
      max_depth: 1,
      limit: mutation_limit
    )
    generator = TestGenerator.new

    Dir.mktmpdir('clear-semantic-mutant-') do |build_dir|
      link_semantic_runtime(build_dir)
      zig_path = File.join(build_dir, 'semantic-mutant.zig')
      header = <<~ZIG
        pub const CLEAR_FRAME_DEBUG = false;
        const std = @import("std");
        const CheatHeader = @import("runtime/runtime-header.zig");
        const CheatLib = CheatHeader.CheatLib;
        const Runtime = CheatHeader.Runtime;
        const EbrContext = CheatHeader.EbrContext;
      ZIG
      blocks = suite.cases.map do |item|
        generator.generate_test_block("semantic-#{item.id}.clear", item.source)
      end
      File.write(zig_path, ([header] + blocks).join("\n"))

      format_output, format_status = Open3.capture2e(semantic_zig, 'fmt', zig_path)
      expect(format_status).to be_success, format_output

      output, status = Open3.capture2e(
        semantic_zig,
        'test', 'semantic-mutant.zig', 'runtime/switch.S', 'runtime/onRoot.S', '-lc',
        chdir: build_dir
      )
      expect(status).to be_success, output
    end
  end

  it 'resolves every generated capability to its declared ownership and access facts', mutant: false do
    suite = SemanticEquivalence::CapabilitySuite.new

    suite.cases.each do |item|
      importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
      result = CompilerFrontend.compile(item.source, importer: importer, source_dir: Dir.pwd)
      main = result.ast.statements.find { |statement| statement.is_a?(AST::FunctionDef) && statement.name == 'main' }
      declaration = main.body.find do |statement|
        (statement.is_a?(AST::VarDecl) || statement.is_a?(AST::BindExpr)) && statement.name == 'value'
      end
      capability = suite.capabilities.find { |candidate| candidate.id == item.expected_value.fetch(:capability) }
      resolved = declaration.full_type!

      expect(resolved.ownership).to eq(capability.ownership), item.id
      expect(resolved.sync).to eq(capability.sync), item.id
    end
  end

  it 'resolves each generated value family to its declared full type before MIR', mutant: false do
    parser_path = File.expand_path('../ruby/ast/parser.rb', __dir__)
    suite = SemanticEquivalence::Suite.mvp(parser_path: parser_path, max_depth: 1)
    local_cases = suite.cases.select { |item| item.consumer_id == :local_initializer }

    local_cases.each do |item|
      ast = ClearParser.new(Lexer.new(item.source).tokenize, item.source).parse
      SemanticAnnotator.new(source_code: item.source).annotate!(ast)
      main = ast.statements.find { |statement| statement.is_a?(AST::FunctionDef) && statement.name == 'main' }
      declaration = main.body.find do |statement|
        (statement.is_a?(AST::VarDecl) || statement.is_a?(AST::BindExpr)) && statement.name == 'value'
      end

      expect(declaration).not_to be_nil, item.id
      expect(Type.surface_name(declaration.full_type!)).to eq(item.expected_type), item.id
    end
  end
end
