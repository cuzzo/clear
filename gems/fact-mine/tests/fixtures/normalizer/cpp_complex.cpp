int main() {
    try {
        throw 1;
    } catch (int e) {
    } catch (...) {
    }
    
    auto lambda = [](int x) { return x * 2; };
    return 0;
}
