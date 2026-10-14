struct ApplyCounter {
    private(set) var value = 0

    mutating func recordSuccess() { value += 1 }
}
