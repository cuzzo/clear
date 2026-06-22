# frozen_string_literal: true

if GLOBAL_USER
  if GLOBAL_FEATURE
    boot("top-level")
  end
end

class SourceFactPathConditionReport
  def first(user, feature, enabled)
    if user
      if feature
        if enabled
          record(
            "first",
            "abcdefghijklmnopqrstuvwxyz",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            "0123456789"
          )
        end
      end
    end
  end

  def second(user, feature, enabled)
    if user
      if feature
        if enabled
          record("second")
        end
      end
    end
  end

  def third(user, feature, enabled)
    if user
      if feature
        if enabled
          record("third")
        end
      end
    end
  end

  def missing_enabled(user, feature)
    if user
      if feature
        record("missing enabled")
      end
    end
  end

  def duplicate_guard(user)
    if user
      if user
        record("duplicate guard")
      end
    end
  end
end
