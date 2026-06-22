# frozen_string_literal: true

class SourceFactStateReads
  def initialize(user)
    @user = user
    @status = :idle
  end

  def inspect_profile(account)
    name = @user.profile&.name
    status = @status
    account.active? && status == :idle && name
  end
end
