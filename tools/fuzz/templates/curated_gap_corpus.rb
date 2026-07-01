# Template: existing self-contained transpile-tests that cover broad fuzz gaps.
#
# Coverage-mode fuzzing is compile-only, so these fixtures exercise parser,
# annotator, MIR lowering, and emission without copying fixture bodies here.

TRANSPILE_TEST_ROOT = File.expand_path("../../../transpile-tests", __dir__)

CURATED_GAP_CORPUS_SKIP = %w[
  50_require.clear
  51_require_types.clear
  224_extern_std_ffi.clear
  382_returned_list_import_cleanup_leak.clear
  382_returned_list_lib.clear
  require_helper.clear
  require_types_helper.clear
].freeze

CURATED_GAP_CORPUS_SKIP_PREFIXES = %w[
  minivm-golden-
].freeze

CURATED_GAP_CORPUS_CELLS =
  Dir[File.join(TRANSPILE_TEST_ROOT, "*.clear")]
    .map { |path| { file: File.basename(path) } }
    .reject { |cell| CURATED_GAP_CORPUS_SKIP.include?(cell[:file]) }
    .reject { |cell| CURATED_GAP_CORPUS_SKIP_PREFIXES.any? { |prefix| cell[:file].start_with?(prefix) } }
    .sort_by { |cell| cell[:file] }
    .freeze

FuzzGenerator.register(:curated_gap_corpus, cells: CURATED_GAP_CORPUS_CELLS) do |p|
  File.read(File.join(TRANSPILE_TEST_ROOT, p[:file]))
end
