

const applyLabels = require('./apply-labels');

const createMockGitHub = (prLabels = [], shouldFail = false) => ({
  rest: {
    pulls: {
      get: async ({ pull_number }) => {
        if (shouldFail) {
          const error = new Error('Not Found');
          error.status = 404;
          throw error;
        }
        return {
          data: {
            number: pull_number,
            labels: prLabels.map(name => ({ name }))
          }
        };
      }
    },
    issues: {
      addLabels: async ({ issue_number, labels }) => {
        console.log(`Mock: Adding labels ${labels.join(', ')} to PR #${issue_number}`);
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

const mockCore = {
  setOutput: (name, value) => {
    console.log(`Mock Core Output: ${name} = ${value}`);
  }
};

async function runTests() {
  console.log('🧪 Running tests for apply-labels.js\n');

  console.log('Test 1: Apply new labels to PR with no existing labels');
  const result1 = await applyLabels(
    createMockGitHub([]),
    mockContext,
    mockCore,
    123,
    'cli,documentation'
  );
  console.assert(result1.success === true, 'Should succeed');
  console.assert(result1.appliedLabels.length === 2, 'Should apply 2 labels');
  console.log('✅ Test 1 passed\n');

  console.log('Test 2: Skip labels that are already applied');
  const result2 = await applyLabels(
    createMockGitHub(['cli', 'documentation']),
    mockContext,
    mockCore,
    123,
    'cli,documentation'
  );
  console.assert(result2.success === false, 'Should return false');
  console.assert(result2.reason === 'already-applied', 'Reason should be already-applied');
  console.log('✅ Test 2 passed\n');

  console.log('Test 3: Apply only new labels when some already exist');
  const result3 = await applyLabels(
    createMockGitHub(['cli']),
    mockContext,
    mockCore,
    123,
    'cli,documentation,tests'
  );
  console.assert(result3.success === true, 'Should succeed');
  console.assert(result3.appliedLabels.length === 2, 'Should apply 2 new labels');
  console.assert(result3.appliedLabels.includes('documentation'), 'Should include documentation');
  console.assert(result3.appliedLabels.includes('tests'), 'Should include tests');
  console.log('✅ Test 3 passed\n');

  console.log('Test 4: Handle empty label string');
  const result4 = await applyLabels(
    createMockGitHub([]),
    mockContext,
    mockCore,
    123,
    ''
  );
  console.assert(result4.success === false, 'Should return false');
  console.assert(result4.reason === 'no-labels', 'Reason should be no-labels');
  console.log('✅ Test 4 passed\n');

  console.log('Test 5: Handle whitespace and empty values in label string');
  const result5 = await applyLabels(
    createMockGitHub([]),
    mockContext,
    mockCore,
    123,
    'cli, , documentation,  '
  );
  console.assert(result5.success === true, 'Should succeed');
  console.assert(result5.appliedLabels.length === 2, 'Should apply 2 labels after filtering');
  console.log('✅ Test 5 passed\n');

  console.log('Test 6: Handle PR not found gracefully');
  const result6 = await applyLabels(
    createMockGitHub([], true),
    mockContext,
    mockCore,
    999,
    'cli'
  );
  console.assert(result6.success === false, 'Should return false');
  console.assert(result6.reason === 'pr-not-found', 'Reason should be pr-not-found');
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