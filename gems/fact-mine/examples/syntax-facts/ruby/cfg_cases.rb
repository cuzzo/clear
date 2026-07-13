class CfgCases
  def dispatch(role, user)
    case role
    when :owner
      publish(user)
    when :guest, :visitor
      invite(user)
    else
      ignore(user)
    end
    finish(user)
  end

  def missing_default(role, user)
    case role
    when :owner
      publish(user)
    end
    finish(user)
  end

  def predicate_case(user)
    case
    when user.ready?
      publish(user)
    else
      ignore(user)
    end
    finish(user)
  end

  def loop_break(items)
    items.each do |item|
      case item.status
      when :done
        break
      else
        publish(item)
      end
    end
    finish(items)
  end
end
