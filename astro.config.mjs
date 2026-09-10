import { defineConfig } from 'astro/config';

// Site servi à la racine de vlldnt.fr par nginx (build statique → dist/).
// inlineStylesheets: 'never' → CSS en fichiers externes = CSP `style-src 'self'`.
export default defineConfig({
  site: 'https://vlldnt.fr',
  build: { inlineStylesheets: 'never' },
});
