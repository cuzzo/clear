class Billing {
    fun mixed(price: Int, tax: Int): Int {
        val result = try {
            price + tax
        } catch (e: Exception) {
            0
        } finally {
            println("Done")
        }
        return result
    }
    
    fun loops() {
        for (i in 0..10) {
            if (i % 2 == 0) continue
        }
        var x = 0
        while (x < 10) {
            x++
        }
    }
}
