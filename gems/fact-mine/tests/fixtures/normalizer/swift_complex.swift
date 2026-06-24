class Billing {
    func mixed(price: Int, tax: Int) -> Int {
        return price + tax
    }
    
    func loops() {
        for i in 0..<10 {
            if i % 2 == 0 { continue }
        }
        var x = 0
        repeat {
            x += 1
        } while x < 10
    }
}
