/**
 * The prose fields of one product, as data.
 *
 * Lives outside `LinkFormView.vue` for the reason `buildCopySections` does: an eight-field list
 * with two names per field and a rule about which of them need a textarea is logic, and logic
 * inside an SFC cannot be tested. Here it can be, and the invariants below are the ones that would
 * otherwise only fail in front of an operator.
 *
 * `key` is the `paywall_links` column and also the key `ai-draft-link` answers with, so a drafted
 * value is applied by matching one name rather than through a translation table. `form` is the
 * link form's field name, which makes this the only place the two vocabularies are mapped.
 */

export interface BriefField {
  /** The column name, which is also the draft function's key. */
  key: string
  /** The link form field this fills. */
  form: string
  label: string
  /** Bodies are markdown paragraphs; a single-line input would silently reflow them. */
  kind: 'input' | 'textarea'
}

/** The values a draft returns, in the order the form should show them. */
export const PAGE_BRIEF_FIELDS: BriefField[] = [
  { key: 'title_en', form: 'title_en', label: 'Title (EN)', kind: 'input' },
  { key: 'title_bn', form: 'title_bn', label: 'Title (BN)', kind: 'input' },
  {
    key: 'unlock_body_md_en',
    form: 'body_en',
    label: 'Body, shown after payment (EN)',
    kind: 'textarea',
  },
  {
    key: 'unlock_body_md_bn',
    form: 'body_bn',
    label: 'Body, shown after payment (BN)',
    kind: 'textarea',
  },
  {
    key: 'unlock_cta_label_en',
    form: 'cta_label_en',
    label: 'Pay button label (EN)',
    kind: 'input',
  },
  {
    key: 'unlock_cta_label_bn',
    form: 'cta_label_bn',
    label: 'Pay button label (BN)',
    kind: 'input',
  },
]

/**
 * The columns `paywall_links` actually has.
 *
 * Written out rather than read from `database.types.ts` on purpose. The generated type would also
 * carry the columns the model must never touch - `slug`, `unlock_cta_url`, `min_amount_override`,
 * `is_active` - and a list derived from it would eventually include one, because nothing stops a
 * column being added later. This is the whole list of what may be drafted, so it is written down.
 */
export const LINK_BRIEF_COLUMNS = [
  'title_en',
  'title_bn',
  'unlock_body_md_en',
  'unlock_body_md_bn',
  'unlock_cta_label_en',
  'unlock_cta_label_bn',
] as const

/**
 * The link form's initial state.
 *
 * Here rather than inline in the SFC because `LINK_BRIEF_FIELDS.form` names are checked against it
 * below: a list of form field names asserted against a hand-written copy of the same names proves
 * nothing, because renaming one in the form would leave both copies agreeing with each other.
 * One object, used by the form and asserted here.
 */
export const pageFormDefaults = (): Record<
  string,
  string | number | boolean | null | Record<string, unknown>
> => ({
  // One template exists; the form no longer offers a choice. The config
  // object must exist from the first render: the template's admin form reads
  // its fields immediately, before a loaded row replaces it.
  template: 'sales-landing',
  template_config: {},
  slug: '',
  title_en: '',
  title_bn: '',
  body_en: '',
  body_bn: '',
  cta_label_en: '',
  cta_label_bn: '',
  cta_url: '',
  is_active: false,
  is_listed: true,
  sort_order: 0,
  min_override: null,
  hide_min: false,
  fixed_amount: null,
})
