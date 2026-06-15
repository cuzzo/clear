# typed: false
# frozen_string_literal: true

module AutoType
  module Providers
    class PythonProvider < Base
      ACTION_KINDS = %w[add_nullability].freeze

      PYTHON_AST_INDEX_SCRIPT = <<~'PYTHON'
        import ast
        import json
        import sys

        path = sys.argv[1]

        try:
            with open(path, "r", encoding="utf-8") as handle:
                source = handle.read()
            tree = ast.parse(source, filename=path, type_comments=True)
        except Exception as exc:
            print(json.dumps({"ok": False, "error": f"{exc.__class__.__name__}: {exc}"}))
            sys.exit(0)

        line_starts = [0]
        for line in source.splitlines(True):
            line_starts.append(line_starts[-1] + len(line.encode("utf-8")))

        def absolute_offset(node, line_attr, col_attr):
            return line_starts[getattr(node, line_attr) - 1] + getattr(node, col_attr)

        def span_for(node):
            required = ("lineno", "col_offset", "end_lineno", "end_col_offset")
            if not all(hasattr(node, attr) for attr in required):
                return None
            return [
                absolute_offset(node, "lineno", "col_offset"),
                absolute_offset(node, "end_lineno", "end_col_offset"),
            ]

        def source_segment(node):
            return (ast.get_source_segment(source, node) or "").strip()

        def base_name(node):
            if isinstance(node, ast.Name):
                return node.id
            if isinstance(node, ast.Attribute):
                return node.attr
            return ""

        def top_level_nullable(node):
            if isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
                return top_level_nullable(node.left) or top_level_nullable(node.right)
            if isinstance(node, ast.Constant) and node.value is None:
                return True
            if isinstance(node, ast.Name) and node.id == "None":
                return True
            if isinstance(node, ast.Subscript) and base_name(node.value) == "Optional":
                return True
            return False

        def field_name(node):
            if isinstance(node, ast.Name):
                return node.id
            if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
                if node.value.id in ("self", "cls"):
                    return node.attr
            return ""

        def annotation_entry(slot, name, annotation, function_line=None, owner=""):
            span = span_for(annotation)
            if span is None:
                return None
            return {
                "slot": slot,
                "name": name,
                "owner": owner,
                "function_line": function_line,
                "line": annotation.lineno,
                "end_line": annotation.end_lineno,
                "start_offset": span[0],
                "end_offset": span[1],
                "type": source_segment(annotation),
                "top_level_nullable": top_level_nullable(annotation),
                "string_annotation": isinstance(annotation, ast.Constant) and isinstance(annotation.value, str),
                "node_kind": type(annotation).__name__,
            }

        class Visitor(ast.NodeVisitor):
            def __init__(self):
                self.annotations = []
                self.owners = []
                self.functions = []

            def visit_ClassDef(self, node):
                self.owners.append(node.name)
                self.generic_visit(node)
                self.owners.pop()

            def visit_FunctionDef(self, node):
                owner = ".".join(self.owners)
                for arg in self.function_args(node.args):
                    if arg.annotation is not None:
                        entry = annotation_entry("param", arg.arg, arg.annotation, node.lineno, owner)
                        if entry is not None:
                            self.annotations.append(entry)
                if node.returns is not None:
                    entry = annotation_entry("return", "", node.returns, node.lineno, owner)
                    if entry is not None:
                        self.annotations.append(entry)
                self.functions.append(node.lineno)
                self.generic_visit(node)
                self.functions.pop()

            visit_AsyncFunctionDef = visit_FunctionDef

            def visit_AnnAssign(self, node):
                name = field_name(node.target)
                if name and node.annotation is not None:
                    entry = annotation_entry(
                        "field",
                        name,
                        node.annotation,
                        self.functions[-1] if self.functions else None,
                        ".".join(self.owners),
                    )
                    if entry is not None:
                        self.annotations.append(entry)
                self.generic_visit(node)

            def function_args(self, args):
                ordered = []
                ordered.extend(args.posonlyargs)
                ordered.extend(args.args)
                if args.vararg is not None:
                    ordered.append(args.vararg)
                ordered.extend(args.kwonlyargs)
                if args.kwarg is not None:
                    ordered.append(args.kwarg)
                return ordered

        visitor = Visitor()
        visitor.visit(tree)
        print(json.dumps({"ok": True, "annotations": visitor.annotations}))
      PYTHON

      def initialize(dry_run: false)
        @dry_run = dry_run
      end

      def language
        "python"
      end

      def capabilities
        {
          "language" => language,
          "action_kinds" => ACTION_KINDS,
          "deterministic" => true,
          "plan_kind" => "text_edits",
          "requires_verifier" => true,
          "syntax" => "python-ast",
          "nilability_style" => "pep604",
        }
      end

      def supports?(action)
        action_language(action) == language && ACTION_KINDS.include?(action["kind"].to_s)
      end

      def plan(action, workspace:)
        return super unless supports?(action)

        path = action_path(action)
        return unsupported_plan(action, "python_missing_path", "Python add_nullability action has no target path") if path.empty?
        return unsupported_plan(action, "python_missing_file", "Python target does not exist: #{path}") unless workspace.file?(path)

        index = annotation_index(path, workspace)
        return unsupported_plan(action, "python_ast_unavailable", index.fetch("error")) unless index.fetch("ok")

        candidate = annotation_candidate(action, index.fetch("annotations"))
        return candidate unless candidate.is_a?(Hash)

        replacement = nilable_replacement(candidate)
        return unsupported_plan(action, "python_empty_annotation", "Python annotation text is empty") unless replacement

        edit = TextEdit.new(
          path: path,
          start_offset: candidate.fetch("start_offset"),
          end_offset: candidate.fetch("end_offset"),
          replacement: replacement,
        )
        RewritePlan.new(
          provider: self.class.name,
          language: language,
          supported: true,
          text_edits: [edit],
          risk: "review",
          requires_verifier: true,
        )
      end

      private

      def action_path(action)
        path = action.dig("target", "path").to_s
        path.empty? ? action["path"].to_s : path
      end

      def action_line(action)
        line = action.dig("target", "line")
        line = action["line"] if line.nil?
        line.to_i
      end

      def action_slot(action)
        action.dig("data", "slot").to_s
      end

      def action_name(action)
        action.dig("data", "name").to_s
      end

      def declared_type(action)
        action.dig("data", "declared_type").to_s
      end

      def annotation_index(path, workspace)
        executable = python_executable
        return { "ok" => false, "error" => "python3 executable not available for Python source planning" } unless executable

        stdout, stderr, status = Open3.capture3(executable, "-c", PYTHON_AST_INDEX_SCRIPT, workspace.absolute_path(path))
        return { "ok" => false, "error" => "Python AST index failed: #{stderr.strip}" } unless status.success?

        JSON.parse(stdout)
      rescue JSON::ParserError => e
        { "ok" => false, "error" => "Python AST index returned invalid JSON: #{e.message}" }
      end

      def python_executable
        @python_executable ||= %w[python3 python].find do |candidate|
          _stdout, _stderr, status = Open3.capture3(candidate, "--version")
          status.success?
        rescue Errno::ENOENT
          false
        end
      end

      def annotation_candidate(action, annotations)
        candidates = Array(annotations).select { |entry| candidate_for_action?(action, entry) }
        return unsupported_plan(action, "python_annotation_not_found", "could not find a matching Python annotation") if candidates.empty?
        return unsupported_plan(action, "python_annotation_ambiguous", "found multiple matching Python annotations") if candidates.size > 1

        candidate = candidates.first
        return unsupported_plan(action, "python_annotation_already_nullable", "Python annotation is already nullable") if candidate["top_level_nullable"]
        return unsupported_plan(action, "python_string_annotation", "string-literal Python annotations are not rewritten yet") if candidate["string_annotation"]
        return unsupported_plan(action, "python_annotation_type_mismatch", "Python annotation no longer matches Nil-kill evidence") unless declared_type_matches?(action, candidate)

        candidate
      end

      def candidate_for_action?(action, entry)
        slot = action_slot(action)
        return false unless entry["slot"].to_s == slot
        return false unless slot != "param" || normalized_name(entry["name"]) == normalized_name(action_name(action))
        return false unless slot != "field" || normalized_name(entry["name"]) == normalized_name(action_name(action))

        line = action_line(action)
        line <= 0 || entry["line"].to_i == line || entry["function_line"].to_i == line
      end

      def normalized_name(name)
        name.to_s.sub(/\A@/, "").sub(/\A(?:self|cls)\./, "")
      end

      def declared_type_matches?(action, candidate)
        declared = normalize_type(declared_type(action))
        declared.empty? || normalize_type(candidate["type"]) == declared
      end

      def normalize_type(type)
        type.to_s.gsub(/\s+/, "")
      end

      def nilable_replacement(candidate)
        type = candidate["type"].to_s.strip
        return nil if type.empty?

        "#{type} | None"
      end

      def unsupported_plan(action, code, message)
        RewritePlan.unsupported(
          provider: self.class.name,
          language: language,
          action: action,
          diagnostic: diagnostic_for(action, code, message),
        )
      end

      def diagnostic_for(action, code, message)
        {
          "severity" => "info",
          "code" => code,
          "language" => language,
          "path" => action_path(action),
          "line" => action_line(action),
          "message" => message,
        }
      end
    end

    register(PythonProvider)
  end
end
