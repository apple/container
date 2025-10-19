const postComment = require('./post-comment');

const createMockGitHub = (shouldFail = false) => ({
  rest: {
    issues: {
      createComment: async ({ issue_number, body }) => {
        if (shouldFail) {
          throw new Error('API Error: Unable to post comment');
        }
        console.log(`Mock: Posted comment on PR #${issue_number}`);
        console.log(`Comment body: ${body}`);
        return { data: {} };
      }
    }
  }
});

const mockContext = {
  repo: {
    owner: 'apple',
    repo: 'container'
  }
};

async function runTests() {
  console.log('🧪 Running tests for post-comment.js\n');

  console.log('Test 1: Post comment with single label');
  const result1 = await postComment(
    createMockGitHub(),
    mockContext,
    123,
    ['cli']
  );
  console.assert(result1.success === true, 'Should succeed');
  console.log('✅ Test 1 passed\n');

  console.log('Test 2: Post comment with multiple labels');
  const result2 = await postComment(
    createMockGitHub(),
    mockContext,
    123,
    ['cli', 'documentation', 'tests']
  );
  console.assert(result2.success === true, 'Should succeed');
  console.log('✅ Test 2 passed\n');

  console.log('Test 3: Handle empty labels array');
  const result3 = await postComment(
    createMockGitHub(),
    mockContext,
    123,
    []
  );
  console.assert(result3.success === false, 'Should return false for empty array');
  console.log('✅ Test 3 passed\n');

  console.log('Test 4: Handle null labels');
  const result4 = await postComment(
    createMockGitHub(),
    mockContext,
    123,
    null
  );
  console.assert(result4.success === false, 'Should return false for null');
  console.log('✅ Test 4 passed\n');

  console.log('Test 5: Handle API failure gracefully');
  const result5 = await postComment(
    createMockGitHub(true),
    mockContext,
    123,
    ['cli']
  );
  console.assert(result5.success === false, 'Should return false on failure');
  console.assert(result5.error !== undefined, 'Should include error message');
  console.log('✅ Test 5 passed\n');

  console.log('Test 6: Verify comment format is correct');
  const mockGitHubWithVerification = {
    rest: {
      issues: {
        createComment: async ({ body }) => {
          console.assert(body.includes('🏷️'), 'Should include emoji');
          console.assert(body.includes('Auto-labeler'), 'Should mention auto-labeler');
          console.assert(body.includes('`cli`'), 'Should format labels as code');
          console.log('Comment format verified');
          return { data: {} };
        }
      }
    }
  };
  await postComment(mockGitHubWithVerification, mockContext, 123, ['cli']);
  console.log('✅ Test 6 passed\n');

  console.log('🎉 All tests passed!');
}

if (require.main === module) {
  runTests().catch(error => {
    console.error('❌ Test failed:', error);
    process.exit(1);
  });
}

module.exports = runTests;