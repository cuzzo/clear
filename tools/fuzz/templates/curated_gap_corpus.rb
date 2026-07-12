# Template: existing self-contained transpile-tests that cover broad fuzz gaps.
#
# Coverage-mode fuzzing is compile-only, so these fixtures exercise parser,
# annotator, MIR lowering, and emission without copying fixture bodies here.

TRANSPILE_TEST_ROOT = File.expand_path("../../../transpile-tests", __dir__)

# These are not standalone fuzz programs: they are multi-file REQUIRE entry
# points, helper/library units without main(), or FFI integration fixtures.
# The transpile/integration suites run them in their native context. They are
# not registered fuzz cells and therefore are not an inactive fuzz set.
CURATED_GAP_CORPUS_SEPARATE_INTEGRATION = %w[
  50_require.clear
  51_require_types.clear
  224_extern_std_ffi.clear
  382_returned_list_import_cleanup_leak.clear
  382_returned_list_lib.clear
  require_helper.clear
  require_types_helper.clear
].freeze

CURATED_GAP_CORPUS_SEPARATE_INTEGRATION_PREFIXES = %w[
  minivm-golden-
].freeze

CURATED_GAP_CORPUS_CELLS =
  Dir[File.join(TRANSPILE_TEST_ROOT, "*.clear")]
    .map { |path| { file: File.basename(path) } }
    .reject { |cell| CURATED_GAP_CORPUS_SEPARATE_INTEGRATION.include?(cell[:file]) }
    .reject do |cell|
      CURATED_GAP_CORPUS_SEPARATE_INTEGRATION_PREFIXES.any? { |prefix| cell[:file].start_with?(prefix) }
    end
    .sort_by { |cell| cell[:file] }
    .freeze

FuzzGenerator.register(:curated_gap_corpus, cells: CURATED_GAP_CORPUS_CELLS) do |p|
  File.read(File.join(TRANSPILE_TEST_ROOT, p[:file]))
end
