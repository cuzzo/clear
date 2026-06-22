# typed: false
# frozen_string_literal: true

require_relative "../static_fact_provider"

module NilKill
  module Inference
    module Providers
      class Python < StaticFactProvider
        def language
          "python"
        end
      end
    end
  end
end
