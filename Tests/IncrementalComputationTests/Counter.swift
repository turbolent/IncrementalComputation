actor Counter {
    private var count = 0

    func increment() -> Int {
        self.count += 1
        return self.count
    }

    var value: Int {
        self.count
    }
}
