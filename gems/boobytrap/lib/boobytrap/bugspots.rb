# frozen_string_literal: true

module Boobytrap
  # Vendored bugspots scoring: Google's rolling, time-decayed
  # bug-fix-locality prediction (Lewis et al., ICSE'13; Igor Wiedler's
  # `bugspots` is the canonical Ruby port). We do NOT shell out to the
  # bugspots CLI -- it is file-granular and unmaintained, and the
  # scoring is ~10 lines. We vendor the formula, tighten the fix regex
  # to the repo's commit convention, and keep extraction (git) cleanly
  # separable from scoring (a pure function) so the math is unit-tested
  # without a git repo.
  module Bugspots
    # bugspots default; CLEAR's CLAUDE.md mandates standalone "Fix ..."
    # commits, so this matches the real convention well.
    FIX_RE = /\b(fix(es|ed)?|bug\s*fix|close[sd]?)\b/i

    Event = Struct.new(:time, :subject, :files, keyword_init: true)
    Blast = Struct.new(:file, :score, :fixes, :avg_touched, :max_touched,
                       :partners, keyword_init: true)

    module_function

    # Shell `git log` once; parse into fix Events. `@@@` is a record
    # marker that cannot collide with a path; %ct = committer epoch.
    def events_from_git(repo, fix_re: FIX_RE, max: 0)
      fmt = "@@@%ct%x09%s"
      cmd = ["git", "-C", repo, "log", "--no-merges",
             "--pretty=format:#{fmt}", "--name-only"]
      cmd += ["-n", max.to_s] if max.positive?
      out = IO.popen(cmd, &:read)
      parse_log(out.to_s, fix_re: fix_re)
    end

    def parse_log(text, fix_re: FIX_RE)
      events = []
      cur = nil
      text.each_line do |line|
        line = line.chomp
        if line.start_with?("@@@")
          events << cur if cur && fix?(cur.subject, fix_re) && !cur.files.empty?
          epoch, subject = line[3..].split("\t", 2)
          cur = Event.new(time: epoch.to_i, subject: subject.to_s, files: [])
        elsif !line.empty? && cur
          cur.files << line
        end
      end
      events << cur if cur && fix?(cur.subject, fix_re) && !cur.files.empty?
      events
    end

    def fix?(subject, fix_re)
      fix_re.match?(subject.to_s)
    end

    # Pure scoring. Newer fixes weighted exponentially higher via the
    # bugspots logistic decay 1/(1+e^(-12t+12)), t in [0,1] over the
    # span of the considered fix commits. Returns { path => score }.
    def score(events)
      return {} if events.empty?

      times = events.map(&:time)
      first = times.min
      span = (times.max - first).to_f
      scores = Hash.new(0.0)
      events.each do |e|
        t = span.zero? ? 1.0 : (e.time - first) / span
        w = 1.0 / (1.0 + Math.exp((-12.0 * t) + 12.0))
        e.files.each { |f| scores[f] += w }
      end
      scores
    end

    # Time-decayed multi-file fix blast radius. A file whose fix commits
    # routinely touch many sibling files is a macro-design risk: fixing
    # one local bug tends to require cross-module edits.
    def blast_radius(events)
      return [] if events.empty?

      times = events.map(&:time)
      first = times.min
      span = (times.max - first).to_f
      acc = Hash.new do |h, file|
        h[file] = {
          score: 0.0,
          fixes: 0,
          touched_sum: 0,
          max_touched: 0,
          partners: Hash.new(0.0)
        }
      end

      events.each do |e|
        files = e.files.uniq
        next if files.empty?

        t = span.zero? ? 1.0 : (e.time - first) / span
        w = 1.0 / (1.0 + Math.exp((-12.0 * t) + 12.0))
        touched = files.size
        files.each do |file|
          row = acc[file]
          row[:score] += w * [touched - 1, 0].max
          row[:fixes] += 1
          row[:touched_sum] += touched
          row[:max_touched] = [row[:max_touched], touched].max
          (files - [file]).each { |partner| row[:partners][partner] += w }
        end
      end

      acc.map do |file, row|
        Blast.new(
          file: file,
          score: row[:score].round(3),
          fixes: row[:fixes],
          avg_touched: (row[:touched_sum].to_f / row[:fixes]).round(2),
          max_touched: row[:max_touched],
          partners: row[:partners].sort_by { |_, v| -v }.first(5).map { |p, v| [p, v.round(3)] }
        )
      end.sort_by { |row| [-row.score, -row.avg_touched, row.file] }
    end

    def from_git(repo, fix_re: FIX_RE, max: 0)
      score(events_from_git(repo, fix_re: fix_re, max: max))
    end
  end
end
