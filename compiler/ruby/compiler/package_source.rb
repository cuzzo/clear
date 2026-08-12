# typed: strict
require "sorbet-runtime"

# Source-level merge for multi-file packages (Go model): a package is a set
# of .clear files compiled TOGETHER as one unit. Files of one package
# reference each other's declarations directly — REQUIREs between members
# are dropped during the merge, so the acyclic-import rule applies only
# BETWEEN packages, never between files of the same package.
#
# The merge is textual and deliberately simple:
#   - every member's REQUIRE lines are classified: a require that resolves
#     into the member set is a SIBLING require and is dropped; anything else
#     is EXTERNAL and is hoisted to the top of the merged unit, deduplicated
#     by (path, alias).
#   - member bodies follow in the given order, each behind a `# FILE:`
#     marker comment so merged-unit diagnostics can be traced back.
#
# Constraints (documented, checked where cheap):
#   - REQUIRE statements must be single-line (they are, in both hand-written
#     and translated CLEAR).
#   - members living in different directories must use `pkg:` requires for
#     externals; a path-relative external require is resolved against ITS
#     member's directory and re-emitted as an absolute-path require so the
#     merged unit (whose source_dir is the first member's directory) still
#     finds it.
module PackageSource
  extend T::Sig

  REQUIRE_LINE = T.let(/\A\s*REQUIRE\s+"([^"]+)"(\s+AS\s+([A-Za-z_][A-Za-z0-9_]*))?\s*;?\s*\z/, Regexp)
  REQUIRE_ALIAS = T.let(/\s+AS\s+([A-Za-z_][A-Za-z0-9_]*)\s*;?\s*\z/, Regexp)

  class MergedPackage < T::Struct
    const :source, String
    const :member_paths, T::Array[String]
  end

  # Merge `member_paths` (absolute paths, deterministic order) into one
  # compilation unit. `resolve_pkg` maps a pkg name to its registered
  # source path(s) (String, comma-list String, or Array) so sibling
  # `pkg:` requires can be recognized; unknown names resolve to nil and
  # are treated as external.
  sig do
    params(
      member_paths: T::Array[String],
      resolve_pkg: T.proc.params(name: String).returns(T.nilable(T.any(String, T::Array[String]))),
    ).returns(MergedPackage)
  end
  def self.merge(member_paths, resolve_pkg:)
    members = member_paths.map { |p| File.expand_path(p) }
    member_set = members.to_set

    external_requires = T.let([], T::Array[String])
    seen_requires = T.let(Set.new, T::Set[[String, T.nilable(String)]])
    bodies = T.let([], T::Array[String])

    members.each do |path|
      dir = File.dirname(path)
      body_lines = T.let([], T::Array[String])
      # Materialize the lines so ruby-to-clear lowers this as a FOR loop.
      # `String#each_line` is callback-based and cannot carry the mutable
      # body_lines accumulator through a CLEAR closure capture.
      File.read(path).split("\n").each do |raw_line|
        line = T.cast(raw_line, String)
        m = REQUIRE_LINE.match(line)
        unless m
          body_lines << "#{line}\n"
          next
        end

        target = T.cast(m[1], String).dup
        alias_name = T.let(nil, T.nilable(String))
        alias_match = REQUIRE_ALIAS.match(line)
        alias_name = T.cast(alias_match[1], String).dup if alias_match
        resolved = PackageSource.resolve_require_targets(target, dir, resolve_pkg)
        if resolved.any? { |t| member_set.include?(t) }
          # Sibling require: the declaration is part of this unit already.
          next
        end

        emitted_target = PackageSource.portable_require_target(target, dir)
        key_alias = T.let(nil, T.nilable(String))
        key_alias = alias_name.dup if alias_name
        key = T.let([emitted_target.dup, key_alias], [String, T.nilable(String)])
        next if seen_requires.include?(key)

        seen_requires << key
        if alias_name
          external_requires << "REQUIRE \"#{emitted_target}\" AS #{alias_name}\n"
        else
          external_requires << "REQUIRE \"#{emitted_target}\"\n"
        end
      end
      bodies << "# FILE: #{path}\n"
      bodies << body_lines.join
    end

    MergedPackage.new(
      source: PackageSource.dedupe_generated_functions((external_requires + ["\n"] + bodies).join),
      member_paths: members,
    )
  end

  # Translated members each emit their own generated support helpers
  # (castXToY, ruby_array_concat_T, ...). Merged into one unit, identical
  # copies collide as duplicate declarations. Drop repeat definitions of a
  # top-level FN whose full text matches one already kept; differing bodies
  # under one name are left alone so the compiler surfaces the conflict.
  sig { params(source: String).returns(String) }
  def self.dedupe_generated_functions(source)
    seen = T.let({}, T::Hash[String, String])
    out = T.let([], T::Array[String])
    lines = source.lines
    i = 0
    seen_extern = T.let(Set.new, T::Set[String])
    while i < lines.length
      line = T.must(lines[i])
      # Single-line EXTERN declarations (FN/STRUCT) repeat verbatim across
      # members that share an FFI module — keep the first.
      stripped_line = line.strip
      if stripped_line.start_with?("EXTERN ")
        key = stripped_line
        if seen_extern.include?(key)
          i += 1
        else
          seen_extern << key
          out << line.dup
          i += 1
        end
        next
      end
      m = /\A(?:PUB |PRIVATE )?FN ([A-Za-z_][A-Za-z0-9_]*)\(/.match(line)
      unless m
        out << line.dup
        i += 1
        next
      end

      block = T.let([line.dup], T::Array[String])
      j = i + 1
      while j < lines.length
        block_line = T.must(lines[j])
        break if block_line == "END\n" || block_line == "END"

        block << block_line.dup
        j += 1
      end
      block << T.must(lines[j]).dup if j < lines.length
      text = block.join
      name = T.must(m[1])
      if seen[name] == text
        # exact duplicate — skip
      else
        out << text
        seen[name] = text unless seen.key?(name)
      end
      i = j + 1
    end
    out.join
  end

  # All absolute file paths a require target can resolve to.
  sig do
    params(
      target: String,
      member_dir: String,
      resolve_pkg: T.proc.params(name: String).returns(T.nilable(T.any(String, T::Array[String]))),
    ).returns(T::Array[String])
  end
  def self.resolve_require_targets(target, member_dir, resolve_pkg)
    if target.start_with?("pkg:")
      resolved = resolve_pkg.call(target.delete_prefix("pkg:"))
      return [] unless resolved

      list = if resolved.is_a?(String)
        resolved.split(",")
      else
        T.cast(resolved, T::Array[String])
      end
      expanded = T.let([], T::Array[String])
      list.each { |path| expanded << File.expand_path(path.strip) }
      return expanded
    end

    [File.expand_path(target, member_dir)]
  end

  # Path-relative externals are re-anchored to the member's own directory so
  # they survive the merged unit's single source_dir.
  sig { params(target: String, member_dir: String).returns(String) }
  def self.portable_require_target(target, member_dir)
    return target if target.start_with?("pkg:")

    File.expand_path(target, member_dir)
  end
end
