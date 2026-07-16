class CoverageCases
  extend T::Sig

  # 1. T.noreturn handling in Sorbet signatures
  sig { returns(T.noreturn) }
  def raises_error; raise "error"; end

  sig { returns(T.any(Integer, T.noreturn)) }
  def mixed_noreturn; 42; end

  sig { params(cond: T::Boolean).void }
  def initialize(cond)
    # 2. Instance variable T.let annotations inside constructor
    @x = T.let(1, Integer)
    @hash = T.let({}, T::Hash[Symbol, String])
    @array_field = T.let([], T::Array[String])
    @cond = cond
  end

  sig { params(y: Integer).void }
  def test_mutations(y)
    # 3. Collection and Hash mutations (<<, push, []=, merge!)
    @array_field << "test"
    @array_field.push("item")
    @hash[:key] = "value"
    @hash.merge!(other: "val")
    @hash.update(another: "val")
  end

  sig { params(cond: T::Boolean).void }
  def test_conditionals(cond)
    # 4. Conditional merging & branch syntax type checks (unless, case, rescue)
    if cond
      a = "then_branch"
    else
      # Variable only defined in else, or different types
      a = 42
    end

    unless cond
      b = :unless_branch
    end

    case cond
    when Integer
      c = cond
    end

    begin
      d = 1
    rescue => e
      d = 2
    end
  end

  sig { params(val: Integer).void }
  def test_non_nil_checks(val)
    # 5. Non-nil checks on self and safe-navigation / nil?
    self.test_mutations(1)

    x = T.let(5, Integer)
    x&.to_s
    x.nil?
  end

  sig { void }
  def test_block_params
    # 6. Block parameters on collections (each, map)
    {a: "val"}.each do |k, v|
      k.to_s
      v.to_s
    end
    ["string"].each do |item|
      item.to_s
    end
  end
end
