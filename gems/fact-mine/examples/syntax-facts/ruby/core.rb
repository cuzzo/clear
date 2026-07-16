# frozen_string_literal: true

class Account < T::Struct
  const :name, String
  prop :active, T::Boolean
end

class RubySyntaxFactsCore
  ADMIN_ROLES = %w[owner admin].freeze
  Status = T.type_alias { Symbol }

  attr_reader :count

  def self.build(source)
    new(source)
  end

  sig { params(source: Object).void }
  def initialize(source)
    @source = source
    @count = T.let(0, Integer)
    @status = T.let(:idle, Status)
  end

  sig { params(user: Object, items: Array, callback: Proc).returns(Symbol) }
  def process(user, items, callback)
    name = user&.profile&.name
    account = Account.new(name: name, active: user.active?)
    audit(name)
    callback.(account)

    case user.role
    when "owner", *ADMIN_ROLES
      escalate(user)
    when nil
      fallback(user)
    else
      default(user)
    end

    if @status == :idle && user.ready?
      @count += 1
      publish(:ready)
    else
      warn("not ready")
    end

    items.each do |(a, b)|
      puts a
    end

    super(user, items, callback)

    @status
  end

  private

  def audit(name)
    puts(name)
    send(:record, name)
    $GLOBAL_STATE
    $1
    { count: }
    `ls`
    `ls #{@count}`
    chained = "hello" "world"
    heredoc = <<~EOF
      hello
    EOF
    logical = nil
    logical ||= 1
    $GLOBAL_STATE += 1
    local_val = 1
    audit !name
    return audit(name)
  end

  private def inline_private(value)
    helper(value)
  end

  private def self.inline_class_private(value)
    helper(value)
  end

  private_class_method def self.inline_class_private2(value)
    helper(value)
  end

  def one_line_return; return 42; end

  def rescue_test
    begin
      foo
    rescue => e
    end
    begin
      foo
    rescue => e
      bar
      baz
    end
  end

  def ensure_only_test
    begin
      foo
    ensure
      bar
    end
  end

  def ready?
    @count > 0
  end

  def loaded? = @status == :ready

  def source_or_default(source = @source)
    source
  end
end

if $GLOBAL_STATE > 0
  puts "active"
else
  puts "inactive"
end
