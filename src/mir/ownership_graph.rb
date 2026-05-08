# typed: true
# ownership_graph.rb — Ownership graph for CLEAR's affine type system.
#
# Nodes: variables and field paths (e.g., "x", "x.child", "x.child.name")
# Edges: ownership relationships (:borrows, :borrows_mut)
#
# Core operations:
#   declare(path, kind, type)          — add a node
#   transfer(from, to)                 — move: invalidate source + children
#   borrow(borrower, source, mutable:) — add borrow edge, check conflicts
#   release_borrow(borrower)           — remove borrow edge
#   drop(path)                         — finalize: remove node + owned children
#   can_write?(path)                   — any borrow edges to this path or ancestors?
#   fork_lightweight / merge(other)    — branch analysis (IF/ELSE)

require "sorbet-runtime"

class OwnershipGraph
    extend T::Sig

  Node = Struct.new(:path, :kind, :state, :type_info, :scope_depth, :line,
                    :move_line, :move_col, :move_action,
                    :move_consumer_param_type,
                    keyword_init: true) do
    def live?;    state == :live; end
    def moved?;   state == :moved; end
    def dropped?; state == :dropped; end
  end

  Edge = Struct.new(:from, :to, :kind, keyword_init: true)
  # Edge kinds:
  #   :borrows     — immutable borrow (y borrows x)
  #   :borrows_mut — mutable borrow (y mutably borrows x)

  attr_reader :nodes, :edges

  sig { void }
  def initialize
    @nodes = {}           # path => Node
    @edges = []           # Array of Edge
    @edges_by_target = Hash.new { |h, k| h[k] = [] }  # target_path => [Edge]
    @edges_by_source = Hash.new { |h, k| h[k] = [] }  # source_path => [Edge]
    @children = Hash.new { |h, k| h[k] = Set.new }    # parent_path => Set of child paths
  end

  # ── Edge index helpers ────────────────────────────────────────────

  sig { params(edge: OwnershipGraph::Edge).returns(T::Array[OwnershipGraph::Edge]) }
  def add_edge(edge)
    @edges << edge
    @edges_by_target[edge.to] << edge
    @edges_by_source[edge.from] << edge
  end

  sig { params(edge: OwnershipGraph::Edge).returns(T.nilable(OwnershipGraph::Edge)) }
  def remove_edge(edge)
    @edges.delete(edge)
    @edges_by_target[edge.to]&.delete(edge)
    @edges_by_source[edge.from]&.delete(edge)
  end

  # ── Core Operations ───────────────────────────────────────────────

  # Declare a new variable or field path.
  sig { params(path: String, kind: Symbol, type_info: T.nilable(Type), scope_depth: Integer, line: Integer).returns(T.nilable(Set)) }
  def declare(path, kind: :affine, type_info: nil, scope_depth: 0, line: 0)
    @nodes[path] = Node.new(
      path: path, kind: kind, state: :live,
      type_info: type_info, scope_depth: scope_depth, line: line
    )
    # Register as child of parent path (e.g., "x.child" is child of "x")
    if path.include?('.')
      parent = path.rpartition('.').first
      @children[parent].add(path)
    end
  end

  # Move ownership from source to target. Invalidates source and all children.
  sig { params(from: String, to: String, at_token: T.nilable(Lexer::Token), action: Symbol).returns(T.nilable(Set)) }
  def transfer(from, to, at_token: nil, action: :move)
    source = @nodes[from]
    return unless source

    # Create target node with source's type
    @nodes[to] = Node.new(
      path: to, kind: source.kind, state: :live,
      type_info: source.type_info, scope_depth: source.scope_depth, line: source.line
    )

    # Invalidate source and all owned children; record the move site
    # (when a token is given) so `clear fix` can locate where the
    # consuming reference lives.
    record_move_site(source, at_token, action)
    invalidate(from, source)
  end

  sig { params(path: String, at_token: T.nilable(Lexer::Token), action: Symbol, consumer_param_type: T.untyped).returns(T.nilable(Set)) }
  def mark_moved(path, at_token: nil, action: :move, consumer_param_type: nil)
    source = @nodes[path]
    return unless source
    record_move_site(source, at_token, action, consumer_param_type: consumer_param_type)
    invalidate(path, source)
  end

  # Add a borrow edge. Returns nil on success, error string on conflict.
  sig { params(borrower: String, source: String, mutable: T::Boolean).returns(T.nilable(String)) }
  def borrow(borrower, source, mutable: false)
    source_node = @nodes[source]
    return "cannot borrow '#{source}': not declared" unless source_node
    return "cannot borrow '#{source}': already moved" if source_node.moved?

    if mutable
      # Mutable borrow: no other borrows (mutable or immutable) may exist
      conflict = find_borrow_conflict(source)
      return conflict if conflict
      add_edge(Edge.new(from: borrower, to: source, kind: :borrows_mut))
    else
      # Immutable borrow: no mutable borrows may exist
      mut_conflict = find_mutable_borrow(source)
      return mut_conflict if mut_conflict
      add_edge(Edge.new(from: borrower, to: source, kind: :borrows))
    end
    nil
  end

  # Remove all borrow edges from a borrower.
  sig { params(borrower: String).returns(T::Array[OwnershipGraph::Edge]) }
  def release_borrow(borrower)
    to_remove = @edges_by_source[borrower]&.select { |e| e.kind == :borrows || e.kind == :borrows_mut } || []
    to_remove.each { |e| remove_edge(e) }
  end

  # Drop a path and all owned children. Returns list of paths to emit cleanup for.
  sig { params(path: String).returns(T::Array[String]) }
  def drop(path)
    node = @nodes[path]
    return [] unless node && node.live?

    # Collect all owned children (depth-first, reverse order for cleanup)
    owned = owned_children(path).reverse
    to_cleanup = (owned + [path]).select { |p| @nodes[p]&.live? }

    to_cleanup.each { |p| @nodes[p].state = :dropped if @nodes[p] }

    # Remove borrow edges from/to dropped paths
    dropped_set = to_cleanup.to_set
    to_remove = @edges.select { |e| dropped_set.include?(e.from) || dropped_set.include?(e.to) }
    to_remove.each { |e| remove_edge(e) }

    to_cleanup
  end

  # Check if a path can be written to (no active borrows on it or ancestors).
  sig { params(path: String).returns(T::Boolean) }
  def can_write?(path)
    # Check this path and all ancestors
    current = path
    loop do
      return false if @edges_by_target[current].any? { |e| e.kind == :borrows || e.kind == :borrows_mut }
      break unless current.include?('.')
      current = current.rpartition('.').first
    end
    true
  end

  # Is the path live?
  sig { params(path: String).returns(T::Boolean) }
  def live?(path)
    @nodes[path]&.live? || false
  end

  # Is the path moved?
  sig { params(path: String).returns(T::Boolean) }
  def moved?(path)
    @nodes[path]&.moved? || false
  end

  # ── Branch Analysis ───────────────────────────────────────────────

  # Lightweight snapshot: only saves node states, not full graph.
  # Use for branches that won't declare new nodes (IF/ELSE in flat code).
  sig { returns(Hash) }
  def fork_lightweight
    states = {}
    @nodes.each do |k, v|
      states[k] = {
        state: v.state,
        move_line: v.move_line,
        move_col: v.move_col,
        move_action: v.move_action,
      }
    end
    { node_states: states, edge_count: @edges.size }
  end

  # Restore from lightweight snapshot: reset states and truncate edges.
  sig { params(snapshot: T::Hash[Symbol, T.untyped]).returns(T.untyped) }
  def restore_lightweight(snapshot)
    snapshot[:node_states].each do |path, saved|
      node = @nodes[path]
      next unless node

      if saved.is_a?(Hash)
        node.state = saved[:state]
        node.move_line = saved[:move_line]
        node.move_col = saved[:move_col]
        node.move_action = saved[:move_action]
      else
        node.state = saved
      end
    end
    target_count = snapshot[:edge_count]
    while @edges.size > target_count
      removed = @edges.pop
      @edges_by_target[removed.to]&.delete(removed)
      @edges_by_source[removed.from]&.delete(removed)
    end
  end

  # Merge a branch's graph state back. Both branches must agree on
  # moved/dropped state; conflicts are returned as error strings.
  sig { params(other: OwnershipGraph).returns(Array) }
  def merge(other)
    errors = []
    all_paths = (@nodes.keys + other.nodes.keys).uniq

    all_paths.each do |path|
      mine = @nodes[path]
      theirs = other.nodes[path]
      next unless mine && theirs

      if mine.state != theirs.state
        case [mine.state, theirs.state]
        when [:live, :moved], [:moved, :live]
          errors << "variable '#{path}' is moved in one branch but live in the other"
        when [:live, :dropped], [:dropped, :live]
        end
        if theirs.moved?
          mine.state = :moved
          mine.move_line = theirs.move_line
          mine.move_col = theirs.move_col
          mine.move_action = theirs.move_action
        end
      end
    end

    # Merge edges: add new ones from other
    existing = @edges.map { |e| [e.from, e.to, e.kind] }.to_set
    other.instance_variable_get(:@edges).each do |e|
      key = [e.from, e.to, e.kind]
      unless existing.include?(key)
        existing.add(key)
        add_edge(e.dup)
      end
    end

    errors
  end

  # ── Queries ───────────────────────────────────────────────────────

  # Get the node for a path.
  sig { params(path: T.untyped).returns(T.untyped) }
  def [](path)
    @nodes[path]
  end

  # All paths that are children of the given path.
  sig { params(path: String).returns(T::Array[String]) }
  def owned_children(path)
    result = []
    collect_descendants(path, result)
    result.sort
  end

  private

  sig { params(path: String, move_source: T.nilable(OwnershipGraph::Node)).returns(T.untyped) }
  def invalidate(path, move_source = nil)
    node = @nodes[path]
    return unless node
    if move_source && node != move_source
      node.move_line = move_source.move_line
      node.move_col = move_source.move_col
      node.move_action = move_source.move_action
    end
    node.state = :moved
    @children[path].each do |child|
      invalidate(child, move_source)  # recurse for nested children
    end
  end

  sig { params(node: OwnershipGraph::Node, at_token: T.nilable(Lexer::Token), action: Symbol, consumer_param_type: T.untyped).returns(T.nilable(Integer)) }
  def record_move_site(node, at_token, action, consumer_param_type: nil)
    node.move_action = action
    node.move_consumer_param_type = consumer_param_type if consumer_param_type
    return unless at_token

    node.move_line = at_token.line
    node.move_col  = at_token.column
  end

  sig { params(path: String, result: T::Array[String]).returns(T::Set[String]) }
  def collect_descendants(path, result)
    @children[path].each do |child|
      result << child
      collect_descendants(child, result)
    end
  end

  sig { params(path: String).returns(T.nilable(String)) }
  def find_borrow_conflict(path)
    b = @edges_by_target[path].find { |e| e.kind == :borrows || e.kind == :borrows_mut }
    return nil unless b
    borrower_node = @nodes[b.from]
    line_info = borrower_node ? " (declared at line #{borrower_node.line})" : ""
    "cannot borrow '#{path}' mutably: already borrowed by '#{b.from}'#{line_info}"
  end

  sig { params(path: String).returns(T.nilable(String)) }
  def find_mutable_borrow(path)
    b = @edges_by_target[path].find { |e| e.kind == :borrows_mut }
    return nil unless b
    "cannot borrow '#{path}': mutably borrowed by '#{b.from}'"
  end
end
