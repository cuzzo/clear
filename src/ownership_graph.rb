# ownership_graph.rb — Ownership graph for CLEAR's affine type system.
#
# Replaces the flat per-variable state machine with a graph that tracks
# ownership relationships between variables and their fields.
#
# Nodes: variables and field paths (e.g., "x", "x.child", "x.child.name")
# Edges: ownership relationships (:owns, :borrows, :borrows_mut, :moves, :rc_share)
#
# Core operations:
#   declare(path, kind, type, storage) — add a node
#   transfer(from, to)                 — move: invalidate source + children
#   borrow(borrower, source, mutable:) — add borrow edge, check conflicts
#   release_borrow(borrower)           — remove borrow edge
#   escape(path)                       — mark for heap promotion
#   drop(path)                         — finalize: remove node + owned children
#   can_write?(path)                   — any borrow edges to this path or ancestors?
#   fork / merge(other)                — branch analysis (IF/ELSE)

class OwnershipGraph
  Node = Struct.new(:path, :kind, :state, :storage, :type_info, :scope_depth, :line, keyword_init: true) do
    def live?;    state == :live; end
    def moved?;   state == :moved; end
    def dropped?; state == :dropped; end
    def aliased?; kind == :aliased; end
  end

  Edge = Struct.new(:from, :to, :kind, keyword_init: true)
  # Edge kinds:
  #   :owns        — parent owns child (x owns x.child)
  #   :borrows     — immutable borrow (y borrows x)
  #   :borrows_mut — mutable borrow (y mutably borrows x)
  #   :moves       — ownership transferred (y moved from x)
  #   :rc_share    — reference-counted share (y is an Rc clone of x)
  #   :aliases     — y is a shallow copy sharing backing data with x (skip cleanup on y)

  attr_reader :nodes, :edges

  def initialize
    @nodes = {}           # path => Node
    @edges = []           # Array of Edge
    @edges_by_target = Hash.new { |h, k| h[k] = [] }  # target_path => [Edge]
    @children = Hash.new { |h, k| h[k] = Set.new }    # parent_path => Set of child paths
  end

  # ── Edge index helpers ────────────────────────────────────────────

  def add_edge(edge)
    @edges << edge
    @edges_by_target[edge.to] << edge
  end

  def rebuild_target_index!
    @edges_by_target = Hash.new { |h, k| h[k] = [] }
    @edges.each { |e| @edges_by_target[e.to] << e }
  end

  # ── Core Operations ───────────────────────────────────────────────

  # Declare a new variable or field path.
  def declare(path, kind: :affine, type_info: nil, storage: :stack, scope_depth: 0, line: 0)
    @nodes[path] = Node.new(
      path: path, kind: kind, state: :live, storage: storage,
      type_info: type_info, scope_depth: scope_depth, line: line
    )
    # Register as child of parent path (e.g., "x.child" is child of "x")
    if path.include?('.')
      parent = path.rpartition('.').first
      @children[parent].add(path)
    end
  end

  # Move ownership from source to target. Invalidates source and all children.
  def transfer(from, to)
    source = @nodes[from]
    return unless source

    # Create target node with source's type
    @nodes[to] = Node.new(
      path: to, kind: source.kind, state: :live, storage: source.storage,
      type_info: source.type_info, scope_depth: source.scope_depth, line: source.line
    )

    # Record the move edge
    add_edge(Edge.new(from: to, to: from, kind: :moves))

    # Invalidate source and all owned children
    invalidate(from)
  end

  # Add a borrow edge. Returns nil on success, error string on conflict.
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
  def release_borrow(borrower)
    @edges.reject! { |e| e.from == borrower && (e.kind == :borrows || e.kind == :borrows_mut) }
    rebuild_target_index!
  end

  # Mark a path for heap promotion (escapes the current frame).
  def escape(path)
    node = @nodes[path]
    return unless node
    node.storage = :heap
  end

  # Drop a path and all owned children. Returns list of paths to emit cleanup for.
  def drop(path)
    node = @nodes[path]
    return [] unless node && node.live?

    # Collect all owned children (depth-first, reverse order for cleanup)
    owned = owned_children(path).reverse
    to_cleanup = (owned + [path]).select { |p| @nodes[p]&.live? }

    to_cleanup.each { |p| @nodes[p].state = :dropped if @nodes[p] }

    # Remove borrow edges from/to dropped paths
    dropped_set = to_cleanup.to_set
    @edges.reject! { |e| dropped_set.include?(e.from) || dropped_set.include?(e.to) }
    rebuild_target_index!

    to_cleanup
  end

  # Check if a path can be written to (no active borrows on it or ancestors).
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
  def live?(path)
    @nodes[path]&.live? || false
  end

  # Does this path alias another variable's backing data? (skip cleanup)
  def aliases?(path)
    @edges.any? { |e| e.from == path && e.kind == :aliases }
  end

  # Does this variable need cleanup? (owns heap data and not aliased)
  def needs_cleanup?(path)
    node = @nodes[path]
    return false unless node
    return false if node.aliased?
    return false unless node.live? || node.dropped?
    node.storage == :heap
  end

  # Is the path moved?
  def moved?(path)
    @nodes[path]&.moved? || false
  end

  # ── Branch Analysis ───────────────────────────────────────────────

  # Snapshot the graph state for branching (IF/ELSE).
  def fork
    snapshot = OwnershipGraph.new
    @nodes.each { |k, v| snapshot.nodes[k] = v.dup }
    snapshot.instance_variable_set(:@edges, @edges.map(&:dup))
    snapshot
  end

  # Restore graph state from a snapshot (destructive — replaces all nodes/edges).
  def restore_from(snapshot)
    @nodes = {}
    @children = Hash.new { |h, k| h[k] = Set.new }
    snapshot.nodes.each do |k, v|
      @nodes[k] = v.dup
      if k.include?('.')
        parent = k.rpartition('.').first
        @children[parent].add(k)
      end
    end
    # Preserve alias edges (permanent facts) across branch analysis.
    # Only restore borrow/move/owns edges from the snapshot.
    alias_edges = @edges.select { |e| e.kind == :aliases }
    @edges = snapshot.instance_variable_get(:@edges).map(&:dup) + alias_edges
    rebuild_target_index!
  end

  # Merge a branch's graph state back. Both branches must agree on
  # moved/dropped state; conflicts are returned as error strings.
  def merge(other)
    errors = []
    all_paths = (@nodes.keys + other.nodes.keys).uniq

    all_paths.each do |path|
      mine = @nodes[path]
      theirs = other.nodes[path]
      next unless mine && theirs

      # If one branch moved/dropped and the other didn't, flag it
      if mine.state != theirs.state
        case [mine.state, theirs.state]
        when [:live, :moved], [:moved, :live]
          # Variable moved in one branch but not the other — must be moved in both or neither
          errors << "variable '#{path}' is moved in one branch but live in the other"
        when [:live, :dropped], [:dropped, :live]
          # Dropped in one branch — ok if both branches drop before join
        end
        # Take the more restrictive state
        mine.state = :moved if theirs.moved?
      end
    end

    # Merge edges: union of both edge sets
    other_edges = other.instance_variable_get(:@edges)
    @edges = (@edges + other_edges).uniq { |e| [e.from, e.to, e.kind] }
    rebuild_target_index!

    errors
  end

  # ── Queries ───────────────────────────────────────────────────────

  # Get the node for a path.
  def [](path)
    @nodes[path]
  end

  # All paths that are children of the given path.
  def owned_children(path)
    result = []
    collect_descendants(path, result)
    result.sort
  end

  private

  def invalidate(path)
    node = @nodes[path]
    return unless node
    node.state = :moved
    @children[path].each do |child|
      @nodes[child]&.state = :moved
      invalidate(child)  # recurse for nested children
    end
  end

  def collect_descendants(path, result)
    @children[path].each do |child|
      result << child
      collect_descendants(child, result)
    end
  end

  def find_borrow_conflict(path)
    b = @edges_by_target[path].find { |e| e.kind == :borrows || e.kind == :borrows_mut }
    return nil unless b
    borrower_node = @nodes[b.from]
    line_info = borrower_node ? " (declared at line #{borrower_node.line})" : ""
    "cannot borrow '#{path}' mutably: already borrowed by '#{b.from}'#{line_info}"
  end

  def find_mutable_borrow(path)
    b = @edges_by_target[path].find { |e| e.kind == :borrows_mut }
    return nil unless b
    "cannot borrow '#{path}': mutably borrowed by '#{b.from}'"
  end
end
