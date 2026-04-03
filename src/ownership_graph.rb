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
  Node = Struct.new(:path, :kind, :state, :storage, :type_info, :scope_depth, :line, :borrowed_from, keyword_init: true) do
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
    @nodes = {}   # path => Node
    @edges = []   # Array of Edge
  end

  # ── Core Operations ───────────────────────────────────────────────

  # Declare a new variable or field path.
  def declare(path, kind: :affine, type_info: nil, storage: :stack, scope_depth: 0, line: 0)
    @nodes[path] = Node.new(
      path: path, kind: kind, state: :live, storage: storage,
      type_info: type_info, scope_depth: scope_depth, line: line
    )
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
    @edges << Edge.new(from: to, to: from, kind: :moves)

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
      @edges << Edge.new(from: borrower, to: source, kind: :borrows_mut)
    else
      # Immutable borrow: no mutable borrows may exist
      mut_conflict = find_mutable_borrow(source)
      return mut_conflict if mut_conflict
      @edges << Edge.new(from: borrower, to: source, kind: :borrows)
    end
    # Mark the node as borrowed (persists after edge cleanup for transpiler queries).
    borrower_node = @nodes[borrower]
    borrower_node.borrowed_from = source if borrower_node
    nil
  end

  # Remove all borrow edges from a borrower.
  def release_borrow(borrower)
    @edges.reject! { |e| e.from == borrower && (e.kind == :borrows || e.kind == :borrows_mut) }
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

    to_cleanup
  end

  # Check if a path can be written to (no active borrows on it or ancestors).
  def can_write?(path)
    # Check this path and all ancestors
    current = path
    loop do
      borrows = @edges.select { |e| e.to == current && (e.kind == :borrows || e.kind == :borrows_mut) }
      return false if borrows.any?
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

  # Is this path a borrower? Checks the persistent borrowed_from field.
  def borrowed?(path)
    @nodes[path]&.borrowed_from != nil
  end

  # Return the source variable name this path borrows from, or nil.
  def borrow_source(path)
    @nodes[path]&.borrowed_from
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
    snapshot.nodes.each { |k, v| @nodes[k] = v.dup }
    # Preserve alias edges (permanent facts) across branch analysis.
    # Only restore borrow/move/owns edges from the snapshot.
    alias_edges = @edges.select { |e| e.kind == :aliases }
    @edges = snapshot.instance_variable_get(:@edges).map(&:dup) + alias_edges
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

    errors
  end

  # ── Queries ───────────────────────────────────────────────────────

  # Get the node for a path.
  def [](path)
    @nodes[path]
  end

  # All paths that are children of the given path.
  def owned_children(path)
    prefix = "#{path}."
    @nodes.keys.select { |k| k.start_with?(prefix) }.sort
  end

  private

  def invalidate(path)
    node = @nodes[path]
    return unless node
    node.state = :moved
    # Also invalidate children
    prefix = "#{path}."
    @nodes.each { |k, v| v.state = :moved if k.start_with?(prefix) }
  end

  def find_borrow_conflict(path)
    borrows = @edges.select { |e| e.to == path && (e.kind == :borrows || e.kind == :borrows_mut) }
    return nil if borrows.empty?
    b = borrows.first
    borrower_node = @nodes[b.from]
    line_info = borrower_node ? " (declared at line #{borrower_node.line})" : ""
    "cannot borrow '#{path}' mutably: already borrowed by '#{b.from}'#{line_info}"
  end

  def find_mutable_borrow(path)
    mut_borrows = @edges.select { |e| e.to == path && e.kind == :borrows_mut }
    return nil if mut_borrows.empty?
    b = mut_borrows.first
    "cannot borrow '#{path}': mutably borrowed by '#{b.from}'"
  end
end
