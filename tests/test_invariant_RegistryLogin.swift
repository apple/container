import XCTest
import Foundation
@testable import ContainerCommands

final class RegistryLoginSecurityTests: XCTestCase {
    
    /// Invariant: BasicAuthentication credentials must only be transmitted over HTTPS, never HTTP
    func testCredentialsRequireHTTPS() throws {
        // Test cases: schemes that should be rejected for credential transmission
        let unsafeSchemes = [
            "http",      // Exact exploit case - cleartext HTTP
            "HTTP",      // Case variation boundary
            "",          // Empty/missing scheme
        ]
        
        for scheme in unsafeSchemes {
            let requestScheme = RequestScheme(scheme)
            let resolvedScheme = requestScheme.schemeFor()
            
            // Security invariant: credentials should never be sent over non-HTTPS
            // If scheme resolves to anything other than "https", it's a security violation
            XCTAssertEqual(
                resolvedScheme.lowercased(),
                "https",
                "Security violation: BasicAuthentication credentials would be transmitted over '\(resolvedScheme)' instead of HTTPS for input scheme '\(scheme)'"
            )
        }
    }
    
    /// Invariant: HTTPS schemes must be preserved and used for credential transmission
    func testHTTPSSchemesArePreserved() throws {
        let safeSchemes = [
            "https",     // Valid secure scheme
            "HTTPS",     // Case variation
        ]
        
        for scheme in safeSchemes {
            let requestScheme = RequestScheme(scheme)
            let resolvedScheme = requestScheme.schemeFor()
            
            XCTAssertEqual(
                resolvedScheme.lowercased(),
                "https",
                "HTTPS scheme '\(scheme)' should resolve to 'https', got '\(resolvedScheme)'"
            )
        }
    }
    
    /// Invariant: Registry URLs without explicit HTTPS must default to secure transport
    func testDefaultSchemeIsSecure() throws {
        // When no scheme is provided, the default must be HTTPS for credential safety
        let emptyScheme = RequestScheme("")
        let nilScheme = RequestScheme(nil)
        
        XCTAssertEqual(
            emptyScheme.schemeFor().lowercased(),
            "https",
            "Empty scheme must default to HTTPS for credential protection"
        )
        
        XCTAssertEqual(
            nilScheme.schemeFor().lowercased(),
            "https",
            "Nil scheme must default to HTTPS for credential protection"
        )
    }
}