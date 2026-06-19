class Worker {
  fun run(items: Items) {
    this.prepare()
    if (this.ready()) {
      this.validate()
    }
    for (item in items) {
      this.helper(item)
    }
  }

  private fun prepare() {}
  private fun ready(): Boolean { return true }
  fun validate() {}
  private fun helper(item: Item) { item.use() }
}
