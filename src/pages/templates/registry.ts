/**
 * The page template registry.
 *
 * A page's layout is code, not database: the database stores which template a
 * page uses (`pages.template`, trigger-checked against the ids here) and a JSON
 * config for it (`pages.template_config`), while everything a template means —
 * its shape, its options, the form that edits those options and the component
 * that draws it — lives in this file. The database's only opinions are the
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
 *
 * The registry holds exactly one template: the dark, long-form sales page.
 */
import { markRaw, type Component } from 'vue'
import SalesLandingTemplate from '@/components/customer/templates/SalesLandingTemplate.vue'
import SalesLandingConfigForm from '@/components/admin/templates/SalesLandingConfigForm.vue'

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

/** One benefit row of a selling page. */
export interface BenefitItem {
  icon: string
  title_en: string
  title_bn: string
  body_en: string
  body_bn: string
}

/** One numbered step of "how it works". */
export interface StepItem {
  title_en: string
  title_bn: string
  body_en: string
  body_bn: string
}

/** One testimonial row. */
export interface TestimonialItem {
  quote_en: string
  quote_bn: string
  author_en: string
  author_bn: string
}

/**
 * The sales-landing content: the whole page's copy and imagery, owned by the
 * template. Flat scalar keys are what the AI fill reads; the arrays are
 * edited section by section in the template's admin form.
 */
export interface SalesLandingConfig {
  hero_title_en: string
  hero_title_bn: string
  hero_subtitle_en: string
  hero_subtitle_bn: string
  hero_image_url: string
  hero_image_alt_en: string
  hero_image_alt_bn: string
  hero_cta_en: string
  hero_cta_bn: string
  problem_heading_en: string
  problem_heading_bn: string
  problem_body_en: string
  problem_body_bn: string
  benefits: BenefitItem[]
  included_heading_en: string
  included_heading_bn: string
  included: LandingItem[]
  how_heading_en: string
  how_heading_bn: string
  how: StepItem[]
  testimonials: TestimonialItem[]
  faq: LandingFaq[]
  /** The Telegram chat the page delivers to (bot must be admin there). */
  telegram_chat_id: string
  telegram_chat_type: string
}

/**
 * One image slot a template declares: a named place in the page with the
 * guidance the images-assignment screen shows the operator. The database
 * stores slots without interpreting them; this list is the contract.
 */
export interface PageImageSlot {
  /** The `page_assets.slot_key` value. */
  key: string
  label: string
  /** Where the image appears on the rendered page. */
  location: string
  /** What the operator should put there. */
  purpose: string
  required: boolean
  recommendedWidth: number
  recommendedHeight: number
  /** Present when the slot repeats per item of a config array. */
  perItemConfigKey?: 'benefits' | 'included' | 'testimonials'
}

/** Slot list: every image surface the sales page renders. */
const SLOTS_SALES: PageImageSlot[] = [
  {
    key: 'hero',
    label: 'Hero image',
    location: 'Top of the page, under the main title and promise',
    purpose:
      'Show the product or its strongest visual: the cover, a clean product shot, or one representative frame.',
    required: true,
    recommendedWidth: 1600,
    recommendedHeight: 1000,
  },
  {
    key: 'problem',
    label: 'Problem image',
    location: 'Beside the problem section, as a visual of the frustration',
    purpose: 'A picture of the mess the buyer is stuck in — cluttered, generic, low quality.',
    required: false,
    recommendedWidth: 1200,
    recommendedHeight: 900,
  },
  {
    key: 'benefits',
    label: 'Benefit images',
    location: 'One optional image inside each benefit card',
    purpose: 'A small visual that makes each benefit concrete at a glance.',
    required: false,
    recommendedWidth: 800,
    recommendedHeight: 600,
    perItemConfigKey: 'benefits',
  },
  {
    key: 'included',
    label: 'Included item images',
    location: 'One optional image beside each included deliverable',
    purpose: 'Show the actual deliverable: the cover, a sample page, a file preview.',
    required: false,
    recommendedWidth: 800,
    recommendedHeight: 600,
    perItemConfigKey: 'included',
  },
  {
    key: 'how',
    label: 'How-it-works image',
    location: 'Beside the steps, as a visual of the process',
    purpose: 'A picture that makes the path from payment to result feel concrete.',
    required: false,
    recommendedWidth: 1200,
    recommendedHeight: 900,
  },
  {
    key: 'testimonials',
    label: 'Testimonial photos',
    location: 'One optional avatar beside each testimonial quote',
    purpose: 'A face or initials-style photo for the person quoted. Use only with permission.',
    required: false,
    recommendedWidth: 400,
    recommendedHeight: 400,
    perItemConfigKey: 'testimonials',
  },
]

/**
 * One assigned image, as the public payload delivers it: keyed by slot (and
 * item index for repeating slots, as `benefits.2`).
 */
export interface PageImage {
  url: string | null
  alt_en: string | null
  alt_bn: string | null
}

export type PageImageMap = Record<string, PageImage>

export interface PageTemplate {
  /** The `pages.template` value. Stable across releases: rows in the wild keep it. */
  id: string
  label: string
  defaultConfig: Record<string, unknown>
  adminForm: Component
  renderer: Component
  /** The image slots this template renders. Empty for text-only layouts. */
  imageSlots: PageImageSlot[]
  /**
   * True when the renderer draws its own edge-to-edge background: the page
   * view drops its centered, padded shell so the template owns the viewport.
   */
  fullBleed?: boolean
}

const SALES_DEFAULT: SalesLandingConfig = {
  hero_title_en: '',
  hero_title_bn: '',
  hero_subtitle_en: '',
  hero_subtitle_bn: '',
  hero_image_url: '',
  hero_image_alt_en: '',
  hero_image_alt_bn: '',
  hero_cta_en: '',
  hero_cta_bn: '',
  problem_heading_en: '',
  problem_heading_bn: '',
  problem_body_en: '',
  problem_body_bn: '',
  benefits: [],
  included_heading_en: '',
  included_heading_bn: '',
  included: [],
  how_heading_en: '',
  how_heading_bn: '',
  how: [],
  testimonials: [],
  faq: [],
  telegram_chat_id: '',
  telegram_chat_type: 'channel',
}

/**
 * The shipped templates. The sales page is currently the only one; the
 * legacy layouts (standard, landing, minimal-product) were removed as
 * superseded. Adding a template back is one entry here plus its form and
 * renderer - nothing else in the app learns the list.
 */
export const PAGE_TEMPLATES: readonly PageTemplate[] = [
  {
    id: 'sales-landing',
    label: 'Sales page',
    defaultConfig: SALES_DEFAULT as unknown as Record<string, unknown>,
    adminForm: markRaw(SalesLandingConfigForm),
    renderer: markRaw(SalesLandingTemplate),
    imageSlots: SLOTS_SALES,
    fullBleed: true,
  },
]

/**
 * Resolves a template by id, falling back to the first declared template.
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
 * Normalizes a stored config for the template.
 *
 * Rows saved before fields existed carry `'{}'`, and a hand-edited row can
 * carry anything the trigger allows (any object, including keys removed from
 * the contract). The renderer gets a config that always has every field the
 * template reads, so no template has to defend against a missing key — that
 * defense lives here, once.
 */
export function normalizeConfig(templateId: string, raw: unknown): Record<string, unknown> {
  const template = templateFor(templateId)
  const source = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}
  const s = source as Partial<SalesLandingConfig>

  if (template.id === 'sales-landing') {
    return {
      ...SALES_DEFAULT,
      ...s,
      hero_image_url: typeof s.hero_image_url === 'string' ? s.hero_image_url : '',
      benefits: (Array.isArray(s.benefits) ? s.benefits : []).map((item) => ({
        icon: item?.icon ?? '',
        title_en: item?.title_en ?? '',
        title_bn: item?.title_bn ?? '',
        body_en: item?.body_en ?? '',
        body_bn: item?.body_bn ?? '',
      })),
      included: (Array.isArray(s.included) ? s.included : []).map((item) => ({
        title_en: item?.title_en ?? '',
        title_bn: item?.title_bn ?? '',
        body_en: item?.body_en ?? '',
        body_bn: item?.body_bn ?? '',
      })),
      how: (Array.isArray(s.how) ? s.how : []).map((step) => ({
        title_en: step?.title_en ?? '',
        title_bn: step?.title_bn ?? '',
        body_en: step?.body_en ?? '',
        body_bn: step?.body_bn ?? '',
      })),
      testimonials: (Array.isArray(s.testimonials) ? s.testimonials : []).map((entry) => ({
        quote_en: entry?.quote_en ?? '',
        quote_bn: entry?.quote_bn ?? '',
        author_en: entry?.author_en ?? '',
        author_bn: entry?.author_bn ?? '',
      })),
      faq: (Array.isArray(s.faq) ? s.faq : []).map((entry) => ({
        q_en: entry?.q_en ?? '',
        q_bn: entry?.q_bn ?? '',
        a_en: entry?.a_en ?? '',
        a_bn: entry?.a_bn ?? '',
      })),
      telegram_chat_id: typeof s.telegram_chat_id === 'string' ? s.telegram_chat_id : '',
      telegram_chat_type: s.telegram_chat_type === 'group' ? 'group' : 'channel',
    } as unknown as Record<string, unknown>
  }

  return { ...template.defaultConfig, ...source }
}
