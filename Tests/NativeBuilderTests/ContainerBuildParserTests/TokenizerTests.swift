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
                .option(Option(key: "--mount", value: "type=cache", raw: "--mount=type=cache")),
                .stringLiteral("/app"),
            ]
        ),
        tokenizerTestInput(
            input: "RUN --network=default /app",
            expectedTokens: [
                .stringLiteral("RUN"),
                .option(Option(key: "--network", value: "default", raw: "--network=default")),
                .stringLiteral("/app"),
            ]
        ),
        tokenizerTestInput(
            input: "RUN --mount=type=bind,target=/target --network=host build.sh",
            expectedTokens: [
                .stringLiteral("RUN"),
                .option(Option(key: "--mount", value: "type=bind,target=/target", raw: "--mount=type=bind,target=/target")),
                .option(Option(key: "--network", value: "host", raw: "--network=host")),
                .stringLiteral("build.sh"),
            ]
        ),
        tokenizerTestInput(
            input: "RUN --mount type=cache /app",
            expectedTokens: [
                .stringLiteral("RUN"),
                .option(Option(key: "--mount", value: "type=cache", raw: "--mount type=cache")),
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
                .option(Option(key: "--mount", value: "type=cache", raw: "--mount=type=cache")),
                .stringLiteral("build.sh"),
                .option(Option(key: "--input", value: "hello", raw: "--input hello")),
            ]
        ),
        tokenizerTestInput(
            input:
                #"""
                RUN --mount=type=cache ["build.sh", "--input", "hello"]
                """#,
            expectedTokens: [
                .stringLiteral("RUN"),
                .option(Option(key: "--mount", value: "type=cache", raw: "--mount=type=cache")),
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
                .option(Option(key: "--mount", value: "type=cache", raw: "--mount=type=cache")),
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
                .option(Option(key: "--mount", value: "type=cache", raw: "--mount=type=cache")),
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
                .option(Option(key: "--mount", value: "type=cache", raw: "--mount=type=cache")),
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
                .option(Option(key: "--mount", value: "type=cache", raw: "--mount=type=cache")),
                .stringLiteral("build.sh --input hello"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --from=alpine src /dest",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option(Option(key: "--from", value: "alpine", raw: "--from=alpine")),
                .stringLiteral("src"),
                .stringLiteral("/dest"),
            ]
        ),

        tokenizerTestInput(
            input: "COPY --from=alpine src src1 src2 src3 /dest",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option(Option(key: "--from", value: "alpine", raw: "--from=alpine")),
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
                .option(Option(key: "--chown", value: "10:11", raw: "--chown=10:11")),
                .stringLiteral("src"),
                .stringLiteral("/dest"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --chown=bin stuff.txt /stuffdest/",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option(Option(key: "--chown", value: "bin", raw: "--chown=bin")),
                .stringLiteral("stuff.txt"),
                .stringLiteral("/stuffdest/"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --chown=1 source /destination",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option(Option(key: "--chown", value: "1", raw: "--chown=1")),
                .stringLiteral("source"),
                .stringLiteral("/destination"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --chmod=440 src /dest/",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option(Option(key: "--chmod", value: "440", raw: "--chmod=440")),
                .stringLiteral("src"),
                .stringLiteral("/dest/"),
            ]
        ),
        tokenizerTestInput(
            input: "COPY --link=false src /dest/",
            expectedTokens: [
                .stringLiteral("COPY"),
                .option(Option(key: "--link", value: "false", raw: "--link=false")),
                .stringLiteral("src"),
                .stringLiteral("/dest/"),
            ]
        ),
        tokenizerTestInput(
            input: "LABEL key=value",
            expectedTokens: [
                .stringLiteral("LABEL"),
                .stringLiteral("key=value"),
            ]
        ),
        tokenizerTestInput(
            input:
                #"""
                LABEL key=value anotherkey=anothervalue quoted="quotelabel"
                """#,
            expectedTokens: [
                .stringLiteral("LABEL"),
                .stringLiteral("key=value"),
                .stringLiteral("anotherkey=anothervalue"),
                .stringLiteral("quoted=\"quotelabel\""),
            ]
        ),
        tokenizerTestInput(
            input:
                #"""
                CMD ["executable", "param1", "param2"]
                """#,
            expectedTokens: [
                .stringLiteral("CMD"),
                .stringList(["executable", "param1", "param2"]),
            ]
        ),
        tokenizerTestInput(
            input:
                #"""
                CMD command param1 param2
                """#,
            expectedTokens: [
                .stringLiteral("CMD"),
                .stringLiteral("command"),
                .stringLiteral("param1"),
                .stringLiteral("param2"),
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

    struct TokenTest: Sendable {
        let tokens: [Token]
        let expectedInstruction: any DockerInstruction
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
                    .option(Option(key: "--platform", value: "linux/arm64", raw: "--platform=linux/arm64")),
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
            .option(Option(key: "--mount", value: "type=cache,target=/cache", raw: "--mount=type=cache,target=/cache")),
            .stringLiteral("build.sh --input hello"),
        ]

        let parser = DockerfileParser()
        let actual = try parser.tokensToRunInstruction(tokens: tokens)

        #expect(actual.command.displayString == "build.sh --input hello")
    }

    @Test func testTokensToRunWithoutShell() throws {
        let command = ["build.sh", "--input", "hello"]
        let tokens: [Token] = [
            .stringLiteral("RUN"),
            .option(Option(key: "--mount", value: "type=cache,target=/mytarget", raw: "--mount=type=cache,target=/mytarget")),
            .stringList(command),
        ]

        let parser = DockerfileParser()
        let actual = try parser.tokensToRunInstruction(tokens: tokens)

        #expect(actual.command.displayString == command.joined(separator: " "))
    }

    static let extraTokensTests: [[Token]] = [
        [
            .stringLiteral("RUN"),
            .option(Option(key: "--mount", value: "type=tmpfs,size=1000", raw: "--mount=type=tmpfs,size=1000")),
            .stringList(["build.sh", "--input", "hello"]),
            .stringLiteral("extra"),
        ],
        [
            .stringLiteral("RUN"),
            .option(Option(key: "--mount", value: "type=bind,target=/target", raw: "--mount=type=bind,target=/target")),
            .stringLiteral("build.sh"),
            .stringLiteral("--input"),
            .stringLiteral("hello"),
            .stringList(["extra"]),
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
                    .option(Option(key: "--link", value: "false", raw: "--link=false")),
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
                    .option(Option(key: "--chmod", value: "440", raw: "--chmod=440")),
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
                    .option(Option(key: "--chown", value: "11:mygroup", raw: "--chown 11:mygroup")),
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
                    .option(Option(key: "--from", value: "alpine", raw: "--from=alpine")),
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
                    .option(Option(key: "--from", value: "base", raw: "--from base")),
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
            .option(Option(key: "--from", value: "alpine", raw: "--from=alpine")),
        ],
    ]

    @Test("Invalid copy tokens throw an error", arguments: invalidCopyTokens)
    func testInvalidCopyTokens(_ tokens: [Token]) throws {
        let parser = DockerfileParser()
        #expect(throws: ParseError.self) {
            let _ = try parser.tokensToCopyInstruction(tokens: tokens)
        }
    }

    static let cmdTokenTests: [TokenTest] = [
        TokenTest(
            tokens: [
                .stringLiteral("CMD"),
                .stringList(["executable", "param1", "param2"]),
            ],
            expectedInstruction: CMDInstruction(command: .exec(["executable", "param1", "param2"]))
        ),
        TokenTest(
            tokens: [
                .stringLiteral("CMD"),
                .stringLiteral("command"),
                .stringLiteral("param1"),
                .stringLiteral("param2"),
            ], expectedInstruction: CMDInstruction(command: .shell("command param1 param2"))
        ),
    ]

    @Test("Successful tokens to CMD Instruction conversion", arguments: cmdTokenTests)
    func testTokensToCMDInstruction(_ testCase: TokenTest) throws {
        let parser = DockerfileParser()
        let actual = try parser.tokensToCMDInstruction(tokens: testCase.tokens)
        guard let expected = testCase.expectedInstruction as? CMDInstruction else {
            Issue.record("Instruction is not the correct type, \(testCase.expectedInstruction)")
            return
        }
        #expect(actual == expected)
    }

    @Test func testTokensToLabelInstruction() throws {
        let tokens: [Token] = [
            .stringLiteral("LABEL"),
            .stringLiteral("key=value"),
            .stringLiteral("anotherkey=anothervalue"),
            .stringLiteral("quoted=\"quotelabel\""),
        ]
        let expectedLabels: [String: String] = [
            "key": "value",
            "anotherkey": "anothervalue",
            "quoted": "\"quotelabel\"",
        ]
        let expectedInstruction = LabelInstruction(labels: expectedLabels)
        let actual = try DockerfileParser().tokensToLabelInstruction(tokens: tokens)
        #expect(actual == expectedInstruction)
    }
}
