# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "mutation_corpus"

module TestMiser
  class GithubArtifactStore
    Result = Struct.new(:found, :artifact_id, :corpus, :manifest, keyword_init: true)

    def initialize(repository:, runner: nil)
      @repository = repository
      @runner = runner || method(:capture)
    end

    def restore(commit:, output:)
      name = "test-miser-corpus-#{commit}"
      listing = run_json(
        "gh", "api", "--method", "GET",
        "repos/#{@repository}/actions/artifacts?name=#{name}&per_page=100"
      )
      artifact = Array(listing["artifacts"])
        .reject { |item| item["expired"] == true }
        .select { |item| item["name"] == name }
        .max_by { |item| [item["created_at"].to_s, item.fetch("id").to_i] }
      return Result.new(found: false) unless artifact

      FileUtils.mkdir_p(output)
      Dir.mktmpdir("test-miser-artifact") do |directory|
        zip = File.join(directory, "artifact.zip")
        stdout, stderr, status = @runner.call(
          "gh", "api", "repos/#{@repository}/actions/artifacts/#{artifact.fetch('id')}/zip"
        )
        raise CorpusError, "GitHub artifact download failed: #{stderr}" unless status.success?
        File.binwrite(zip, stdout)
        _stdout, unzip_stderr, unzip_status = @runner.call("unzip", "-q", zip, "-d", directory)
        raise CorpusError, "GitHub artifact unzip failed: #{unzip_stderr}" unless unzip_status.success?

        manifest = Dir[File.join(directory, "**", "manifest.json")].first
        corpus = Dir[File.join(directory, "**", "mutation-corpus.json.zst")].first
        raise CorpusError, "GitHub artifact #{artifact['id']} lacks manifest/corpus" unless manifest && corpus
        verified = MutationCorpus.verify!(corpus_path: corpus, manifest_path: manifest)
        raise CorpusError, "GitHub artifact commit mismatch" unless verified["commit"] == commit
        raise CorpusError, "GitHub artifact repository mismatch" unless verified["repository"] == @repository

        restored_corpus = File.join(output, "mutation-corpus.json.zst")
        restored_manifest = File.join(output, "manifest.json")
        FileUtils.cp(corpus, restored_corpus)
        FileUtils.cp(manifest, restored_manifest)
        return Result.new(
          found: true,
          artifact_id: artifact.fetch("id"),
          corpus: restored_corpus,
          manifest: restored_manifest
        )
      end
    rescue JSON::ParserError => error
      raise CorpusError, "invalid GitHub artifact response: #{error.message}"
    end

    private

    def run_json(*argv)
      stdout, stderr, status = @runner.call(*argv)
      raise CorpusError, "GitHub artifact lookup failed: #{stderr}" unless status.success?
      JSON.parse(stdout)
    end

    def capture(*argv)
      Open3.capture3(*argv)
    end
  end
end
