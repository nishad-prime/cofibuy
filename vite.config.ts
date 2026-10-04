/// <reference types="vitest/config" />
import { fileURLToPath, URL } from 'node:url'
import tailwindcss from '@tailwindcss/vite'
import vue from '@vitejs/plugin-vue'
import { defineConfig } from 'vite'
import { guardServiceRole } from './vite/plugins/guard-service-role.ts'

export default defineConfig({
  plugins: [vue(), tailwindcss(), guardServiceRole()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  build: {
    target: 'es2022',
    cssTarget: 'safari16',
    sourcemap: true,
  },
  test: {
    globals: true,
    environment: 'jsdom',
    pool: 'vmThreads',
    include: ['src/**/*.test.ts'],
    restoreMocks: true,
  },
})
