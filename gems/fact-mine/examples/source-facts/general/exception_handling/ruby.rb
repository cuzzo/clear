def method_two
  begin
    raise "err"
  rescue StandardError => e
    log(e)
  ensure
    cleanup
  end
end
