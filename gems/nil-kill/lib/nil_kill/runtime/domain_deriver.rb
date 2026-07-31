# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    # Turning what the collector saw into the rows the pipeline reads.
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

        call("nil-kill-derive-domains", root: root, source_roles: source_roles) do |args|
          documents.each { |path| args.concat(["--input", path]) }
        end
      end

      # Shaping the documents into rows: the same inputs, the same non-production
      # roles, and no VM needed for either.
      def self.export(runtime_dirs:, plan:, source_roles:, root:)
        return if runtime_dirs.empty?

        call("nil-kill-collector-export", root: root, source_roles: source_roles) do |args|
          args.concat(["--plan", plan.to_s]) if plan && File.file?(plan.to_s)
          runtime_dirs.each { |dir| args.concat(["--runtime-dir", dir.to_s]) }
        end
      end

      # The document a shard adds up to. Minting a protocol value from an
      # observed one needs the traced language's own type-symbol rules, and the
      # shard's own document reports which runtime observed it.
      def self.trace_documents(runtime_dirs:, plan:, root:)
        return if runtime_dirs.empty?

        call("nil-kill-trace-document", root: root, source_roles: nil) do |args|
          args.concat(["--plan", plan.to_s])
          runtime_dirs.each { |dir| args.concat(["--runtime-dir", dir.to_s]) }
        end
      end

      # Merging shards into one canonical document. A shard contributes what it
      # observed, so shards legitimately cover different anchors; the rules for
      # reconciling them are the same rules the join already applies.
      def self.merge_evidence(inputs:, output:, plan: nil)
        binary = NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY
        args = [binary, "nil-kill-merge-evidence", "--output", output.to_s]
        args.concat(["--plan", plan.to_s]) if plan
        inputs.each { |path| args.concat(["--input", path.to_s]) }
        _out, err, status = Open3.capture3(*args)
        raise "fact-mine nil-kill-merge-evidence failed: #{err}" unless status.success?

        output.to_s
      end

      # Which functions each shard exercised and which callsites it reached --
      # what an incremental collect reruns a shard on.
      def self.shard_bookkeeping(inventory:, shard_dirs:, root:)
        return {} if shard_dirs.empty?

        Tempfile.create(["nil-kill-inventory", ".json"]) do |written|
          written.write(JSON.generate(inventory))
          written.flush
          Tempfile.create(["nil-kill-bookkeeping", ".json"]) do |out|
            args = [NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY,
                    "nil-kill-shard-bookkeeping", "--inventory", written.path,
                    "--output", out.path, "--root", root.to_s]
            shard_dirs.each { |dir| args.concat(["--shard", dir.to_s]) }
            _stdout, err, status = Open3.capture3(*args)
            raise "fact-mine nil-kill-shard-bookkeeping failed: #{err}" unless status.success?

            JSON.parse(File.read(out.path))
          end
        end
      end

      # One traced program per shard, several at a time. Their output is the
      # workload's own, so it goes straight to the terminal; only the names of
      # the shards that failed come back.
      def self.run_shards(shards:, jobs:, continue_on_error:, banner:)
        return [] if shards.empty?

        Tempfile.create(["nil-kill-shards", ".json"]) do |plan|
          plan.write(JSON.generate(
            "shards" => shards, "jobs" => jobs,
            "continue_on_error" => continue_on_error, "banner" => banner
          ))
          plan.flush
          Tempfile.create(["nil-kill-shard-failures", ".json"]) do |out|
            system(
              NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY, "nil-kill-run-shards",
              "--plan", plan.path, "--output", out.path
            )
            contents = File.read(out.path)
            contents.empty? ? [] : JSON.parse(contents).fetch("failed", [])
          end
        end
      end

      def self.call(subcommand, root:, source_roles:)
        args = [NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY, subcommand,
                "--root", root.to_s]
        args.concat(["--source-roles", source_roles.to_s]) if source_roles
        yield args
        _out, err, status = Open3.capture3(*args)
        raise "fact-mine #{subcommand} failed: #{err}" unless status.success?
      end
    end
  end
end
