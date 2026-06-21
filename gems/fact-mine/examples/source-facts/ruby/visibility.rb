# frozen_string_literal: true

class SourceFactVisibility
  def public_step
    prepare
  end

  private

  def prepare
    @ready = true
  end

  protected def inline_guard
    true
  end

  private :inline_guard
end
