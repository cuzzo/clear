# typed: false
# frozen_string_literal: true

require "digest"

module NilKill
  module Runtime
    # What the runtime was when it observed something. Two places need to say
    # this and they must say the same thing: the collector, writing its trace
    # from inside the traced program, and the provider, answering for the
    # repository from outside it. A trace whose claims disagree with the
    # provider's is rejected at merge, so the claims cannot live in only one of
    # them. Kept to the standard library, because the collector is loaded into
    # arbitrary user programs via RUBYOPT where nothing else is guaranteed.
    module EnvironmentClaims
      module_function

      def ruby(root:)
        claims = {
          "runtime.language" => "ruby",
          "runtime.version" => RUBY_VERSION,
          "runtime.engine" => RUBY_ENGINE,
          "runtime.engine_version" => RUBY_ENGINE_VERSION,
        }
        lockfile = File.join(root.to_s, "Gemfile.lock")
        if File.file?(lockfile)
          claims["runtime.lockfile.Gemfile.lock.sha256"] =
            "sha256:#{Digest::SHA256.file(lockfile).hexdigest}"
        end
        claims
      end

      def ruby_provenance
        {
          "provider" => "ruby-tracepoint",
          "provider_version" => "1",
        }
      end
    end
  end
end
