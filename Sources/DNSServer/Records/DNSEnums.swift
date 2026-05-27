//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

/// DNS message type (query or response).
public enum MessageType: UInt16, Sendable {
    case query = 0
    case response = 1
}

/// DNS operation code (RFC 1035, 1996, 2136).
public enum OperationCode: UInt8, Sendable {
    case query = 0  // Standard query (RFC 1035)
    case inverseQuery = 1  // Inverse query (obsolete, RFC 3425)
    case status = 2  // Server status request (RFC 1035)
    // 3 is reserved
    case notify = 4  // Zone change notification (RFC 1996)
    case update = 5  // Dynamic update (RFC 2136)
    case dso = 6  // DNS Stateful Operations (RFC 8490)
    // 7-15 reserved
}

/// DNS response return codes (RFC 1035, 2136, 2845, 6895).
public enum ReturnCode: UInt8, Sendable {
    case noError = 0  // No error
    case formatError = 1  // Format error - unable to interpret query
    case serverFailure = 2  // Server failure
    case nonExistentDomain = 3  // Name error - domain does not exist (NXDOMAIN)
    case notImplemented = 4  // Not implemented - query type not supported
    case refused = 5  // Refused - policy restriction
    case yxDomain = 6  // Name exists when it should not (RFC 2136)
    case yxRRSet = 7  // RR set exists when it should not (RFC 2136)
    case nxRRSet = 8  // RR set does not exist when it should (RFC 2136)
    case notAuthoritative = 9  // Server not authoritative (RFC 2136) / Not authorized (RFC 2845)
    case notZone = 10  // Name not in zone (RFC 2136)
    case dsoTypeNotImplemented = 11  // DSO-TYPE not implemented (RFC 8490)
    // 12-15 reserved
    case badSignature = 16  // TSIG signature failure (RFC 2845)
    case badKey = 17  // Key not recognized (RFC 2845)
    case badTime = 18  // Signature out of time window (RFC 2845)
    case badMode = 19  // Bad TKEY mode (RFC 2930)
    case badName = 20  // Duplicate key name (RFC 2930)
    case badAlgorithm = 21  // Algorithm not supported (RFC 2930)
    case badTruncation = 22  // Bad truncation (RFC 4635)
    case badCookie = 23  // Bad/missing server cookie (RFC 7873)
}

/// DNS resource record types (RFC 1035, 3596, 2782, and others).
public enum ResourceRecordType: UInt16, Sendable {
    case host = 1  // A - IPv4 address (RFC 1035)
    case nameServer = 2  // NS - Authoritative name server (RFC 1035)
    case mailDestination = 3  // MD - Mail destination (obsolete, RFC 1035)
    case mailForwarder = 4  // MF - Mail forwarder (obsolete, RFC 1035)
    case alias = 5  // CNAME - Canonical name (RFC 1035)
    case startOfAuthority = 6  // SOA - Start of authority (RFC 1035)
    case mailbox = 7  // MB - Mailbox domain name (experimental, RFC 1035)
    case mailGroup = 8  // MG - Mail group member (experimental, RFC 1035)
    case mailRename = 9  // MR - Mail rename domain name (experimental, RFC 1035)
    case null = 10  // NULL - Null RR (experimental, RFC 1035)
    case wellKnownService = 11  // WKS - Well known service (RFC 1035)
    case pointer = 12  // PTR - Domain name pointer (RFC 1035)
    case hostInfo = 13  // HINFO - Host information (RFC 1035)
    case mailInfo = 14  // MINFO - Mailbox information (RFC 1035)
    case mailExchange = 15  // MX - Mail exchange (RFC 1035)
    case text = 16  // TXT - Text strings (RFC 1035)
    case responsiblePerson = 17  // RP - Responsible person (RFC 1183)
    case afsDatabase = 18  // AFSDB - AFS database location (RFC 1183)
    case x25 = 19  // X25 - X.25 PSDN address (RFC 1183)
    case isdn = 20  // ISDN - ISDN address (RFC 1183)
    case routeThrough = 21  // RT - Route through (RFC 1183)
    case nsapAddress = 22  // NSAP - NSAP address (RFC 1706)
    case nsapPointer = 23  // NSAP-PTR - NSAP pointer (RFC 1706)
    case signature = 24  // SIG - Security signature (RFC 2535)
    case key = 25  // KEY - Security key (RFC 2535)
    case pxRecord = 26  // PX - X.400 mail mapping (RFC 2163)
    case gpos = 27  // GPOS - Geographical position (RFC 1712)
    case host6 = 28  // AAAA - IPv6 address (RFC 3596)
    case location = 29  // LOC - Location information (RFC 1876)
    case nextDomain = 30  // NXT - Next domain (obsolete, RFC 2535)
    case endpointId = 31  // EID - Endpoint identifier
    case nimrodLocator = 32  // NIMLOC - Nimrod locator
    case service = 33  // SRV - Service locator (RFC 2782)
    case atma = 34  // ATMA - ATM address
    case namingPointer = 35  // NAPTR - Naming authority pointer (RFC 3403)
    case keyExchange = 36  // KX - Key exchange (RFC 2230)
    case cert = 37  // CERT - Certificate (RFC 4398)
    case a6Record = 38  // A6 - IPv6 address (obsolete, RFC 2874)
    case dname = 39  // DNAME - Delegation name (RFC 6672)
    case sink = 40  // SINK - Kitchen sink
    case opt = 41  // OPT - EDNS option (RFC 6891)
    case apl = 42  // APL - Address prefix list (RFC 3123)
    case delegationSigner = 43  // DS - Delegation signer (RFC 4034)
    case sshFingerprint = 44  // SSHFP - SSH key fingerprint (RFC 4255)
    case ipsecKey = 45  // IPSECKEY - IPsec key (RFC 4025)
    case resourceSignature = 46  // RRSIG - Resource record signature (RFC 4034)
    case nsec = 47  // NSEC - Next secure record (RFC 4034)
    case dnsKey = 48  // DNSKEY - DNS key (RFC 4034)
    case dhcid = 49  // DHCID - DHCP identifier (RFC 4701)
    case nsec3 = 50  // NSEC3 - NSEC3 (RFC 5155)
    case nsec3Param = 51  // NSEC3PARAM - NSEC3 parameters (RFC 5155)
    case tlsa = 52  // TLSA - TLSA certificate (RFC 6698)
    case smimea = 53  // SMIMEA - S/MIME cert association (RFC 8162)
    // 54 unassigned
    case hip = 55  // HIP - Host identity protocol (RFC 8005)
    case ninfo = 56  // NINFO
    case rkey = 57  // RKEY
    case taLink = 58  // TALINK - Trust anchor link
    case cds = 59  // CDS - Child DS (RFC 7344)
    case cdnsKey = 60  // CDNSKEY - Child DNSKEY (RFC 7344)
    case openPGPKey = 61  // OPENPGPKEY - OpenPGP key (RFC 7929)
    case csync = 62  // CSYNC - Child-to-parent sync (RFC 7477)
    case zoneDigest = 63  // ZONEMD - Zone message digest (RFC 8976)
    case svcBinding = 64  // SVCB - Service binding (RFC 9460)
    case httpsBinding = 65  // HTTPS - HTTPS binding (RFC 9460)
    // 66-98 unassigned
    case spf = 99  // SPF - Sender policy framework (RFC 7208)
    case uinfo = 100  // UINFO
    case uid = 101  // UID
    case gid = 102  // GID
    case unspec = 103  // UNSPEC
    case nid = 104  // NID - Node identifier (RFC 6742)
    case l32 = 105  // L32 - Locator32 (RFC 6742)
    case l64 = 106  // L64 - Locator64 (RFC 6742)
    case lp = 107  // LP - Locator FQDN (RFC 6742)
    case eui48 = 108  // EUI48 - 48-bit MAC (RFC 7043)
    case eui64 = 109  // EUI64 - 64-bit MAC (RFC 7043)
    // 110-248 unassigned
    case tkey = 249  // TKEY - Transaction key (RFC 2930)
    case tsig = 250  // TSIG - Transaction signature (RFC 2845)
    case incrementalZoneTransfer = 251  // IXFR - Incremental zone transfer (RFC 1995)
    case standardZoneTransfer = 252  // AXFR - Full zone transfer (RFC 1035)
    case mailboxRecords = 253  // MAILB - Mailbox-related records (RFC 1035)
    case mailAgentRecords = 254  // MAILA - Mail agent RRs (obsolete, RFC 1035)
    case all = 255  // * - All records (RFC 1035)
    case uri = 256  // URI - Uniform resource identifier (RFC 7553)
    case caa = 257  // CAA - Certification authority authorization (RFC 8659)
    case avc = 258  // AVC - Application visibility and control
    case doa = 259  // DOA - Digital object architecture
    case amtRelay = 260  // AMTRELAY - Automatic multicast tunneling relay (RFC 8777)
    case resInfo = 261  // RESINFO - Resolver information
    // ...
    case ta = 32768  // TA - DNSSEC trust authorities
    case dlv = 32769  // DLV - DNSSEC lookaside validation (RFC 4431)
}

/// DNS resource record class (RFC 1035).
public enum ResourceRecordClass: UInt16, Sendable {
    case internet = 1  // IN - Internet (RFC 1035)
    // 2 unassigned
    case chaos = 3  // CH - Chaos (RFC 1035)
    case hesiod = 4  // HS - Hesiod (RFC 1035)
    // 5-253 unassigned
    case none = 254  // NONE - None (RFC 2136)
    case any = 255  // * - Any class (RFC 1035)
}
