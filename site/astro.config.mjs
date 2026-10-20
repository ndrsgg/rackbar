import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://rackbar.app',
  devToolbar: { enabled: false },
  // Compression eats the space between a line break and an inline element,
  // and the newlines inside <pre> blocks filled from expressions.
  compressHTML: false,
  build: {
    // One request for the page: no render-blocking stylesheet.
    inlineStylesheets: 'always',
  },
});
