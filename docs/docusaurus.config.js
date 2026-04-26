// @ts-check

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Cronyx',
  tagline: 'A statically-typed, metaprogramming-first language',
  url: 'https://brendancron.github.io',
  baseUrl: '/compiler/',

  organizationName: 'brendancron',
  projectName: 'compiler',
  trailingSlash: false,

  onBrokenLinks: 'warn',
  onBrokenMarkdownLinks: 'warn',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          sidebarPath: './sidebars.js',
          routeBasePath: '/',
          editUrl: 'https://github.com/brendancron/compiler/edit/main/docs/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      navbar: {
        title: 'Cronyx',
        items: [
          {
            href: 'https://github.com/brendancron/compiler',
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        copyright: `Copyright © ${new Date().getFullYear()} Brendan Cron.`,
      },
    }),
};

export default config;
