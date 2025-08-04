//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerBuildIR
import Testing

@testable import ContainerBuildParser

@Suite class TokenizerTest {
    struct tokenizerTestInput {
        let input: String
        let expectedTokens: [Token]
    }

    let tokenizerTestCases: [tokenizerTestInput] = [
        tokenizerTestInput(
            input: "FROM alpine AS build",
            expectedTokens: [
                .stringLiteral("FROM"),
                .stringLiteral("alpine"),
                .stringLiteral("AS"),
                .stringLiteral("build"),
            ]
        ),
        tokenizerTestInput(
            input: "FROM alpine",
            expectedTokens: [
                .stringLiteral("FROM"),
                .stringLiteral("alpine"),
            ]
        ),
        tokenizerTestInput(
            input: "RUN --mount=type=cache /app",
            expectedTokens: [
                .stringLiteral("RUN"),
                .option("--mount", "type=cache"),
                .stringLiteral("/app"),
            ]
        ),
        tokenizerTestInput(
            input: "RUN --network=default /app",
            expectedTokens: [
                .stringLiteral("RUN"),
                .option("--network", "default"),
                .stringLiteral("/app"),
            ]
        ),
        tokenizerTestInput(
            input: "RUN --mount=type=bind,target=/target --network=host build.sh",
            expectedTokens: [
                .stringLiteral("RUN"),
                .option("--mount", "type=bind,target=/target"),
                .option("--network", "host"),
                .stringLiteral("build.sh"),
            ]
        ),
        tokenizerTestInput(
            input: "RUN --mount type=cache /app",
            expectedTokens: [
                .stringLiteral("RUN"),
                .option("--mount", "type=cache"),
                .stringLiteral("/app"),
            ]
        ),
        tokenizerTestInput(
            input:
                """
                RUN --mount=type=cache build.sh --input hello
                """,
            expectedTokens: [
                .stringLiteral("RUN"),
                .option("--mount", "type=cache"),
                .stringLiteral("build.sh"),
                .option("--input", "hello"),
            ]
        ),
        tokenizerTestInput(
            input:
                #"""
                RUN --mount=type=cache ["build.sh", "--input", "hello"]
                """#,
            expectedTokens: [
                .stringLiteral("RUN"),
                .option("--mount", "type=cache"),
                .stringList(["build.sh", "--input", "hello"]),
            ]
        ),
        tokenizerTestInput(
            input:
                #"""
                RUN --mount=type=cache [ "build.sh", "--input", "hello" ]
                """#,
            expectedTokens: [
                .stringLiteral("RUN"),
                .option("--mount", "type=cache"),
                .stringList(["build.sh", "--input", "hello"]),
            ]
        ),
        tokenizerTestInput(
            input:
                #"""
                RUN --mount=type=cache "build.sh --input hello"
                """#,
            expectedTokens: [
                .stringLiteral("RUN"),
                .option("--mount", "type=cache"),
                .stringLiteral("build.sh --input hello"),
            ]
        ),
        tokenizerTestInput(
            input:
                #"""
                RUN --mount=type=cache "build.sh --input hello"
                # this is a full line comment 
                """#,
            expectedTokens: [
                .stringLiteral("RUN"),
                .option("--mount", "type=cache"),
                .stringLiteral("build.sh --input hello"),
            ]
        ),
        tokenizerTestInput(
            input:
                #"""
                RUN --mount=type=cache "build.sh --input hello" # this is an end line comment
                """#,
            expectedTokens: [
                .stringLiteral("RUN"),
                .option("--mount", "type=cache"),
                .stringLiteral("build.sh --input hello"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --from=alpine src /dest",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option("--from", "alpine"),
                .stringLiteral("src"),
                .stringLiteral("/dest"),
            ]
        ),

        tokenizerTestInput(
            input: "COPY --from=alpine src src1 src2 src3 /dest",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option("--from", "alpine"),
                .stringLiteral("src"),
                .stringLiteral("src1"),
                .stringLiteral("src2"),
                .stringLiteral("src3"),
                .stringLiteral("/dest"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --chown=10:11 src /dest",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option("--chown", "10:11"),
                .stringLiteral("src"),
                .stringLiteral("/dest"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --chown=bin stuff.txt /stuffdest/",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option("--chown", "bin"),
                .stringLiteral("stuff.txt"),
                .stringLiteral("/stuffdest/"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --chown=1 source /destination",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option("--chown", "1"),
                .stringLiteral("source"),
                .stringLiteral("/destination"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --chmod=440 src /dest/",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option("--chmod", "440"),
                .stringLiteral("src"),
                .stringLiteral("/dest/"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --link=false src /dest/",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option("--link", "false"),
                .stringLiteral("src"),
                .stringLiteral("/dest/"),
            ]
        ),
    ]

    @Test func testTokenization() throws {
        for testCase: tokenizerTestInput in tokenizerTestCases {
            var tokenizer = DockerfileTokenizer(testCase.input)
            let tokens = try tokenizer.getTokens()
            #expect(!tokens.isEmpty)
            #expect(TokenizerTest.isEqual(actual: tokens, expected: testCase.expectedTokens))
        }
    }

    static private func isEqual(actual: [Token], expected: [Token]) -> Bool {
        if actual.count != expected.count {
            return false
        }
        var index = 0
        while index < actual.count {
            if actual[index] != expected[index] {
                return false
            }
            index += 1
        }
        return true
    }

    struct TokenTest {
        let tokens: [Token]
        let expectedInstruction: DockerInstruction
    }

    @Test func tokenTranslationFrom() throws {
        let fromTokenTestInputs: [TokenTest] = [
            TokenTest(
                tokens: [
                    .stringLiteral("FROM"),
                    .stringLiteral("alpine"),
                ],
                expectedInstruction: try FromInstruction(image: "alpine")
            ),
            TokenTest(
                tokens: [
                    .stringLiteral("FROM"),
                    .stringLiteral("alpine"),
                    .stringLiteral("AS"),
                    .stringLiteral("build"),
                ],
                expectedInstruction: try FromInstruction(image: "alpine", stageName: "build")
            ),
            TokenTest(
                tokens: [
                    .stringLiteral("FROM"),
                    .option("--platform", "linux/arm64"),
                    .stringLiteral("alpine"),
                ],
                expectedInstruction: try FromInstruction(image: "alpine", platform: "linux/arm64")
            ),
        ]

        for testCase in fromTokenTestInputs {
            let buildParser = DockerfileParser()
            let actualInstruction = try buildParser.tokensToFromInstruction(tokens: testCase.tokens)
            guard let expected = testCase.expectedInstruction as? FromInstruction else {
                Issue.record("unexpected instruction type \(testCase.expectedInstruction)")
                return
            }
            #expect(actualInstruction == expected)
        }
    }

    @Test func testTokensToRunWithShellCommand() throws {
        let tokens: [Token] = [
            .stringLiteral("RUN"),
            .option("--mount", "type=cache,target=/cache"),
            .stringLiteral("build.sh --input hello"),
        ]

        let parser = DockerfileParser()
        let actual = try parser.tokensToRunInstruction(tokens: tokens)

        #expect(actual.shell)
        #expect(actual.command == "build.sh --input hello")
    }

    @Test func testTokensToRunWithoutShell() throws {
        let command = ["build.sh", "--input", "hello"]
        let tokens: [Token] = [
            .stringLiteral("RUN"),
            .option("--mount", "type=cache,target=/mytarget"),
            .stringList(command),
        ]

        let parser = DockerfileParser()
        let actual = try parser.tokensToRunInstruction(tokens: tokens)

        #expect(actual.shell == false)
        #expect(actual.command == command.joined(separator: " "))
    }

    static let extraTokensTests: [[Token]] = [
        [
            .stringLiteral("RUN"),
            .option("--mount", "type=tmpfs,size=1000"),
            .stringList(["build.sh", "--input", "hello"]),
            .stringLiteral("extra"),
        ],
        [
            .stringLiteral("RUN"),
            .option("--mount", "type=bind,target=/target"),
            .stringLiteral("build.sh"),
            .stringLiteral("--input"),
            .stringLiteral("hello"),
            .stringList(["extra"]),
        ],
        [
            .stringLiteral("RUN"),
            .option("--mount", "type=bind,target=/target"),
            .stringLiteral("build.sh"),
            .option("key", "value"),
        ],
    ]

    @Test("Parsing to run instruction fails when there's extra tokens", arguments: extraTokensTests)
    func testTokensToRunExtraTokens(tokens: [Token]) throws {
        #expect(throws: ParseError.self) {
            let parser = DockerfileParser()
            let _ = try parser.tokensToRunInstruction(tokens: tokens)
        }
    }

    @Test func testTokensToCopyInstruction() throws {
        let copyTokenTests = [
            TokenTest(
                tokens: [
                    .stringLiteral("COPY"),
                    .option("--link", "false"),
                    .stringLiteral("src"),
                    .stringLiteral("/dest/"),
                ],
                expectedInstruction: try CopyInstruction(
                    sources: ["src"],
                    destination: "/dest/",
                )
            ),
            TokenTest(
                tokens: [
                    .stringLiteral("COPY"),
                    .option("--chmod", "440"),
                    .stringLiteral("src"),
                    .stringLiteral("/dest"),
                ],
                expectedInstruction: try CopyInstruction(
                    sources: ["src"],
                    destination: "/dest",
                    permissions: .mode(440)
                )
            ),
            TokenTest(
                tokens: [
                    .stringLiteral("COPY"),
                    .option("--chown", "11:mygroup"),
                    .stringLiteral("source"),
                    .stringLiteral("destination"),
                ],
                expectedInstruction: try CopyInstruction(
                    sources: ["source"],
                    destination: "destination",
                    ownership: Ownership(user: .numeric(id: 11), group: .named(id: "mygroup"))
                )
            ),
            TokenTest(
                tokens: [
                    .stringLiteral("COPY"),
                    .option("--from", "alpine"),
                    .stringLiteral("src"),
                    .stringLiteral("src1"),
                    .stringLiteral("src2"),
                    .stringLiteral("src3"),
                    .stringLiteral("/dest"),
                ],
                expectedInstruction: try CopyInstruction(
                    sources: ["src", "src1", "src2", "src3"],
                    destination: "/dest",
                    from: "alpine",
                )
            ),
            TokenTest(
                tokens: [
                    .stringLiteral("COPY"),
                    .option("--from", "base"),
                    .stringLiteral("Source"),
                    .stringLiteral("Dest"),
                ],
                expectedInstruction: try CopyInstruction(
                    sources: ["Source"],
                    destination: "Dest",
                    from: "base",
                )
            ),
        ]

        for test in copyTokenTests {
            let parser = DockerfileParser()
            let actual = try parser.tokensToCopyInstruction(tokens: test.tokens)
            guard let expected = test.expectedInstruction as? CopyInstruction else {
                Issue.record("unexpected instruction type \(test.expectedInstruction)")
                return
            }
            #expect(actual == expected)
        }
    }

    static let invalidCopyTokens: [[Token]] = [
        [
            // no destination
            .stringLiteral("COPY"),
            .stringLiteral("Source"),
        ],
        [
            // no sources
            .stringLiteral("COPY"),
            .option("--from", "alpine"),
        ],
    ]

    @Test("Invalid copy tokens throw an error", arguments: invalidCopyTokens)
    func testInvalidCopyTokens(_ tokens: [Token]) throws {
        let parser = DockerfileParser()
        #expect(throws: ParseError.self) {
            let _ = try parser.tokensToCopyInstruction(tokens: tokens)
        }
    }
}
