# frozen_string_literal: true

module TestMiser
  module FastMutantFork
    MUTANT_VERSION = "0.15.1"
    POLL_INTERVAL = 0.005

    module_function

    def install
      return unless ::Mutant::VERSION == MUTANT_VERSION

      parent = ::Mutant::Isolation::Fork.const_get(:Parent, false)
      child = ::Mutant::Isolation::Fork.const_get(:Child, false)
      parent.class_eval do
        define_method(:start_child) do
          pid = world.process.fork do
            ::Process.setpgrp
            child.call(
              to_h.merge(
                log_pipe: log_pipe.child,
                result_pipe: result_pipe.child
              )
            )
          end
          begin
            ::Process.setpgid(pid, pid)
          rescue Errno::EACCES, Errno::ESRCH
            # The child either won the race to set its group or already exited.
          end
          pid
        end
        private :start_child

        define_method(:terminate_graceful) do
          status = nil
          loop do
            status = peek_child
            break if status || deadline.expired?

            world.kernel.sleep(TestMiser::FastMutantFork::POLL_INTERVAL)
          end

          status ? handle_status(status) : terminate_ungraceful
        end
        private :terminate_graceful

        define_method(:terminate_ungraceful) do
          begin
            world.process.kill("KILL", -@pid)
          rescue Errno::ESRCH
            world.process.kill("KILL", @pid)
          end

          _pid, status = world.process.wait2(@pid)
          handle_status(status)
        end
        private :terminate_ungraceful
      end
    end
  end
end
