# Template: exhaustive loop-frame rewind discovery across loop syntax,
# sequential control-flow containers, and destination-sensitive allocation.
#
# This complements the older loop templates, which cover cleanup disruptors,
# escaping collections, and declaration-time method temporaries. Its primary
# regression is the two-phase binding shape:
#
#   MUTABLE temp: String = "";
#   temp = COPY borrowed_value;
#
# COPY is annotated as heap-producing without a destination, while assignment
# lowering evaluates it with the finalized binding allocator. If that binding
# is iteration-frame scoped, LoopFrameAnalysis must still synthesize a rewind.
# Missing rewinds are rejected by MIRChecker, so every passing cell is both a
# compile-time ownership oracle and a runtime leak/UAF oracle.

LRM_LOOP_KINDS = %i[while for_range for_each while_bind].freeze
LRM_CONTAINERS = %i[
  direct if_then if_else if_bind_then if_bind_else match_arm match_default
  nested_if_match with
].freeze
LRM_PRODUCERS = %i[copy concat substring].freeze
LRM_DISRUPTORS = %i[continue break early_return raise].freeze

LOOP_REWIND_MATRIX_CELLS = []
LRM_LOOP_KINDS.each do |loop_kind|
  LRM_CONTAINERS.each do |container|
    LRM_PRODUCERS.each do |producer|
      LOOP_REWIND_MATRIX_CELLS << {
        scenario: :container_matrix,
        loop_kind: loop_kind,
        container: container,
        producer: producer,
      }
    end
  end
end

# Nested marks are independent: allocating only in the outer loop, only in the
# inner loop, or in both must produce the corresponding set of rewinds. Cover
# every nesting-friendly loop form; WHILE-bind is covered as both a normal and
# disrupting top-level loop below without introducing a reset allocation that
# would contaminate the outer-loop placement oracle.
%i[while for_range for_each].each do |loop_kind|
  %i[outer inner both].each do |placement|
    LRM_PRODUCERS.each do |producer|
      LOOP_REWIND_MATRIX_CELLS << {
        scenario: :nested,
        loop_kind: loop_kind,
        placement: placement,
        producer: producer,
      }
    end
  end
end

# A defer-based rewind must run through every abrupt iteration exit. The
# existing cleanup matrix covers declaration-time allocations; these cells
# specifically preserve the destination-sensitive reassignment shape that
# caused the bug, across all four loop forms.
LRM_LOOP_KINDS.each do |loop_kind|
  LRM_DISRUPTORS.each do |disruptor|
    LOOP_REWIND_MATRIX_CELLS << {
      scenario: :disruptor,
      loop_kind: loop_kind,
      disruptor: disruptor,
    }
  end
end

# Marked loops must remain correct when their body executes zero times.
LRM_LOOP_KINDS.each do |loop_kind|
  LOOP_REWIND_MATRIX_CELLS << { scenario: :zero_iterations, loop_kind: loop_kind }
end

# TIGHT loops intentionally do not rewind each iteration; allocating bodies
# remain legal and retain function-frame lifetime. Keep that policy boundary
# in the same matrix so a rewind fix cannot accidentally reject TIGHT code.
LRM_PRODUCERS.each do |producer|
  LOOP_REWIND_MATRIX_CELLS << { scenario: :tight, producer: producer }
end

# Scalar COPY is a bit copy and must not be mistaken for an allocating COPY.
LRM_LOOP_KINDS.each do |loop_kind|
  LOOP_REWIND_MATRIX_CELLS << { scenario: :bit_copy, loop_kind: loop_kind }
end

def lrm_expression(producer, source = "base_source")
  case producer
  when :copy then "COPY #{source}"
  when :concat then "#{source} $+ i.toString()"
  when :substring then "#{source}.substr(0_i64, 3_i64)"
  end
end

def lrm_assignment(producer, source = "base_source")
  expression = lrm_expression(producer, source)
  "temp = #{expression}; ASSERT temp.length() >= 3_i64;"
end

def lrm_control_body(container, producer)
  assignment = lrm_assignment(producer)
  case container
  when :direct
    assignment
  when :if_then
    "IF i >= 0_i64 THEN #{assignment} END"
  when :if_else
    "IF i < 0_i64 THEN PASS; ELSE #{assignment} END"
  when :if_bind_then
    "IF maybe_source EXISTS AS source THEN #{lrm_assignment(producer, 'source')} END"
  when :if_bind_else
    "IF empty_sources[0_i64] EXISTS AS source THEN PASS; ELSE #{assignment} END"
  when :match_arm
    <<~CLEAR.chomp
      PARTIAL MATCH tagged START
        RewindValue.Str AS source -> #{lrm_assignment(producer, 'source')},
        DEFAULT -> PASS;
      END
    CLEAR
  when :match_default
    <<~CLEAR.chomp
      PARTIAL MATCH untagged START
        RewindValue.Str AS source -> PASS;,
        DEFAULT -> #{assignment}
      END
    CLEAR
  when :nested_if_match
    <<~CLEAR.chomp
      IF i >= 0_i64 THEN
        PARTIAL MATCH tagged START
          RewindValue.Str AS source -> #{lrm_assignment(producer, 'source')},
          DEFAULT -> PASS;
        END
      END
    CLEAR
  when :with
    expression = lrm_expression(producer, "view.value")
    "WITH locked_source AS view { temp = #{expression}; ASSERT temp.length() >= 3_i64; }"
  end
end

def lrm_loop(loop_kind, body, iterations: 3)
  indented = "      ASSERT i >= 0_i64;\n"
  indented += body.lines.map { |line| "      #{line}" }.join
  indented += "\n" unless indented.end_with?("\n")
  case loop_kind
  when :while
    <<~CLEAR.chomp
      MUTABLE i = 0_i64;
      WHILE i < #{iterations}_i64 DO
      #{indented}  i += 1_i64;
      END
    CLEAR
  when :for_range
    <<~CLEAR.chomp
      FOR i IN (0_i64 ..< #{iterations}_i64) DO
      #{indented}END
    CLEAR
  when :for_each
    <<~CLEAR.chomp
      FOR i IN indices DO
      #{indented}END
    CLEAR
  when :while_bind
    <<~CLEAR.chomp
      WHILE &remaining.pop() EXISTS AS i DO
      #{indented}END
    CLEAR
  end
end

def lrm_support
  <<~CLEAR.chomp
    UNION RewindValue { Nil, Str: String }
    STRUCT RewindBox { value: String }
  CLEAR
end

def lrm_setup
  <<~CLEAR.chomp
    base_source = "seed";
    maybe_source: ?String = "seed";
    empty_sources: []String = [];
    tagged = RewindValue{ Str: "seed" };
    untagged = RewindValue.Nil;
    locked_source = RewindBox{ value: "seed" } @locked;
    indices: []Int64 = [0_i64, 1_i64, 2_i64];
    MUTABLE remaining: []Int64 = [2_i64, 1_i64, 0_i64];
  CLEAR
end

def lrm_container_program(params)
  temp_decl = params[:container] == :with ? nil : 'MUTABLE temp: String = "";'
  body = <<~CLEAR.chomp
    #{temp_decl}
    #{lrm_control_body(params[:container], params[:producer])}
  CLEAR
  <<~CLEAR
    #{lrm_support}

    FN main() RETURNS !Void ->
      #{lrm_setup.lines.join('  ')}
      #{lrm_loop(params[:loop_kind], body).lines.join('  ')}
      RETURN;
    END
  CLEAR
end

def lrm_nested_program(params)
  assignment = lrm_assignment(params[:producer])
  outer_body = params[:placement] == :inner ? "PASS;" : assignment
  inner_body = params[:placement] == :outer ? "PASS;" : assignment
  nested = case params[:loop_kind]
  when :while
    <<~CLEAR.chomp
      MUTABLE i = 0_i64;
      WHILE i < 2_i64 DO
        ASSERT i >= 0_i64;
        MUTABLE temp: String = "";
        #{outer_body}
        MUTABLE j = 0_i64;
        WHILE j < 2_i64 DO
          ASSERT j >= 0_i64;
          MUTABLE temp: String = "";
          #{inner_body}
          j += 1_i64;
        END
        i += 1_i64;
      END
    CLEAR
  when :for_range
    <<~CLEAR.chomp
      FOR i IN (0_i64 ..< 2_i64) DO
        ASSERT i >= 0_i64;
        MUTABLE temp: String = "";
        #{outer_body}
        FOR j IN (0_i64 ..< 2_i64) DO
          ASSERT j >= 0_i64;
          MUTABLE temp: String = "";
          #{inner_body}
        END
      END
    CLEAR
  when :for_each
    <<~CLEAR.chomp
      indices: []Int64 = [0_i64, 1_i64];
      FOR i IN indices DO
        ASSERT i >= 0_i64;
        MUTABLE temp: String = "";
        #{outer_body}
        FOR j IN indices DO
          ASSERT j >= 0_i64;
          MUTABLE temp: String = "";
          #{inner_body}
        END
      END
    CLEAR
  end
  <<~CLEAR
    FN main() RETURNS !Void ->
      base_source = "seed";
      #{nested.lines.join('  ')}
      RETURN;
    END
  CLEAR
end

def lrm_disruptor_program(params)
  disruptor = case params[:disruptor]
  when :continue
    prefix = params[:loop_kind] == :while ? "i += 1_i64; " : ""
    "IF i == 1_i64 THEN #{prefix}CONTINUE; END"
  when :break
    "IF i == 1_i64 THEN BREAK; END"
  when :early_return
    "IF i == 1_i64 THEN RETURN; END"
  when :raise
    "IF i == 1_i64 THEN RAISE; END"
  end
  body = <<~CLEAR.chomp
    MUTABLE temp: String = "";
    #{lrm_assignment(:copy)}
    #{disruptor}
  CLEAR
  <<~CLEAR
    #{lrm_support}

    FN run() RETURNS !Void ->
      #{lrm_setup.lines.join('  ')}
      #{lrm_loop(params[:loop_kind], body).lines.join('  ')}
      RETURN;
    END

    FN main() RETURNS Void ->
      run() OR_ELSE PASS;
      RETURN;
    END
  CLEAR
end

def lrm_zero_iteration_program(params)
  body = <<~CLEAR.chomp
    MUTABLE temp: String = "";
    #{lrm_assignment(:copy)}
  CLEAR
  setup = lrm_setup
    .sub('indices: []Int64 = [0_i64, 1_i64, 2_i64];', 'indices: []Int64 = [];')
    .sub('MUTABLE remaining: []Int64 = [2_i64, 1_i64, 0_i64];', 'MUTABLE remaining: []Int64 = [];')
  <<~CLEAR
    #{lrm_support}

    FN main() RETURNS !Void ->
      #{setup.lines.join('  ')}
      #{lrm_loop(params[:loop_kind], body, iterations: 0).lines.join('  ')}
      RETURN;
    END
  CLEAR
end

def lrm_tight_program(params)
  <<~CLEAR
    FN main() RETURNS !Void ->
      base_source = "seed";
      MUTABLE i = 0_i64;
      TIGHT WHILE i < 3_i64 DO
        MUTABLE temp: String = "";
        #{lrm_assignment(params[:producer])}
        i += 1_i64;
      END
      RETURN;
    END
  CLEAR
end

def lrm_bit_copy_program(params)
  body = "MUTABLE copied = 0_i64; copied = COPY i; ASSERT copied == i;"
  <<~CLEAR
    FN main() RETURNS Void ->
      indices: []Int64 = [0_i64, 1_i64, 2_i64];
      MUTABLE remaining: []Int64 = [2_i64, 1_i64, 0_i64];
      #{lrm_loop(params[:loop_kind], body).lines.join('  ')}
      RETURN;
    END
  CLEAR
end

FuzzGenerator.register(:loop_rewind_matrix, cells: LOOP_REWIND_MATRIX_CELLS) do |params|
  case params[:scenario]
  when :container_matrix then lrm_container_program(params)
  when :nested then lrm_nested_program(params)
  when :disruptor then lrm_disruptor_program(params)
  when :zero_iterations then lrm_zero_iteration_program(params)
  when :tight then lrm_tight_program(params)
  when :bit_copy then lrm_bit_copy_program(params)
  end
end
