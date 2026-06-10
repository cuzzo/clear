# typed: strict
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
require_relative "../ast/type"
require_relative "ownership_identity"

class OwnershipGraph
    extend T::Sig

  MoveConsumerParamType = T.type_alias { T.nilable(Type::TypeInput) }
  PlaceId = OwnershipIdentity::PlaceId

  class LightweightSnapshot < T::Struct
    extend T::Sig

    const :states, T::Hash[PlaceId, Symbol]
    const :move_lines, T::Hash[PlaceId, Integer]
    const :move_cols, T::Hash[PlaceId, Integer]
    const :move_actions, T::Hash[PlaceId, Symbol]
    const :edge_count, Integer

    sig { params(path: String).returns(T.nilable(Symbol)) }
    def state_for(path)
      state_for_place(PlaceId.from_path(path))
    end

    sig { params(place: PlaceId).returns(T.nilable(Symbol)) }
    def state_for_place(place)
      states[place]
    end

    sig { params(path: String).returns(T.nilable(Integer)) }
    def move_line_for(path)
      move_line_for_place(PlaceId.from_path(path))
    end

    sig { params(place: PlaceId).returns(T.nilable(Integer)) }
    def move_line_for_place(place)
      move_lines[place]
    end

    sig { params(path: String).returns(T.nilable(Integer)) }
    def move_col_for(path)
      move_col_for_place(PlaceId.from_path(path))
    end

    sig { params(place: PlaceId).returns(T.nilable(Integer)) }
    def move_col_for_place(place)
      move_cols[place]
    end

    sig { params(path: String).returns(T.nilable(Symbol)) }
    def move_action_for(path)
      move_action_for_place(PlaceId.from_path(path))
    end

    sig { params(place: PlaceId).returns(T.nilable(Symbol)) }
    def move_action_for_place(place)
      move_actions[place]
    end

    sig { params(block: T.proc.params(path: String, state: Symbol).void).void }
    def each_state(&block)
      states.each { |place, state| block.call(place.path, state) }
      nil
    end

    sig { params(block: T.proc.params(place: PlaceId, state: Symbol).void).void }
    def each_place_state(&block)
      states.each { |place, state| block.call(place, state) }
      nil
    end
  end

  class Node < T::Struct
    extend T::Sig

    prop :path, String, default: ""
    prop :kind, Symbol, default: :affine
    prop :state, Symbol, default: :live
    prop :type_info, Type, factory: -> { Type.new(:Any) }
    prop :scope_depth, Integer, default: 0
    prop :line, Integer, default: 0
    prop :move_line, T.nilable(Integer), default: nil
    prop :move_col, T.nilable(Integer), default: nil
    prop :move_action, T.nilable(Symbol), default: nil
    prop :move_consumer_param_type, MoveConsumerParamType, default: nil

    sig { returns(T::Boolean) }
    def live?;    state == :live; end
    sig { returns(T::Boolean) }
    def moved?;   state == :moved; end
    sig { returns(T::Boolean) }
    def specific_move_action?; moved? && !move_action.nil? && move_action != :move; end
    sig { returns(T::Boolean) }
    def dropped?; state == :dropped; end
    # Carrier struct: member stays :type_info; expose the project-wide
    # canonical accessor name so readers use one name everywhere.
    sig { returns(Type) }
    def full_type; type_info; end
    sig { params(val: Type).returns(Type) }
    def full_type=(val); self.type_info = val; end
  end

  class Edge < T::Struct
    const :from, String
    const :to, String
    const :kind, Symbol
  end
  # Edge kinds:
  #   :borrows     — immutable borrow (y borrows x)
  #   :borrows_mut — mutable borrow (y mutably borrows x)

  sig { returns(T::Array[OwnershipGraph::Edge]) }
  attr_reader :edges

  sig { void }
  def initialize
    @nodes = T.let({}, T::Hash[PlaceId, OwnershipGraph::Node])           # place => Node
    @edges = T.let([], T::Array[OwnershipGraph::Edge])           # Array of Edge
    @edges_by_target = T.let(Hash.new { |h, k| h[k] = T.let([], T::Array[OwnershipGraph::Edge]) }, T::Hash[PlaceId, T::Array[OwnershipGraph::Edge]])  # target_place => [Edge]
    @edges_by_source = T.let(Hash.new { |h, k| h[k] = T.let([], T::Array[OwnershipGraph::Edge]) }, T::Hash[PlaceId, T::Array[OwnershipGraph::Edge]])  # source_place => [Edge]
    @children = T.let(Hash.new { |h, k| h[k] = T.let(Set.new, T::Set[PlaceId]) }, T::Hash[PlaceId, T::Set[PlaceId]])    # parent_place => Set of child places
    @completed_nodes = T.let({}, T::Hash[PlaceId, OwnershipGraph::Node])
    @scope_depth = T.let(0, Integer)
  end

  sig { returns(Integer) }
  def scope_depth
    @scope_depth
  end

  sig { returns(Integer) }
  def push_scope!
    clear_completed_snapshot! if @scope_depth.zero?
    @scope_depth = @scope_depth + 1
  end

  sig { params(archive: T::Boolean).returns(Integer) }
  def pop_scope!(archive: false)
    prune_scope!(@scope_depth, archive: archive)
    @scope_depth = @scope_depth - 1
  end

  sig { returns(T::Hash[String, OwnershipGraph::Node]) }
  def nodes
    out = T.let({}, T::Hash[String, OwnershipGraph::Node])
    @completed_nodes.each { |place, node| out[place.path] = node }
    @nodes.each { |place, node| out[place.path] = node }
    out
  end

  sig { void }
  def clear_completed_snapshot!
    @completed_nodes = {}
  end

  # ── Edge index helpers ────────────────────────────────────────────

  sig { params(edge: OwnershipGraph::Edge).returns(OwnershipGraph::Edge) }
  def add_edge(edge)
    @edges << edge
    edges_to(edge.to) << edge
    edges_from(edge.from) << edge
    edge
  end

  sig { params(edge: OwnershipGraph::Edge).returns(T.nilable(OwnershipGraph::Edge)) }
  def remove_edge(edge)
    @edges.delete(edge)
    edges_to(edge.to).delete(edge)
    edges_from(edge.from).delete(edge)
  end

  # ── Core Operations ───────────────────────────────────────────────

  # Declare a new variable or field path.
  sig { params(path: String, kind: Symbol, type_info: Type, scope_depth: Integer, line: Integer).returns(T.nilable(T::Set[String])) }
  def declare(path, kind: :affine, type_info: Type.new(:Any), scope_depth: 0, line: 0)
    place = place_id(path)
    @nodes[place] = Node.new(
      path: path, kind: kind, state: :live,
      type_info: type_info, scope_depth: scope_depth, line: line
    )
    # Register as child of parent path (e.g., "x.child" is child of "x")
    parent = place.parent
    children_for_place(parent).add(place) if parent
    nil
  end

  # Move ownership from source to target. Invalidates source and all children.
  sig { params(from: String, to: String, at_token: T.nilable(Lexer::Token), action: Symbol).returns(T.nilable(T::Set[String])) }
  def transfer(from, to, at_token: nil, action: :move)
    source = node_for(from)
    return unless source

    # Create target node with source's type
    @nodes[place_id(to)] = Node.new(
      path: to, kind: source.kind, state: :live,
      type_info: source.full_type, scope_depth: source.scope_depth, line: source.line
    )

    # Invalidate source and all owned children; record the move site
    # (when a token is given) so `clear fix` can locate where the
    # consuming reference lives.
    record_move_site(source, at_token, action)
    invalidate(from, source)
  end

  sig { params(path: String, at_token: T.nilable(Lexer::Token), action: Symbol, consumer_param_type: MoveConsumerParamType).returns(T.nilable(T::Set[String])) }
  def mark_moved(path, at_token: nil, action: :move, consumer_param_type: nil)
    source = node_for(path)
    return unless source
    record_move_site(source, at_token, action, consumer_param_type: consumer_param_type)
    invalidate(path, source)
  end

  # Add a borrow edge. Returns nil on success, error string on conflict.
  sig { params(borrower: String, source: String, mutable: T::Boolean).returns(T.nilable(String)) }
  def borrow(borrower, source, mutable: false)
    source_node = node_for(source)
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
    to_remove = edges_from(borrower).select { |e| e.kind == :borrows || e.kind == :borrows_mut }
    to_remove.each { |e| remove_edge(e) }
  end

  # Drop a path and all owned children. Returns list of paths to emit cleanup for.
  sig { params(path: String).returns(T::Array[String]) }
  def drop(path)
    node = node_for(path)
    return [] unless node && node.live?

    # Collect all owned children (depth-first, reverse order for cleanup)
    owned = owned_children(path).reverse
    to_cleanup = (owned + [path]).select { |p| node_for(p)&.live? }

    to_cleanup.each do |p|
      node_to_drop = node_for(p)
      node_to_drop.state = :dropped if node_to_drop
    end

    # Remove borrow edges from/to dropped paths
    dropped_set = to_cleanup.map { |p| place_id(p) }.to_set
    to_remove = @edges.select { |e| dropped_set.include?(place_id(e.from)) || dropped_set.include?(place_id(e.to)) }
    to_remove.each { |e| remove_edge(e) }

    to_cleanup
  end

  sig { params(scope_depth: Integer, archive: T::Boolean).returns(Integer) }
  def prune_scope!(scope_depth, archive: false)
    places = @nodes.select { |_place, node| node.scope_depth >= scope_depth }.keys
    return 0 if places.empty?

    @completed_nodes = places.to_h { |place| [place, T.must(@nodes[place])] } if archive
    place_set = places.to_set
    places.each { |place| @nodes.delete(place) }
    @edges.select { |edge| place_set.include?(place_id(edge.from)) || place_set.include?(place_id(edge.to)) }.each { |edge| remove_edge(edge) }
    @children.each_value { |children| children.subtract(place_set) }
    @children.delete_if { |parent, children| place_set.include?(parent) || children.empty? }
    places.size
  end

  # Check if a path can be written to (no active borrows on it or ancestors).
  sig { params(path: String).returns(T::Boolean) }
  def can_write?(path)
    # Check this path and all ancestors
    current = place_id(path)
    loop do
      return false if edges_to(current).any? { |e| e.kind == :borrows || e.kind == :borrows_mut }
      parent = current.parent
      break unless parent
      current = parent
    end
    true
  end

  # Is the path live?
  sig { params(path: String).returns(T::Boolean) }
  def live?(path)
    node_for(path)&.live? || false
  end

  # Is the path moved?
  sig { params(path: String).returns(T::Boolean) }
  def moved?(path)
    node_for(path)&.moved? || false
  end

  # ── Branch Analysis ───────────────────────────────────────────────

  # Lightweight snapshot: only saves node states, not full graph.
  # Use for branches that won't declare new nodes (IF/ELSE in flat code).
  sig { returns(LightweightSnapshot) }
  def fork_lightweight
    states = T.let({}, T::Hash[PlaceId, Symbol])
    move_lines = T.let({}, T::Hash[PlaceId, Integer])
    move_cols = T.let({}, T::Hash[PlaceId, Integer])
    move_actions = T.let({}, T::Hash[PlaceId, Symbol])
    @nodes.each do |place, v|
      states[place] = v.state
      move_line = v.move_line
      move_col = v.move_col
      move_action = v.move_action
      move_lines[place] = move_line if move_line
      move_cols[place] = move_col if move_col
      move_actions[place] = move_action if move_action
    end
    LightweightSnapshot.new(
      states: states,
      move_lines: move_lines,
      move_cols: move_cols,
      move_actions: move_actions,
      edge_count: @edges.size,
    )
  end

  # Restore from lightweight snapshot: reset states and truncate edges.
  sig { params(snapshot: LightweightSnapshot).void }
  def restore_lightweight(snapshot)
    snapshot.each_place_state do |place, state|
      node = @nodes[place]
      next unless node

      node.state = state
      node.move_line = snapshot.move_line_for_place(place)
      node.move_col = snapshot.move_col_for_place(place)
      node.move_action = snapshot.move_action_for_place(place)
    end
    target_count = snapshot.edge_count
    while @edges.size > target_count
      remove_edge(T.must(@edges.last))
    end
  end

  # Merge a branch's graph state back. Both branches must agree on
  # moved/dropped state; conflicts are returned as error strings.
  sig { params(other: OwnershipGraph).returns(T::Array[String]) }
  def merge(other)
    errors = T.let([], T::Array[String])
    all_paths = (nodes.keys + other.nodes.keys).uniq

    all_paths.each do |path|
      mine = node_for(path)
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
    other.edges.each do |e|
      key = [e.from, e.to, e.kind]
      unless existing.include?(key)
        existing.add(key)
        add_edge(Edge.new(from: e.from, to: e.to, kind: e.kind))
      end
    end

    errors
  end

  # ── Queries ───────────────────────────────────────────────────────

  # Get the node for a path.
  sig { params(path: String).returns(T.nilable(OwnershipGraph::Node)) }
  def [](path)
    node_for(path) || @completed_nodes[place_id(path)]
  end

  # All paths that are children of the given path.
  sig { params(path: String).returns(T::Array[String]) }
  def owned_children(path)
    result = []
    collect_descendants(path, result)
    result.sort
  end

  private

  sig { params(path: String, move_source: T.nilable(OwnershipGraph::Node)).returns(T.nilable(T::Set[String])) }
  def invalidate(path, move_source = nil)
    node = node_for(path)
    return unless node
    if move_source && node != move_source
      node.move_line = move_source.move_line
      node.move_col = move_source.move_col
      node.move_action = move_source.move_action
    end
    node.state = :moved
    children_for(path).each do |child|
      invalidate(child.path, move_source)  # recurse for nested children
    end
    nil
  end

  sig { params(node: OwnershipGraph::Node, at_token: T.nilable(Lexer::Token), action: Symbol, consumer_param_type: MoveConsumerParamType).returns(T.nilable(Integer)) }
  def record_move_site(node, at_token, action, consumer_param_type: nil)
    node.move_action = action
    node.move_consumer_param_type = consumer_param_type if consumer_param_type
    return unless at_token

    node.move_line = at_token.line
    node.move_col  = at_token.column
  end

  sig { params(path: String, result: T::Array[String]).returns(T::Set[String]) }
  def collect_descendants(path, result)
    children_for(path).each do |child|
      result << child.path
      collect_descendants(child.path, result)
    end
    result.to_set
  end

  sig { params(path: String).returns(T.nilable(String)) }
  def find_borrow_conflict(path)
    b = edges_to(path).find { |e| e.kind == :borrows || e.kind == :borrows_mut }
    return nil unless b
    borrower_node = node_for(b.from)
    line_info = borrower_node ? " (declared at line #{borrower_node.line})" : ""
    "cannot borrow '#{path}' mutably: already borrowed by '#{b.from}'#{line_info}"
  end

  sig { params(path: String).returns(T.nilable(String)) }
  def find_mutable_borrow(path)
    b = edges_to(path).find { |e| e.kind == :borrows_mut }
    return nil unless b
    "cannot borrow '#{path}': mutably borrowed by '#{b.from}'"
  end

  sig { params(path: T.any(String, PlaceId)).returns(T::Array[OwnershipGraph::Edge]) }
  def edges_to(path)
    @edges_by_target[place_id(path)] ||= T.let([], T::Array[OwnershipGraph::Edge])
  end

  sig { params(path: T.any(String, PlaceId)).returns(T::Array[OwnershipGraph::Edge]) }
  def edges_from(path)
    @edges_by_source[place_id(path)] ||= T.let([], T::Array[OwnershipGraph::Edge])
  end

  sig { params(path: String).returns(T::Set[PlaceId]) }
  def children_for(path)
    children_for_place(place_id(path))
  end

  sig { params(place: PlaceId).returns(T::Set[PlaceId]) }
  def children_for_place(place)
    @children[place] ||= T.let(Set.new, T::Set[PlaceId])
  end

  sig { params(path: T.any(String, PlaceId)).returns(PlaceId) }
  def place_id(path)
    PlaceId.from_path(path)
  end

  sig { params(path: String).returns(T.nilable(OwnershipGraph::Node)) }
  def node_for(path)
    @nodes[place_id(path)] || @completed_nodes[place_id(path)]
  end

end
