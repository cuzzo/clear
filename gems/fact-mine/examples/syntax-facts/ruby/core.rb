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

    items.flat_map do |item|
      item.children
    end

    @status
  end

  private

  def audit(name)
    puts(name)
    send(:record, name)
    $GLOBAL_STATE
    @source
  end

  private def inline_private(value)
    helper(value)
  end

  def ready?
    @count > 0
  end

  def loaded? = @status == :ready
end
