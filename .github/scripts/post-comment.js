/**
 * @param {Object} github
 * @param {Object} context
 * @param {number} prNumber
 * @param {Array<string>} appliedLabels
 */
async function postComment(github, context, prNumber, appliedLabels) {
    if (!appliedLabels || appliedLabels.length === 0) {
      console.log('No labels to comment about');
      return { success: false };
    }
  
    const labelBadges = appliedLabels.map(l => `\`${l}\``).join(', ');
    const comment = `🏷️ **Auto-labeler** has applied the following labels: ${labelBadges}`;
  
    try {
      await github.rest.issues.createComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: prNumber,
        body: comment
      });
  
      console.log('✅ Comment posted successfully');
      return { success: true };
  
    } catch (error) {
      console.error('Failed to post comment:', error.message);
      return { success: false, error: error.message };
    }
  }
  
  module.exports = postComment;