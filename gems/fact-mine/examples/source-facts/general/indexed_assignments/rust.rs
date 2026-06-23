fn method_six(obj: &[i32], index: usize, key: usize) {
    self.cache.status = obj[key];
    self.cache[index].status = 1;
    self.cache.clear();
}
