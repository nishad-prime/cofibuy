/**
 * The page template registry.
 *
 * A page's layout is code, not database: the database stores which template a
 * page uses (`pages.template`, trigger-checked against the ids here) and a JSON
 * config for it (`pages.template_config`), while everything a template means —
 * its shape, its options, the form that edits those options and the component
 * that draws them — lives in this file. The database's only opinions are the
 * two it can enforce on its own: the id must be one the running app declares,
 * and the config must be a JSON object.
 *
 * Consequences, both deliberate:
 *
 *   1. A template can never drift from its form or renderer, because all three
 *      are declared in the same object and typechecked together.
 *   2. Adding a template is one entry here plus its components; nothing else
 *      in the app learns the list, so nothing else can fall out of step with
 *      it. (`/admin/gateways` follows the same idea with `auto_providers`.)
 */
import { markRaw, type Component } from 'vue'
import StandardTemplate from '@/components/customer/templates/StandardTemplate.vue'
import LandingTemplate from '@/components/customer/templates/LandingTemplate.vue'
import StandardConfigForm from '@/components/admin/templates/StandardConfigForm.vue'
import LandingConfigForm from '@/components/admin/templates/LandingConfigForm.vue'

/** One feature row of the landing template. */
export interface LandingItem {
  title_en: string
  title_bn: string
  body_en: string
  body_bn: string
}

/** One question row of the landing template. */
export interface LandingFaq {
  q_en: string
  q_bn: string
  a_en: string
  a_bn: string
}

/** Everything the landing template can draw. Empty strings render as absent. */
export interface LandingConfig {
  subtitle_en: string
  subtitle_bn: string
  items: LandingItem[]
  faq: LandingFaq[]
}

export interface PageTemplate {
  /** The `pages.template` value. Stable across releases: rows in the wild keep it. */
  id: string
  label: string
  defaultConfig: Record<string, unknown>
  adminForm: Component
  renderer: Component
}

const LANDING_DEFAULT: LandingConfig = {
  subtitle_en: '',
  subtitle_bn: '',
  items: [],
  faq: [],
}

/**
 * The shipped templates. `standard` is the layout every page had before
 * templates existed, which is why existing rows default to it and why its
 * config is empty — it reads nothing from the config, so a page saved before
 * the column was added renders exactly as it did.
 */
export const PAGE_TEMPLATES: readonly PageTemplate[] = [
  {
    id: 'standard',
    label: 'Standard',
    defaultConfig: {},
    adminForm: markRaw(StandardConfigForm),
    renderer: markRaw(StandardTemplate),
  },
  {
    id: 'landing',
    label: 'Landing',
    defaultConfig: LANDING_DEFAULT as unknown as Record<string, unknown>,
    adminForm: markRaw(LandingConfigForm),
    renderer: markRaw(LandingTemplate),
  },
]

/**
 * Resolves a template by id, falling back to `standard`.
 *
 * The fallback is the load-bearing part: the database trigger refuses unknown
 * ids at write time, but a page saved by a newer app and read by an older one
 * (a stale deploy, a cached bundle) would otherwise crash the renderer instead
 * of showing the layout the operator did not pick.
 */
export function templateFor(id: string | null | undefined): PageTemplate {
  return (
    PAGE_TEMPLATES.find((t) => t.id === id) ??
    (PAGE_TEMPLATES as readonly [PageTemplate, ...PageTemplate[]])[0]
  )
}

/**
 * Normalizes a stored config for a template.
 *
 * Rows saved before the template existed carry `'{}'`, and a hand-edited row
 * can carry anything the trigger allows (any object). The renderer gets a
 * config that always has every field the template reads, so no template has to
 * defend against a missing key — that defense lives here, once.
 */
export function normalizeConfig(templateId: string, raw: unknown): Record<string, unknown> {
  const template = templateFor(templateId)
  const source = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}

  if (template.id === 'landing') {
    const s = source as Partial<LandingConfig>
    return {
      subtitle_en: typeof s.subtitle_en === 'string' ? s.subtitle_en : '',
      subtitle_bn: typeof s.subtitle_bn === 'string' ? s.subtitle_bn : '',
      items: (Array.isArray(s.items) ? s.items : []).map((item) => ({
        title_en: item?.title_en ?? '',
        title_bn: item?.title_bn ?? '',
        body_en: item?.body_en ?? '',
        body_bn: item?.body_bn ?? '',
      })),
      faq: (Array.isArray(s.faq) ? s.faq : []).map((entry) => ({
        q_en: entry?.q_en ?? '',
        q_bn: entry?.q_bn ?? '',
        a_en: entry?.a_en ?? '',
        a_bn: entry?.a_bn ?? '',
      })),
    } as unknown as Record<string, unknown>
  }

  return { ...template.defaultConfig, ...source }
}
