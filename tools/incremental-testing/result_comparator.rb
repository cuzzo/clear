# typed: strict
# frozen_string_literal: true

require "digest"
require "sorbet-runtime"

module IncrementalTesting
  class Comparison < T::Struct
    const :equal, T::Boolean
    const :incremental_digest, String
    const :clean_digest, String
  end

  class ResultComparator
    extend T::Sig

    sig { params(incremental: String, clean: String).returns(Comparison) }
    def self.compare(incremental, clean)
      Comparison.new(
        equal: incremental == clean,
        incremental_digest: Digest::SHA256.hexdigest(incremental),
        clean_digest: Digest::SHA256.hexdigest(clean),
      )
    end
  end
end
