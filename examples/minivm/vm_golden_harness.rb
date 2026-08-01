# frozen_string_literal: true

# Target-aware helpers for MiniVM golden tests.
#
# The stack bytecode VM is the current implementation. The register target is
# intentionally wired as a pending target so tests can describe both sides of
# the contract before the register emitter/runner exist.

require "open3"
require "tempfile"
require "timeout"
require "fileutils"

src_root = File.expand_path("../../compiler/ruby", __dir__)
$LOAD_PATH.unshift(src_root)
$LOAD_PATH.unshift(File.join(src_root, "ast"))
$LOAD_PATH.unshift(File.join(src_root, "mir"))
$LOAD_PATH.unshift(File.join(src_root, "backends"))
$LOAD_PATH.unshift(File.join(src_root, "annotator-helpers"))

require_relative "register_bc_emitter"
require "compiler/compiler_frontend"
require "compiler/module_importer"
require "mir_checker"
require "mir_lowering"

module MiniVM
  module Golden
    ROOT = File.expand_path("../..", __dir__)
    BC_RUN = File.expand_path("bc_run.rb", __dir__)
    COMPLETION_MARKER = "SCHEME: all expressions completed"
    DEFAULT_RUN_TIMEOUT_SECONDS = Integer(ENV.fetch("MINIVM_GOLDEN_TIMEOUT_SECONDS", "10"))

    class PendingTarget < StandardError; end

    Case = Struct.new(:path, keyword_init: true) do
      def self.all(root = File.join(Golden::ROOT, "examples", "minivm", "vm-tests"))
        Dir.glob(File.join(root, "**", "*.clear")).sort.reject do |path|
          File.basename(path).start_with?("minivm-golden-")
        end.map { |path| new(path: path) }
      end

      def source
        File.read(path)
      end

      def source_dir
        File.dirname(path)
      end

      def relative_path(root = File.join(Golden::ROOT, "examples", "minivm", "vm-tests"))
        path.delete_prefix(File.expand_path(root) + "/")
      end

      def expected_output
        File.read(output_path).strip
      end

      def output_path
        path.sub(/\.clear\z/, ".out")
      end

      def bytecode_snapshot_path(target)
        path.sub(/\.clear\z/, ".#{target}.bc")
      end
    end

    RegisterBytecode = Struct.new(:ops, :consts, keyword_init: true) do
      def snapshot
        parts = ["register instructions:"]
        parts.concat(RegisterDisassembler.new(ops, consts).lines)
        unless consts.empty?
          parts << "consts:"
          parts.concat(consts)
        end
        parts.join("\n")
      end

      def raw_snapshot
        parts = ["ops:", ops.join(",")]
        unless consts.empty?
          parts << "consts:"
          parts.concat(consts)
        end
        parts.join("\n")
      end
    end

    RunResult = Struct.new(:status, :output, :raw_output, :bench_ms, keyword_init: true)

    def self.bench_ms(raw)
      match = raw.to_s.scan(/BENCH_RESULT:\s*(\d+(?:\.\d+)?)\s*ms/).last
      match ? match.first.to_f : nil
    end
    SnapshotResult = Struct.new(:test_case, :target, :path, :status, :message, keyword_init: true)

    class RegisterDisassembler
      SPEC = MiniVM::Register::OpcodeSpec
      OPCODE_NAMES = SPEC::OPCODES.to_h { |op| [op.code, op.name.to_s] }.freeze
      ARITIES = SPEC::FIXED_ARITIES

      CONST_OPS = [
        RegisterBcEmitter::ICONST,
        RegisterBcEmitter::FCONST,
        RegisterBcEmitter::SCONST,
      ].freeze

      def initialize(ops, consts)
        @ops = ops
        @consts = consts
      end

      def lines
        out = []
        ip = 0
        while ip < @ops.length
          opcode = @ops[ip]
          name = OPCODE_NAMES.fetch(opcode, "ROP_#{opcode}")
          arity = if call_opcode?(opcode)
                    5 + (@ops[ip + 3].to_i * 2)
                  elsif opcode == RegisterBcEmitter::NCALL
                    4 + (@ops[ip + 4].to_i * 2)
                  else
                    ARITIES.fetch(opcode) do
            raise "No register bytecode disassembler arity for #{name} (opcode #{opcode}) at ip #{ip}"
                    end
          end
          args = @ops[(ip + 1)..(ip + arity)] || []
          rendered_args = format_args(opcode, args)
          line = format("%04d %-8s", ip, name).rstrip
          line += " #{rendered_args}" unless rendered_args.empty?
          line += const_comment(opcode, args)
          out << line
          ip += 1 + arity
        end
        out
      end

      private

      def call_opcode?(opcode)
        opcode == RegisterBcEmitter::ICALL || opcode == RegisterBcEmitter::FCALL
      end

      def format_args(opcode, args)
        case opcode
        when RegisterBcEmitter::ICONST
          "r#{args[0]} #{args[1]}"
        when RegisterBcEmitter::FCONST
          "f#{args[0]} #{args[1]}"
        when RegisterBcEmitter::SCONST
          "s#{args[0]} #{args[1]}"
        when RegisterBcEmitter::IRET
          "r#{args[0]}"
        when RegisterBcEmitter::FRET
          "f#{args[0]}"
        when RegisterBcEmitter::SRET
          "s#{args[0]}"
        when RegisterBcEmitter::IMOV
          "r#{args[0]} r#{args[1]}"
        when RegisterBcEmitter::FMOV
          "f#{args[0]} f#{args[1]}"
        when RegisterBcEmitter::SMOV
          "s#{args[0]} s#{args[1]}"
        when RegisterBcEmitter::IADD,
             RegisterBcEmitter::ISUB,
             RegisterBcEmitter::IMUL,
             RegisterBcEmitter::IDIV,
             RegisterBcEmitter::IMOD,
             RegisterBcEmitter::ILT,
             RegisterBcEmitter::IGT,
             RegisterBcEmitter::IEQ,
             RegisterBcEmitter::INEQ,
             RegisterBcEmitter::ILTE,
             RegisterBcEmitter::IGTE
          "r#{args[0]} r#{args[1]} r#{args[2]}"
        when RegisterBcEmitter::FADD,
             RegisterBcEmitter::FSUB,
             RegisterBcEmitter::FMUL,
             RegisterBcEmitter::FDIV
          "f#{args[0]} f#{args[1]} f#{args[2]}"
        when RegisterBcEmitter::SCONCAT
          "s#{args[0]} s#{args[1]} s#{args[2]}"
        when RegisterBcEmitter::LNEW
          "v#{args[0]}"
        when RegisterBcEmitter::LAPPENDI
          "v#{args[0]} r#{args[1]}"
        when RegisterBcEmitter::LGETI
          "r#{args[0]} v#{args[1]} r#{args[2]}"
        when RegisterBcEmitter::LLEN
          "r#{args[0]} v#{args[1]}"
        when RegisterBcEmitter::MNEW
          "m#{args[0]}"
        when RegisterBcEmitter::MPUTI
          "m#{args[0]} #{args[1]} r#{args[2]}"
        when RegisterBcEmitter::MGETI
          "r#{args[0]} m#{args[1]} #{args[2]} r#{args[3]}"
        when RegisterBcEmitter::NMPUTI
          "m#{args[0]} r#{args[1]} r#{args[2]}"
        when RegisterBcEmitter::NMGETI
          "r#{args[0]} m#{args[1]} r#{args[2]} r#{args[3]}"
        when RegisterBcEmitter::NMCONTAINS
          "r#{args[0]} m#{args[1]} r#{args[2]}"
        when RegisterBcEmitter::NMDELETE
          "m#{args[0]} r#{args[1]}"
        when RegisterBcEmitter::NMNEW
          "m#{args[0]}"
        when RegisterBcEmitter::NMLEN
          "r#{args[0]} m#{args[1]}"
        when RegisterBcEmitter::LFNEW
          "v#{args[0]}"
        when RegisterBcEmitter::LFAPPEND
          "v#{args[0]} f#{args[1]}"
        when RegisterBcEmitter::LFGET
          "f#{args[0]} v#{args[1]} r#{args[2]}"
        when RegisterBcEmitter::SEQ
          "r#{args[0]} s#{args[1]} s#{args[2]}"
        when RegisterBcEmitter::LSETI
          "v#{args[0]} r#{args[1]} r#{args[2]}"
        when RegisterBcEmitter::FLT,
             RegisterBcEmitter::FGT,
             RegisterBcEmitter::FEQ,
             RegisterBcEmitter::FNEQ,
             RegisterBcEmitter::FLTE,
             RegisterBcEmitter::FGTE
          "r#{args[0]} f#{args[1]} f#{args[2]}"
        when RegisterBcEmitter::JMP
          args[0].to_s
        when RegisterBcEmitter::JF
          "r#{args[0]} #{args[1]}"
        when RegisterBcEmitter::JILTF,
             RegisterBcEmitter::JIGTF,
             RegisterBcEmitter::JIEQF,
             RegisterBcEmitter::JINEQF,
             RegisterBcEmitter::JILTEF,
             RegisterBcEmitter::JIGTEF
          "r#{args[0]} r#{args[1]} #{args[2]}"
        when RegisterBcEmitter::JFLTF,
             RegisterBcEmitter::JFGTF,
             RegisterBcEmitter::JFEQF,
             RegisterBcEmitter::JFNEQF,
             RegisterBcEmitter::JFLTEF,
             RegisterBcEmitter::JFGTEF
          "f#{args[0]} f#{args[1]} #{args[2]}"
        when RegisterBcEmitter::ICALL
          fixed = "r#{args[0]} #{args[1]} argc=#{args[2]} iframe=#{args[3]} fframe=#{args[4]}"
          ([fixed] + format_typed_call_args(args[5..] || [])).join(" ")
        when RegisterBcEmitter::FCALL
          fixed = "f#{args[0]} #{args[1]} argc=#{args[2]} iframe=#{args[3]} fframe=#{args[4]}"
          ([fixed] + format_typed_call_args(args[5..] || [])).join(" ")
        when RegisterBcEmitter::NCALL
          fixed = "#{ret_kind_name(args[0])} #{format_ret_reg(args[0], args[1])} #{native_name(args[2])} argc=#{args[3]}"
          ([fixed] + format_typed_call_args(args[4..] || [])).join(" ")
        when RegisterBcEmitter::IPRINT
          "#{args[0]} r#{args[1]} #{args[2]}"
        when RegisterBcEmitter::IPRINT2
          "#{args[0]} r#{args[1]} #{args[2]} r#{args[3]} #{args[4]}"
        else
          args.join(" ")
        end
      end

      def format_typed_call_args(args)
        args.each_slice(2).map do |kind, reg|
          case kind
          when RegisterBcEmitter::ARG_F then "f#{reg}"
          when RegisterBcEmitter::ARG_S then "s#{reg}"
          else "r#{reg}"
          end
        end
      end

      def format_ret_reg(ret_kind, reg)
        case ret_kind
        when RegisterBcEmitter::RET_F then "f#{reg}"
        when RegisterBcEmitter::RET_S then "s#{reg}"
        when RegisterBcEmitter::RET_VOID then "_"
        else "r#{reg}"
        end
      end

      def ret_kind_name(ret_kind)
        case ret_kind
        when RegisterBcEmitter::RET_F then "ret=f64"
        when RegisterBcEmitter::RET_S then "ret=string"
        when RegisterBcEmitter::RET_VOID then "ret=void"
        else "ret=i64"
        end
      end

      def native_name(native_id)
        {
          RegisterBcEmitter::N_TIMESTAMP_MS => "timestampMs",
          RegisterBcEmitter::N_RANDOM => "random",
          RegisterBcEmitter::N_RANDOM_INT => "randomInt",
          RegisterBcEmitter::N_INT_TO_STRING => "Int64.toString",
          RegisterBcEmitter::N_STRING_LENGTH => "String.length",
          RegisterBcEmitter::N_STRING_STARTS_WITH => "startsWith?",
          RegisterBcEmitter::N_STRING_CONTAINS => "String.contains?",
          RegisterBcEmitter::N_STRING_CHAR_AT => "charAt",
          RegisterBcEmitter::N_STRING_SUBSTR => "substr",
          RegisterBcEmitter::N_STRING_TO_NUMBER_OR => "toNumberOr",
          RegisterBcEmitter::N_FLOAT_TO_INT => "toInt",
          RegisterBcEmitter::N_INT_TO_FLOAT => "toFloat",
          RegisterBcEmitter::N_STRING_REPLACE => "replace",
          RegisterBcEmitter::N_STRING_LOWERCASE => "lowercase",
          RegisterBcEmitter::N_STRING_UPPERCASE => "uppercase",
        }.fetch(native_id, "native_#{native_id}")
      end

      def const_comment(opcode, args)
        return "" unless CONST_OPS.include?(opcode)
        const = @consts[args[1]]
        const ? " ; #{const}" : ""
      end
    end

    class RegisterTarget
      attr_reader :name

      def initialize
        @name = :register
      end

      def compile(source, source_dir: Dir.pwd)
        source_dir = File.expand_path(source_dir)
        importer = ModuleImporter.new(base_dir: source_dir)
        fe_result = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
        lowering = MIRLowering.new(input: MIRLoweringInput.new(
          struct_schemas: fe_result.struct_schemas,
          enum_schemas: fe_result.enum_schemas,
          union_schemas: fe_result.union_schemas,
          lifecycle_registry: fe_result.lifecycle_registry,
          fn_sigs: fe_result.fn_sigs,
          moved_guard_info: fe_result.moved_guard_info,
          importer: importer,
          source_dir: source_dir,
          target: :bc
        ))
        program = lowering.lower_program(fe_result.ast)
        mir_errors = MIRChecker.new.check_program!(program, strict: true)
        raise "MIR validation errors: #{mir_errors.first}" unless mir_errors.nil? || mir_errors.empty?

        emitter = RegisterBcEmitter.new(fe_result, source: source, importer: importer)
        compiled = emitter.compile(program)
        RegisterBytecode.new(
          ops: compiled.ops,
          consts: compiled.consts.map { |c| emitter.serialize_const(c) }
        )
      rescue RegisterBcEmitter::Unsupported => e
        raise PendingTarget, e.message
      end

      def run(source, source_dir: Dir.pwd, timeout_seconds: DEFAULT_RUN_TIMEOUT_SECONDS, optimized: false)
        with_source_file(source, source_dir) do |path|
          env = optimized ? { "BC_OPT" => "1" } : {}
          raw, status = Open3.capture2e(env, "timeout", "--kill-after=2", timeout_seconds.to_s, "ruby", BC_RUN, path, "--run", "--vm=register")
          return RunResult.new(status: :timeout, output: "", raw_output: raw, bench_ms: nil) if status.exitstatus == 124

          if status.exitstatus == 2
            message = raw.to_s.sub(/\ARegister VM pending:\s*/, "").strip
            raise PendingTarget, message
          end
          RunResult.new(
            status: status.success? ? :pass : :error,
            output: normalize_output(raw),
            raw_output: raw,
            bench_ms: MiniVM::Golden.bench_ms(raw)
          )
        end
      end

      private

      def with_source_file(source, source_dir)
        Tempfile.create(["minivm-golden-register-", ".clear"], source_dir) do |file|
          file.write(source)
          file.flush
          yield file.path
        end
      end

      def normalize_output(raw)
        clean = raw.to_s.gsub(/\e\[[0-9;]*m/, "")
        lines = clean.lines.reject do |line|
          line.match?(/\A\[(Warning|Note|Info)\]/) ||
            line.include?("Building register vm runner")
        end
        lines.join.strip
      end
    end

    def self.register
      @register ||= RegisterTarget.new
    end

    def self.targets
      { register: register }
    end

    def self.normalize_snapshot(text)
      text.to_s.lines.map(&:rstrip).join("\n").strip
    end

    def self.update_snapshots(root: File.join(ROOT, "examples", "minivm", "vm-tests"), targets: [:register], check: false)
      target_names = Array(targets).map(&:to_sym)
      unknown = target_names - self.targets.keys
      raise ArgumentError, "unknown VM golden target(s): #{unknown.join(", ")}" unless unknown.empty?

      Case.all(root).flat_map do |test_case|
        target_names.map do |target_name|
          path = test_case.bytecode_snapshot_path(target_name)
          begin
            bytecode = self.targets.fetch(target_name).compile(test_case.source, source_dir: test_case.source_dir)
            snapshot = normalize_snapshot(bytecode.snapshot)
            current = File.exist?(path) ? normalize_snapshot(File.read(path)) : nil
            if check
              if current == snapshot
                SnapshotResult.new(test_case: test_case, target: target_name, path: path, status: :unchanged)
              else
                SnapshotResult.new(test_case: test_case, target: target_name, path: path, status: :stale)
              end
            elsif current == snapshot
              SnapshotResult.new(test_case: test_case, target: target_name, path: path, status: :unchanged)
            else
              FileUtils.mkdir_p(File.dirname(path))
              File.write(path, snapshot + "\n")
              SnapshotResult.new(test_case: test_case, target: target_name, path: path, status: :written)
            end
          rescue PendingTarget => e
            SnapshotResult.new(test_case: test_case, target: target_name, path: path, status: :pending, message: e.message)
          rescue => e
            SnapshotResult.new(test_case: test_case, target: target_name, path: path, status: :error, message: e.message)
          end
        end
      end
    end
  end
end
