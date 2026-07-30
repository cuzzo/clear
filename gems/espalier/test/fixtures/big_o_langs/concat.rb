class Concat
  def build(parts)
    out = ""
    parts.each { |part| out = out + part }
    out
  end
end
