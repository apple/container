import Foundation
import Logging
import ComposeCore

@main
struct ComposeDebugCLI {
    static func main() {
        // Minimal placeholder to satisfy SPM when composing the package.
        // This target is not used in release packaging; it exists for local debugging.
        Logger(label: "compose-debug").info("compose-debug stub running")
    }
}

