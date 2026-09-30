export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'scope-enum': [
      2,
      'always',
      [
        'db',
        'rpc',
        'auth',
        'storage',
        'recovery',
        'i18n',
        'ui',
        'admin',
        'repo',
        'deps',
        'ci',
        'docs',
        'config',
        'release',
      ],
    ],
    'body-max-line-length': [2, 'always', 100],
  },
}
