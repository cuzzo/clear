#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates the Zola site content from in-repo markdown.
#
# docs/ is the public markdown source for the site. Most docs are authored
# directly under docs/. The stdlib reference is generated first from
# code-owned heredocs in tools/stdlib_docs.rb, then treated like the rest of
# docs/. Each section below maps a set of source files to a Zola section under
# site/content/. Front matter (title from the first `# ` heading, date/updated
# from git history) is injected; markdown links between any two generated files
# are rewritten to Zola internal links so they resolve on the site. Generated
# site files are git-ignored (see site/.gitignore); CI runs this before
# `zola build`.
#
#   ruby tools/gen_site.rb

require "fileutils"
require "shellwords"
require "set"

ROOT = File.expand_path("..", __dir__)

require_relative "stdlib_docs"

StdlibDocs.generate!(root: ROOT)

def slug_from_basename(abs) = File.basename(abs, ".md")

def slug_from_relpath(abs, base)
  abs.sub("#{base}/", "").sub(/\.md\z/, "").tr("/", "-")
end

RETRO   = File.join(ROOT, "docs", "retrospective")
DOCS    = File.join(ROOT, "docs")
# docs/agents is internal agent notes; retrospective is the blog
# stream -- neither is rendered under /docs.
EXCLUDE = [File.join(DOCS, "agents"), RETRO].freeze

SECTIONS = {
  "blog" => {
    srcs: Dir.glob(File.join(RETRO, "*.md")).sort,
    out:  File.join(ROOT, "site", "content", "blog"),
    slug: ->(a) { slug_from_basename(a) }
  },
  "docs" => {
    srcs: Dir.glob(File.join(DOCS, "**", "*.md")).sort.reject { |p|
      EXCLUDE.any? { |ex| p == ex || p.start_with?("#{ex}/") }
    },
    out:  File.join(ROOT, "site", "content", "docs"),
    slug: ->(a) { slug_from_relpath(a, DOCS) }
  }
}.freeze

def git_date(file, added:)
  filter = added ? "--diff-filter=A --follow" : ""
  iso = `git -C #{ROOT.shellescape} log #{filter} --format=%aI -1 -- #{file.shellescape}`.strip
  iso.empty? ? nil : iso[0, 10]
end

def toml_escape(str) = str.gsub("\\", "\\\\\\\\").gsub('"', '\\"')

# Global map: source abspath -> "@/<section>/<slug>.md" for every
# file we generate, so cross-links (incl. cross-section) resolve.
INTERNAL = {}
SECTIONS.each do |name, sec|
  abort "no markdown for section '#{name}'" if sec[:srcs].empty?
  sec[:srcs].each do |a|
    INTERNAL[File.realpath(a)] = "@/#{name}/#{sec[:slug].call(a)}.md"
  end
end

LINK_RE = %r{\]\(\s*([^)\s#]+\.md)(#[^)\s]*)?\s*\)}

# GitHub tolerates empty-URL links (`[text]()`) used as emphasis
# brackets; Zola's renderer hard-errors on them. Source docs stay the
# source of truth -- neutralize the publish-breaking form here.
EMPTY_LINK_RE = /\[([^\]]+)\]\(\s*(?:<>)?\s*\)/

def strip_empty_links(body) = body.gsub(EMPTY_LINK_RE, '\1')

# Zola/syntect treats the whole fence info string as the language, so
# ```ruby clear``` matches no syntax and renders unhighlighted.
# GitHub/Linguist use only the first token. Reduce each fence's info
# to its first token; map the CLEAR-family tokens to Ruby (CLEAR is
# Ruby-ish) so they highlight like Ruby on the site. Source docs are
# untouched and still render on GitHub.
FENCE_RE  = /\A(\s*)(`{3,}|~{3,})(.*)\z/
CODE_LANG = { "clear" => "ruby", "CLEAR" => "ruby", "cht" => "ruby" }.freeze

def normalize_code_fences(body)
  in_fence = false
  marker   = nil
  body.each_line.map do |line|
    m = line.chomp.match(FENCE_RE)
    if m && !in_fence
      in_fence = true
      marker   = m[2][0]
      info = m[3].strip
      next line if info.empty?

      tok = info.split(/\s+/).first
      "#{m[1]}#{m[2]}#{CODE_LANG[tok] || tok}\n"
    elsif m && in_fence && m[2][0] == marker && m[3].strip.empty?
      in_fence = false
      line
    else
      line
    end
  end.join
end

# GitHub-style alerts (`> [!NOTE]` ...). Zola/pulldown-cmark does not
# render these natively (it emits literal "[!NOTE]"), so convert them
# to raw-HTML blocks with the GitHub octicon + label. Blank lines
# around the body keep it parsed as markdown (CommonMark HTML-block
# rule), so inline code/links inside the alert still render. Source
# docs keep the GitHub syntax (native alerts on GitHub).
ALERTS = {
  "NOTE"      => ["Note",      %(<path d="M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/>)],
  "TIP"       => ["Tip",       %(<path d="M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z"/>)],
  "IMPORTANT" => ["Important", %(<path d="M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"/>)],
  "WARNING"   => ["Warning",   %(<path d="M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"/>)],
  "CAUTION"   => ["Caution",   %(<path d="M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/>)]
}.freeze

ALERT_HEAD = /\A>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*\z/i

def render_alerts(body)
  out = []
  lines = body.lines
  i = 0
  in_fence = false
  while i < lines.length
    line = lines[i]
    if line.chomp =~ /\A\s*(`{3,}|~{3,})/
      in_fence = !in_fence
      out << line
      i += 1
      next
    end
    m = (!in_fence && line.chomp.match(ALERT_HEAD))
    unless m
      out << line
      i += 1
      next
    end

    type = m[1].upcase
    i += 1
    body_lines = []
    while i < lines.length && lines[i].lstrip.start_with?(">")
      q = lines[i].chomp.sub(/\A\s*>\s?/, "")
      body_lines << q
      i += 1
    end
    label, icon = ALERTS[type]
    svg = %(<svg class="gh-alert-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">#{icon}</svg>)
    out << "\n<div class=\"gh-alert gh-alert-#{type.downcase}\">\n"
    out << "<p class=\"gh-alert-title\">#{svg} #{label}</p>\n\n"
    out << "#{body_lines.join("\n").strip}\n\n"
    out << "</div>\n\n"
  end
  out.join
end

def rewrite_links(body, src_abs)
  dir = File.dirname(src_abs)
  body.gsub(LINK_RE) do
    target = Regexp.last_match(1)
    anchor = Regexp.last_match(2)
    whole  = Regexp.last_match(0)
    next whole if target.start_with?("http", "/", "@", "#")

    mapped = INTERNAL[File.expand_path(target, dir)]
    mapped ? "](#{mapped}#{anchor})" : whole
  end
end

SECTIONS.each do |name, sec|
  FileUtils.mkdir_p(sec[:out])
  Dir.glob(File.join(sec[:out], "*.md")).each do |f|
    File.delete(f) unless File.basename(f) == "_index.md"
  end

  sec[:srcs].each do |path|
    slug = sec[:slug].call(path)
    raw  = File.read(path)

    h1 = raw.lines.find { |l| l.start_with?("# ") }
    title = (h1 ? h1.sub(/^#\s+/, "") : slug.tr("-", " ")).strip

    body = raw.dup
    if h1
      body = body.sub(/\A.*?^#{Regexp.escape(h1)}\n?/m, "")
      body = body.sub(/\A\n/, "")
    end
    body = strip_empty_links(body)
    body = normalize_code_fences(body)
    body = rewrite_links(body, File.realpath(path))
    body = render_alerts(body)

    date    = git_date(path, added: true)  || Time.now.strftime("%Y-%m-%d")
    updated = git_date(path, added: false) || date
    rel_src = path.sub("#{ROOT}/", "")

    front = +"+++\n"
    front << %(title = "#{toml_escape(title)}"\n)
    front << "date = #{date}\n"
    front << "updated = #{updated}\n"
    front << "[extra]\n"
    front << %(source = "#{rel_src}"\n)
    front << "+++\n\n"

    File.write(File.join(sec[:out], "#{slug}.md"), front + body)
    puts "generated #{name}/#{slug}.md  (#{date})  #{title}"
  end
end
