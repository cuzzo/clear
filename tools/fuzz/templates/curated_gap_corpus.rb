# Template: existing self-contained transpile-tests that cover broad fuzz gaps.
#
# Coverage-mode fuzzing is compile-only, so these fixtures exercise parser,
# annotator, MIR lowering, and emission without copying fixture bodies here.

TRANSPILE_TEST_ROOT = File.expand_path("../../../transpile-tests", __dir__)

CURATED_GAP_CORPUS_SKIP = %w[
  50_require.cht
  51_require_types.cht
  224_extern_std_ffi.cht
  382_returned_list_import_cleanup_leak.cht
  382_returned_list_lib.cht
  require_helper.cht
  require_types_helper.cht
].freeze

CURATED_GAP_CORPUS_SKIP_PREFIXES = %w[
  minivm-golden-
].freeze

CURATED_GAP_CORPUS_CELLS =
  Dir[File.join(TRANSPILE_TEST_ROOT, "*.cht")]
    .map { |path| { file: File.basename(path) } }
    .reject { |cell| CURATED_GAP_CORPUS_SKIP.include?(cell[:file]) }
    .reject { |cell| CURATED_GAP_CORPUS_SKIP_PREFIXES.any? { |prefix| cell[:file].start_with?(prefix) } }
    .sort_by { |cell| cell[:file] }
    .freeze

FuzzGenerator.register(:curated_gap_corpus, cells: CURATED_GAP_CORPUS_CELLS) do |p|
  File.read(File.join(TRANSPILE_TEST_ROOT, p[:file]))
end
