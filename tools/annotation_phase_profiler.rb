# frozen_string_literal: true

# Tool-only timing probe for the three annotation phases. The compiler keeps
# these phases free of profiler concerns; profiling tools install this probe
# after loading the annotator.
module AnnotationPhaseProfiler
  Record = Struct.new(
    :calls,
    :inclusive_seconds,
    :self_seconds,
    :inclusive_allocations,
    :self_allocations,
    keyword_init: true
  )
  Frame = Struct.new(:name, :started_at, :started_allocations, :child_seconds, :child_allocations, :previous_label,
                     keyword_init: true)

  PHASES = {
    "resolution" => Annotator::Phases::ResolutionPhase,
    "type_analysis" => Annotator::Phases::TypeAnalysisPhase,
    "capability_audit" => Annotator::Phases::CapabilityAuditPhase,
  }.freeze

  @records = Hash.new do |hash, name|
    hash[name] = Record.new(
      calls: 0,
      inclusive_seconds: 0.0,
      self_seconds: 0.0,
      inclusive_allocations: 0,
      self_allocations: 0
    )
  end
  @stacks = Hash.new { |hash, thread_id| hash[thread_id] = [] }
  @listener = nil
  @installed = false

  class << self
    attr_reader :records

    def install!(listener: nil)
      @listener = listener
      return if @installed

      PHASES.each do |name, phase_class|
        wrapper = Module.new do
          define_method(:run) do |*args, **kwargs, &block|
            AnnotationPhaseProfiler.track(name) { super(*args, **kwargs, &block) }
          end
        end
        phase_class.singleton_class.prepend(wrapper)
      end
      @installed = true
    end

    def reset!(listener: @listener)
      @records.clear
      @stacks.clear
      @listener = listener
    end

    def track(name)
      stack = @stacks[Thread.current.object_id]
      previous_label = @listener&.phase
      frame = Frame.new(
        name: name,
        started_at: monotonic_time,
        started_allocations: allocated_objects,
        child_seconds: 0.0,
        child_allocations: 0,
        previous_label: previous_label
      )
      stack << frame
      @listener.phase = "annotate.#{name}" if @listener
      yield
    ensure
      elapsed = monotonic_time - frame.started_at
      allocations = allocated_objects - frame.started_allocations
      stack.pop

      record = @records[name]
      record.calls += 1
      record.inclusive_seconds += elapsed
      record.self_seconds += elapsed - frame.child_seconds
      record.inclusive_allocations += allocations
      record.self_allocations += allocations - frame.child_allocations

      if (parent = stack.last)
        parent.child_seconds += elapsed
        parent.child_allocations += allocations
      end
      @listener.phase = frame.previous_label if @listener
    end

    def report(io: $stdout, annotation_total: nil)
      io.puts "== annotation phases =="
      PHASES.each_key do |name|
        record = @records[name]
        io.puts format(
          "%18s %10.6f self %10.6f incl %5d calls %10d self_alloc",
          name,
          record.self_seconds,
          record.inclusive_seconds,
          record.calls,
          record.self_allocations
        )
      end

      accounted = PHASES.keys.sum { |name| @records[name].self_seconds }
      io.puts format("%18s %10.6f", "accounted", accounted)
      return unless annotation_total

      io.puts format("%18s %10.6f", "annotation_total", annotation_total)
      io.puts format("%18s %10.6f", "outside_phases", annotation_total - accounted)
    end

    def serializable_records
      PHASES.keys.to_h do |name|
        record = @records[name]
        [name, {
          calls: record.calls,
          inclusive_seconds: record.inclusive_seconds,
          self_seconds: record.self_seconds,
          inclusive_allocations: record.inclusive_allocations,
          self_allocations: record.self_allocations,
        }]
      end
    end

    private

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def allocated_objects
      GC.stat(:total_allocated_objects)
    end
  end
end
