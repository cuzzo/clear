$PROGRAM_NAME = 'annotator_compat_support'
require_relative '/home/yahn/cheat/tools/parser_compat'
require 'open3'
gr = File.expand_path('compiler/src')
src = '/tmp/annotator-compat/build/annotator_compat.clear'
bin = '/tmp/annotator-compat/build/annotator_compat'
env = { 'CLEAR_DISABLE_BUILD_ZIG' => '1', 'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8', 'CLEAR_EXTRA_NATIVE_DIRS' => gr }
cmd = [LexerHarnessSupport::CLEAR, 'build', src, '-o', bin, '--no-stack-check', '--main-tier', 'service', '--safe', *ParserCompat.package_flags(gr)]
_o, e, s = Open3.capture3(env, *cmd)
File.write('/tmp/build_annot_err.txt', e)
puts "status=#{s.success?}"
