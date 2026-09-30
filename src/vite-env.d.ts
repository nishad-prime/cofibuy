/// <reference types="vite/client" />

/* eslint-disable @typescript-eslint/no-unused-vars -- interface merging */

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL?: string
  readonly VITE_SUPABASE_ANON_KEY?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}

declare global {
  interface Window {
    __COFIBUY_LOCALE__?: string
  }
}

export {}
