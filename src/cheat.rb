#! /usr/bin/env ruby

require 'bundler/setup' # so `bundle exec` not needed
require "logger"

require_relative "vm"

$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  "[#{severity}] #{msg}\n"
end

OptionParser.new do |opts|
  opts.on('--log-level LEVEL', 'Set log level (DEBUG, INFO, WARN, ERROR)') do |level|
    $logger.level = Logger.const_get(level.upcase)
  end
end.parse!


if __FILE__ == $0
  script_file = ARGV.first
  if script_file
    vm = VM.new(script_file, ARGV[1..])
    puts vm.run_file(File.join(Dir.pwd, script_file))
  else
    $stderr.puts "Usage: ruby cheat.rb <script.ct>"
  end
end

