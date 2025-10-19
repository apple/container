/**

 * @param {Object} github
 * @param {Object} context
 * @param {Object} core
 * @param {number} prNumber
 * @param {string} labelsString
 */
async function applyLabels(github, context, core, prNumber, labelsString) {
    if (!labelsString) {
      console.log('No labels to apply');
      return { success: false, reason: 'no-labels' };
    }

    const labels = labelsString.split(',')
      .map(l => l.trim())
      .filter(l => l !== '');
  
    if (labels.length === 0) {
      console.log('No labels to apply after filtering');
      return { success: false, reason: 'empty-after-filter' };
    }
  
    console.log(`Applying labels to PR #${prNumber}: ${labels.join(', ')}`);
  
    try {
      const { data: pr } = await github.rest.pulls.get({
        owner: context.repo.owner,
        repo: context.repo.repo,
        pull_number: prNumber
      });
  
      console.log(`PR #${prNumber} current labels: ${pr.labels.map(l => l.name).join(', ')}`);
  
      const currentLabels = pr.labels.map(l => l.name);
      const newLabels = labels.filter(l => !currentLabels.includes(l));
  
      if (newLabels.length === 0) {
        console.log('All labels are already applied to the PR');
        return { success: false, reason: 'already-applied' };
      }
  
      console.log(`Adding new labels: ${newLabels.join(', ')}`);
  
      await github.rest.issues.addLabels({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: prNumber,
        labels: newLabels
      });
  
      console.log('✅ Labels applied successfully!');
  
      return {
        success: true,
        appliedLabels: newLabels,
        shouldComment: true
      };
  
    } catch (error) {
      console.error('❌ Error applying labels:', error.message);
  
      if (error.status === 404) {
        console.log('PR not found - it may have been deleted or closed');
        return { success: false, reason: 'pr-not-found' };
      }
  
      throw error;
    }
  }
  
  module.exports = applyLabels;