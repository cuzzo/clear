# typed: false
# frozen_string_literal: true

require_relative "../static_fact_provider"

module NilKill
  module Inference
    module Providers
      class Ruby < StaticFactProvider
        def language
          "ruby"
        end
      end
    end
  end
end
