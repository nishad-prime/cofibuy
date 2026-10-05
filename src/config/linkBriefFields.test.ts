import { describe, expect, it } from 'vitest'
import {
  LINK_BRIEF_COLUMNS,
  LINK_BRIEF_FIELDS,
  linkFormDefaults,
  type BriefField,
} from '@/config/linkBriefFields'

const byKey = (key: string): BriefField | undefined => LINK_BRIEF_FIELDS.find((f) => f.key === key)

/**
 * The invariants here are the ones whose failure is invisible until a customer sees it.
 *
 * This list is the only place a draft response is mapped onto the link form, so a column renamed
 * here and not there produces a field that is filled on screen and blank in the database - or the
 * reverse, and the save writes an empty string over copy the operator wrote themselves.
 */
describe('LINK_BRIEF_FIELDS', () => {
  it('covers exactly the columns a draft answers with', () => {
    expect(LINK_BRIEF_FIELDS.map((f) => f.key).sort()).toEqual([...LINK_BRIEF_COLUMNS].sort())
  })

  it('has no duplicate columns', () => {
    expect(new Set(LINK_BRIEF_FIELDS.map((f) => f.key)).size).toBe(LINK_BRIEF_FIELDS.length)
  })

  it('has no duplicate form fields', () => {
    // Two columns writing one input would mean the second silently overwrote the first, which for
    // the EN/BN pairs would show up as Bangla appearing in the English box.
    expect(new Set(LINK_BRIEF_FIELDS.map((f) => f.form)).size).toBe(LINK_BRIEF_FIELDS.length)
  })

  /**
   * Every draft field must have somewhere to land. A column with no matching form field is drafted
   * into nothing: the operator sees no change and the token spent was worth nothing.
   */
  it('maps every column onto a form field the link form initialises', () => {
    for (const field of LINK_BRIEF_FIELDS) {
      expect(Object.keys(linkFormDefaults())).toContain(field.form)
    }
  })

  it('covers every form field a draft writes', () => {
    const formKeys = Object.keys(linkFormDefaults())
    expect(LINK_BRIEF_FIELDS.map((f) => f.form).sort()).toEqual(
      formKeys.filter((k) => LINK_BRIEF_FIELDS.some((f) => f.form === k)).sort(),
    )
  })

  /**
   * A one-line input for a markdown paragraph is a formatting accident waiting to happen: the
   * operator edits it, the browser does not reflow it, and the storefront renders a wall of text.
   */
  it('gives the markdown bodies a textarea and the short fields an input', () => {
    for (const key of ['teaser_md_en', 'teaser_md_bn', 'unlock_body_md_en', 'unlock_body_md_bn']) {
      expect(byKey(key)?.kind).toBe('textarea')
    }
    for (const key of ['title_en', 'title_bn', 'unlock_cta_label_en', 'unlock_cta_label_bn']) {
      expect(byKey(key)?.kind).toBe('input')
    }
  })

  /**
   * The pairs are what make a product's copy usable, and a half-pair is the state the preview
   * exists to catch: Bangla shows the model's words while English falls back to empty.
   */
  it('pairs every field with its other language', () => {
    const bases = ['title', 'teaser_md', 'unlock_body_md', 'unlock_cta_label']
    for (const base of bases) {
      expect(byKey(`${base}_en`), base).toBeDefined()
      expect(byKey(`${base}_bn`), base).toBeDefined()
    }
    expect(LINK_BRIEF_FIELDS.length).toBe(bases.length * 2)
  })

  /**
   * The columns the model must never see in a request it can answer. A slug is half of a URL a
   * customer may have bookmarked, and a price or a pay-button URL are facts the operator owns.
   */
  it('leaves the slug, the pay URL and the numbers out of the draft', () => {
    for (const forbidden of [
      'slug',
      'unlock_cta_url',
      'min_amount_override',
      'hide_min_override',
      'is_active',
      'is_listed',
      'sort_order',
    ]) {
      expect(LINK_BRIEF_FIELDS.map((f) => f.key)).not.toContain(forbidden)
    }
  })

  it("labels every field, since the labels are the operator's map of the proposal", () => {
    for (const field of LINK_BRIEF_FIELDS) {
      expect(field.label.trim(), field.key).not.toBe('')
    }
  })
})
