def method_six(obj, index, key)
  self.cache.status = obj[key]
  self.cache[index].status = 1
  @cache.clear
end
