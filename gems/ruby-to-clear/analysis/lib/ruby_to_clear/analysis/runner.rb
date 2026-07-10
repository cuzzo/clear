# frozen_string_literal: true

require "fileutils"
require "timeout"

module RubyToClear
  module Analysis
    class Runner
      TAIL_BYTES = 256 * 1024

      def run(argv, stdout_path:, stderr_path:, timeout_seconds:, chdir: nil, env: {})
        FileUtils.mkdir_p(File.dirname(stdout_path))
        FileUtils.mkdir_p(File.dirname(stderr_path))
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        pid = nil
        status = nil
        timed_out = false

        File.open(stdout_path, "wb") do |stdout|
          File.open(stderr_path, "wb") do |stderr|
            pid = Process.spawn(env, *argv, out: stdout, err: stderr, chdir: chdir, pgroup: true)
            begin
              Timeout.timeout(timeout_seconds) { _waited_pid, status = Process.wait2(pid) }
            rescue Timeout::Error
              timed_out = true
              terminate_group(pid)
              _waited_pid, status = Process.wait2(pid)
            end
          end
        end

        {
          "argv" => argv,
          "chdir" => chdir,
          "exit_status" => status&.exitstatus,
          "term_signal" => status&.termsig,
          "timed_out" => timed_out,
          "success" => !timed_out && status&.success? == true,
          "duration_seconds" => elapsed(started),
          "stdout_path" => stdout_path,
          "stderr_path" => stderr_path
        }
      rescue SystemCallError => e
        {
          "argv" => argv,
          "chdir" => chdir,
          "exit_status" => nil,
          "term_signal" => nil,
          "timed_out" => false,
          "success" => false,
          "duration_seconds" => elapsed(started),
          "stdout_path" => stdout_path,
          "stderr_path" => stderr_path,
          "harness_error" => "#{e.class}: #{e.message}"
        }
      end

      def diagnostic_text(result)
        paths = [result["stderr_path"], result["stdout_path"]]
        text = paths.filter_map { |path| tail(path) }.reject(&:empty?).join("\n")
        harness_error = result["harness_error"]
        harness_error ? "#{harness_error}\n#{text}" : text
      end

      private

      def terminate_group(pid)
        Process.kill("TERM", -pid)
        sleep 0.25
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end

      def tail(path)
        return unless path && File.file?(path)

        File.open(path, "rb") do |file|
          file.seek(-TAIL_BYTES, IO::SEEK_END) if file.size > TAIL_BYTES
          file.read
        end
      end

      def elapsed(started)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
      end
    end
  end
end
