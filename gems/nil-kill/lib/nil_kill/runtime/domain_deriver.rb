# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    # Turning what the collector saw into value domains.
    #
    # The traced program reports the answers only an interpreter can give --
    # this object's class, a sample of its container, a record's fields, the
    # file its class was declared in -- and stops. What counts as a shape, when
    # two collections are the same shape, and which names are test-only is the
    # same arithmetic whatever language was traced, so FactMine owns it and
    # every language's shim is spared reimplementing it.
    module DomainDeriver
      def self.run(documents:, source_roles:, root:)
        return if documents.empty?

        binary = NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY
        args = [binary, "nil-kill-derive-domains", "--root", root.to_s]
        args.concat(["--source-roles", source_roles.to_s]) if source_roles
        documents.each { |path| args.concat(["--input", path]) }
        _out, err, status = Open3.capture3(*args)
        raise "fact-mine nil-kill-derive-domains failed: #{err}" unless status.success?
      end
    end
  end
end
