require_relative 'recorder'

module Puck
  # External instrumentation for v1-v7's compilation pipeline. All hooks
  # attach at runtime to classes the version's files defined; nothing in
  # examples/puck/v*/ is modified.
  #
  # Two mechanisms are used:
  #
  # 1. TracePoint (read-only) for parser and compiler method entry/exit and
  #    `consume`. The Ruby interpreter fires these without our classes being
  #    aware.
  #
  # 2. Singleton-class `prepend` on AstNode / ExprNode / ByteCode `.new`, plus
  #    instance-side `prepend` on `ByteCode#arg=` for patch detection. These
  #    insert a module into the runtime ancestor chain; source files are
  #    untouched. The hook is a no-op when no Recorder is active, so the
  #    classes remain usable from `run.rb` or direct `ruby v3/vm.rb` runs.
  module Instrumenter
    @recorder = nil
    @hooked = {}

    class << self
      # Run `block` with the given recorder active. Installs hooks on the
      # currently-loaded version's classes (the caller is expected to have
      # called Puck::VersionLoader.load_version first).
      def with_recorder(recorder)
        install_class_hooks
        previous = @recorder
        previous_node = @current_compile_node
        @recorder = recorder
        @current_compile_node = nil
        tps = build_tracepoints
        tps.each(&:enable)
        yield
      ensure
        tps&.each(&:disable)
        @recorder = previous
        @current_compile_node = previous_node
      end

      def notify_node_built(node)
        @recorder&.record_node_built(node)
      end

      def notify_bytecode_new(bc)
        @recorder&.record_bytecode_new(bc, @current_compile_node)
      end

      def notify_bytecode_patch(bc, new_value)
        @recorder&.record_bytecode_patch(bc, new_value)
      end

      private

      def install_class_hooks
        install_new_hook(AstNode) if defined?(AstNode)
        install_new_hook(ExprNode) if defined?(ExprNode)
        install_bytecode_hooks(ByteCode) if defined?(ByteCode)
      end

      def install_new_hook(klass)
        key = [:new_node, klass.object_id]
        return if @hooked[key]
        klass.singleton_class.prepend(NodeNewTracer)
        @hooked[key] = true
      end

      def install_bytecode_hooks(klass)
        key = [:bytecode, klass.object_id]
        return if @hooked[key]
        klass.singleton_class.prepend(BytecodeNewTracer)
        klass.prepend(BytecodeArgSetter)
        @hooked[key] = true
      end

      def build_tracepoints
        parser_class = defined?(Parser) ? Parser : nil
        compiler_class = defined?(Compiler) ? Compiler : nil
        return [] unless parser_class || compiler_class

        [
          TracePoint.new(:call) do |tp|
            cls = tp.defined_class
            mid = tp.method_id
            if parser_class && cls == parser_class
              if mid.to_s.start_with?("parse")
                pos = read_ivar(tp, :@pos) || 0
                @recorder&.record_parse_enter(mid, pos)
              end
            elsif compiler_class && cls == compiler_class
              if mid.to_s.start_with?("compile")
                node = extract_first_arg(tp)
                @current_compile_node = node if structured_ast?(node)
                @recorder&.record_compile_enter(mid, node)
              end
            end
          end,

          TracePoint.new(:return) do |tp|
            cls = tp.defined_class
            mid = tp.method_id
            if parser_class && cls == parser_class
              if mid == :consume
                pos = read_ivar(tp, :@pos) || 0
                @recorder&.record_consume(pos - 1, tp.return_value)
              elsif mid.to_s.start_with?("parse")
                pos = read_ivar(tp, :@pos) || 0
                @recorder&.record_parse_exit(mid, pos)
              end
            elsif compiler_class && cls == compiler_class
              if mid.to_s.start_with?("compile")
                node = extract_first_arg(tp)
                @recorder&.record_compile_exit(mid, node)
              end
            end
          end,

          # Per-statement attribution. Several versions' compilers loop with
          # `ast.each do |node|` (no per-statement method call), so :call
          # events alone don't tell us which AST node produced which emit.
          # We watch :line events inside compiler methods and capture the
          # current `node` block-local as the active compile target.
          TracePoint.new(:line) do |tp|
            next unless compiler_class && tp.defined_class == compiler_class
            node = read_local(tp, :node) || read_local(tp, :stmt)
            @current_compile_node = node if structured_ast?(node)
          end
        ]
      end

      # AstNode and ExprNode are Structs with .type; reject Arrays and other
      # non-AST values that the local `node` might temporarily hold.
      def structured_ast?(v)
        v.respond_to?(:type) && v.respond_to?(:members)
      end

      def read_local(tp, name)
        tp.binding.local_variable_get(name)
      rescue NameError, StandardError
        nil
      end

      def read_ivar(tp, name)
        tp.self.instance_variable_get(name)
      rescue StandardError
        nil
      end

      def extract_first_arg(tp)
        params = tp.parameters
        return nil if params.nil? || params.empty?
        name = params.first.last
        return nil if name.nil?
        tp.binding.local_variable_get(name)
      rescue StandardError
        nil
      end
    end

    module NodeNewTracer
      def new(*args, **kwargs)
        node = super
        Puck::Instrumenter.notify_node_built(node)
        node
      end
    end

    module BytecodeNewTracer
      def new(*args, **kwargs)
        bc = super
        Puck::Instrumenter.notify_bytecode_new(bc)
        bc
      end
    end

    module BytecodeArgSetter
      def arg=(value)
        Puck::Instrumenter.notify_bytecode_patch(self, value)
        super
      end
    end
  end
end
