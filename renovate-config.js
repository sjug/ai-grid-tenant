module.exports = {
  platform: 'github',
  repositories: [
    'ai-grid-cloud/ai-grid-cluster-gitops'
  ],
  hostRules: [
    {
      hostType: 'docker',
      matchHost: 'quay.io',
      username: process.env.QUAY_USERNAME,
      password: process.env.QUAY_PASSWORD,
    },
  ],
};
