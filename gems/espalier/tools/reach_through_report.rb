# frozen_string_literal: true

# WIP: cross-language reach-through report - module A invoking non-public
# methods of module B.
#
# Sources of truth: fact-mine syntax-facts (declared visibility per function,
# call sites with receiver/message/arguments). Three finding classes:
#   1. declared-private cross-owner call (visibility != public at the target)
#   2. convention-private cross-owner call (leading-underscore target in
#      Python/JS where the language enforces nothing)
#   3. Ruby send bypass: send(:literal) resolved to the actual target and
#      checked; send(dynamic) reported as an unverifiable privacy bypass
#      (the ruby_metaprogramming hazard already covers these sites).
#
# Usage: ruby reach_through_report.rb REPO_ROOT

require_relative "corpus_common"

repo = File.expand_path(ARGV[0] || ".")
files = CorpusCommon.production_files(repo)
abort "no production sources found" if files.empty?

facts = CorpusCommon.run_syntax_facts(repo, files)
documents = facts["documents"] || []

# function identity: [owner, name] -> {visibility, path, line}
functions = {}
owners_by_tail = Hash.new { |h, k| h[k] = Set.new }
documents.each do |doc|
  lang = doc["language"]
  (doc["functions"] || []).each do |f|
    owner = f["owner"].to_s
    functions[[lang, owner, f["name"]]] ||= {
      "visibility" => f["visibility"] || "public",
      "path" => doc["file"],
      "line" => f["line"]
    }
    owners_by_tail[[lang, owner.split("::").last]] << owner unless owner.empty?
    owners_by_tail[[lang, owner]] << owner unless owner.empty?
  end
end

def resolve_owner(owners_by_tail, lang, receiver)
  candidates = owners_by_tail[[lang, receiver]]
  candidates.size == 1 ? candidates.first : nil
end

SEND_METHODS = %w[send __send__ public_send].freeze

# Universal method names that unique-name resolution must never claim:
# stdlib collections and lifecycle verbs define these everywhere, so a single
# project definition proves nothing about the call target.
GENERIC_NAMES = %w[
  add get set remove delete create close open dispose run call apply next
  size clear put pop push write read count reset init start stop update
  build parse format merge copy clone equals hash to_s toString insert find
  max min entry scope len new push_back append contains includes has key
  keys values each map filter reduce
].to_set.freeze

# Languages whose compiler already rejects cross-class private access: a
# cross-owner-private finding there is a resolution artifact (or
# package-private mislabeled), not a real violation.
ENFORCING_LANGUAGES = %w[java csharp go rust swift kotlin].freeze

findings = { declared: [], convention: [], send_resolved: [], send_dynamic: 0, suspect: [] }

documents.each do |doc|
  (doc["calls"] || []).each do |call|
    caller_owner = call["owner"].to_s
    receiver = call["receiver"].to_s
    message = call["message"].to_s
    file = doc["file"]

    # Ruby send-family: try to resolve literal symbol targets.
    if SEND_METHODS.include?(message)
      literal = Array(call["arguments"]).first.to_s[/\A:(\w+[?!]?)\z/, 1]
      if literal.nil?
        findings[:send_dynamic] += 1
        next
      end
      target_owner =
        if receiver.empty? || receiver == "self"
          caller_owner
        elsif receiver.match?(/\A[A-Z]/)
          resolve_owner(owners_by_tail, doc["language"], receiver)
        else
          defining = functions.keys.select { |(l, _, name)| l == doc["language"] && name == literal }
                              .map { |(_, owner, _)| owner }.uniq
          defining.size == 1 ? defining.first : nil
        end
      next unless target_owner
      target = functions[[doc["language"], target_owner, literal]]
      next unless target
      if message != "public_send" && target["visibility"] != "public"
        findings[:send_resolved] << {
          from: caller_owner, to: "#{target_owner}##{literal}",
          visibility: target["visibility"],
          at: "#{file}:#{call["line"]}", target_at: "#{target["path"]}:#{target["line"]}"
        }
      end
      next
    end

    # Ordinary cross-owner calls: resolve constant-shaped receivers by owner
    # name; fall back to unique-definition resolution for instance receivers
    # (the message is defined by exactly one owner in the corpus).
    next if receiver.empty? || receiver == "self" || receiver == "this" || receiver == "cls"
    target_owner = nil
    resolution = nil
    if receiver.match?(/\A[A-Z][A-Za-z0-9_:.]*\z/)
      target_owner = resolve_owner(owners_by_tail, doc["language"], receiver)
      resolution = "owner"
    elsif message.start_with?("_") && !GENERIC_NAMES.include?(message)
      # Unique-name resolution is only trustworthy for distinctive names.
      # Plain names collide with struct fields and attr_reader accessors
      # (which fact-mine does not emit as functions), so restrict the
      # fallback to underscore-convention targets; everything else needs
      # receiver type evidence (flow_types / nil-kill runtime types).
      defining = functions.keys.select { |(l, _, name)| l == doc["language"] && name == message }
                          .map { |(_, owner, _)| owner }.uniq
      if defining.size == 1
        target_owner = defining.first
        resolution = "unique-name"
      end
    end
    next unless target_owner && target_owner != caller_owner
    target = functions[[doc["language"], target_owner, message]]
    next unless target

    if target["visibility"] && target["visibility"] != "public"
      finding = {
        from: caller_owner, to: "#{target_owner}##{message}",
        visibility: "#{target["visibility"]}, via #{resolution}",
        at: "#{file}:#{call["line"]}", target_at: "#{target["path"]}:#{target["line"]}"
      }
      bucket = ENFORCING_LANGUAGES.include?(doc["language"]) ? :suspect : :declared
      findings[bucket] << finding
    elsif message.start_with?("_") && !message.start_with?("__")
      findings[:convention] << {
        from: caller_owner, to: "#{target_owner}##{message}",
        visibility: "underscore-convention",
        at: "#{file}:#{call["line"]}", target_at: "#{target["path"]}:#{target["line"]}"
      }
    end
  end

  # Convention-private access in owner-less module systems (Python/JS):
  # calling _name on an imported module object.
  next unless %w[python javascript typescript].include?(doc["language"])
  (doc["calls"] || []).each do |call|
    receiver = call["receiver"].to_s
    message = call["message"].to_s
    next unless message.start_with?("_") && !message.start_with?("__")
    next if receiver.empty? || receiver == "self" || receiver == "cls" || receiver == "this"
    next unless receiver.match?(/\A[a-z][a-z0-9_]*\z/)
    target = functions.keys.find { |(l, _, name)| l == doc["language"] && name == message }
    next unless target
    target_info = functions[target]
    next if target_info["path"] == doc["file"]
    findings[:convention] << {
      from: "#{doc["file"]} (via #{receiver})", to: "#{target[1]}##{message}",
      visibility: "underscore-convention",
      at: "#{doc["file"]}:#{call["line"]}", target_at: "#{target_info["path"]}:#{target_info["line"]}"
    }
  end
end

findings[:convention].uniq! { |f| [f[:at], f[:to]] }

puts "repo: #{repo}  files: #{files.size}  functions: #{functions.size}"
puts
puts "== Declared-private reach-through (#{findings[:declared].size}) =="
findings[:declared].first(12).each do |f|
  puts "  #{f[:at]}  #{f[:from]} -> #{f[:to]} (#{f[:visibility]}, defined #{f[:target_at]})"
end
puts
puts "== send(:literal) privacy bypass (#{findings[:send_resolved].size}); dynamic send sites: #{findings[:send_dynamic]} =="
findings[:send_resolved].first(12).each do |f|
  puts "  #{f[:at]}  #{f[:from]} -> #{f[:to]} (#{f[:visibility]})"
end
puts
puts "== Convention-private reach-through (#{findings[:convention].size}) =="
findings[:convention].first(12).each do |f|
  puts "  #{f[:at]}  #{f[:from]} -> #{f[:to]}"
end
puts
puts "== Suspect (enforcing language; likely package-private or resolution artifact) (#{findings[:suspect].size}) =="
findings[:suspect].first(6).each do |f|
  puts "  #{f[:at]}  #{f[:from]} -> #{f[:to]} (#{f[:visibility]})"
end
