import Testing
@testable import Perch

struct DevServerClassifierTests {
    private let home = "/Users/dev"

    private func kind(_ executable: String, _ arguments: [String]) -> DevServerKind? {
        DevServerClassifier.classify(executable: executable, arguments: arguments, home: home)
    }

    @Test(arguments: [
        (["node", "/p/web/node_modules/.bin/next", "dev"], "Next.js"),
        (["next-server (v15.1.0)"], "Next.js"),
        (["node", "/p/app/node_modules/.bin/vite"], "Vite"),
        (["node", "/p/app/node_modules/vite/bin/vite.js", "--port", "5173"], "Vite"),
        (["node", "/p/app/server.js"], "Node.js"),
    ])
    func namesNodeFrameworks(arguments: [String], expected: String) {
        #expect(kind("/opt/homebrew/bin/node", arguments)?.name == expected)
    }

    @Test func pythonInsideAnAppBundleIsStillListed() {
        let python = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        #expect(kind(python, [python, "-m", "http.server", "8000"])?.name == "Python HTTP")
        #expect(kind(python, [python, "manage.py", "runserver"])?.name == "Django")
        #expect(kind(python, [python, "worker.py"])?.name == "Python")
    }

    @Test func databasesDoNotOpenInTheBrowser() {
        let postgres = kind("/opt/homebrew/Cellar/postgresql@16/16.4/bin/postgres", ["postgres", "-D", "/opt/homebrew/var/postgresql@16"])
        #expect(postgres == DevServerKind(name: "PostgreSQL", isWeb: false))
    }

    @Test(arguments: [
        "/Applications/Discord.app/Contents/MacOS/Discord",
        "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
        "/usr/libexec/rapportd",
        "/Library/Application Support/Logitech/logi_agent",
        "/Users/dev/Library/Android/sdk/platform-tools/adb",
    ])
    func appsAndSystemServicesAreHidden(executable: String) {
        #expect(kind(executable, [executable]) == nil)
    }

    @Test func codingAgentsAreHidden() {
        #expect(kind("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/claude"]) == nil)
        #expect(kind("/Users/dev/.bun/bin/bun", ["bun", "/Users/dev/.bun/bin/omp", "--mode", "rpc-ui"]) == nil)
        #expect(kind("/Users/dev/.bun/install/global/node_modules/@opencode/cli/bin/opencode.exe", ["opencode"]) == nil)
        #expect(kind("/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"]) == nil)
    }

    @Test func projectBinaryFallsBackToItsName() {
        #expect(kind("/Users/dev/code/api/bin/api-server", ["./bin/api-server"]) == DevServerKind(name: "api-server", isWeb: true))
    }

    @Test func rootAndHomeAreNotProjects() {
        #expect(DevServerClassifier.projectDirectory("/", home: home) == nil)
        #expect(DevServerClassifier.projectDirectory(home, home: home) == nil)
        #expect(DevServerClassifier.projectDirectory("/Users/dev/code/web", home: home) == "/Users/dev/code/web")
    }
}
