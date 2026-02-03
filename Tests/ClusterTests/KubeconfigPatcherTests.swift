import XCTest
@testable import ClusterCommands

final class KubeconfigPatcherTests: XCTestCase {
    func testPatchRewritesServerAndNames() {
        let raw = """
        apiVersion: v1
        kind: Config
        clusters:
        - cluster:
            server: https://10.0.0.1:6443
          name: kubernetes
        contexts:
        - context:
            cluster: kubernetes
            user: kubernetes-admin
          name: kubernetes-admin@kubernetes
        current-context: kubernetes-admin@kubernetes
        users:
        - name: kubernetes-admin
          user:
            token: example
        """

        let patched = KubeconfigManager.patch(raw: raw, clusterName: "uds", apiPort: 7443)

        XCTAssertTrue(patched.contains("server: https://127.0.0.1:7443"))
        XCTAssertTrue(patched.contains("name: uds"))
        XCTAssertTrue(patched.contains("cluster: uds"))
        XCTAssertTrue(patched.contains("user: admin"))
        XCTAssertTrue(patched.contains("current-context: uds"))
        XCTAssertFalse(patched.contains("kubernetes-admin@kubernetes"))
    }
}
