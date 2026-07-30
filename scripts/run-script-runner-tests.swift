import Foundation

@main
struct TestRunner {
    static func main() async {
        do {
            try ScriptRunnerTests.runAllTests()
        } catch {
            print("❌ Test failed: \(error)")
            exit(1)
        }
    }
}
