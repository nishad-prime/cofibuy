/**
 * The copy editor's two views over one registry.
 *
 * Plain records and plain functions rather than vue-i18n messages, for the same
 * reason the admin panel is English-only and the titles this replaces were a plain
 * record: these are admin chrome, and the copy store is deliberately unreachable from
 * admin chrome, so rewording the editor cannot reword the editor itself.
 *
 * Keyed by copy key, not by the derived `copyKeyLabel` output. Deriving the map key
 * would tie it to a formatting function, so a change to how a key is turned into words
 * could silently orphan every label.
 *
 * The section builder lives here rather than in CopyView so it can be tested. It is
 * the one piece of the editor where a mistake is silent: a key that stops being
 * listed still saves, still counts as dirty, and simply becomes unreachable, so an
 * operator cannot fix its wording and nothing anywhere reports an error.
 */

import { COPY_KEYS, COPY_NAMESPACES, copyKeyLabel, SIMPLE_COPY } from '@/config/copyKeys'
import bnCustomer from '@/i18n/locales/bn/customer.json'
import enCustomer from '@/i18n/locales/en/customer.json'

export const COPY_SECTION_TITLES: Record<string, string> = {
  identity: 'Shop identity',
  home: 'Homepage',
  paywall: 'Payment page',
  closed: 'When payments are closed',
  order: 'After ordering',
  notFound: 'Page not found',
  recovery: 'Access recovery',
  evidence: 'Evidence upload',
}

/** Titles for the full view, where sections are namespaces. */
export const NAMESPACE_TITLES: Record<string, string> = {
  app: 'Site identity',
  home: 'Index page',
  paywall: 'Paywall',
  order: 'Order status',
  evidence: 'Evidence form',
  recovery: 'Access recovery',
  common: 'Shared labels',
  footer: 'Footer',
  lang: 'Language switch',
  notFound: 'Not found',
  setup: 'Setup warning',
}

export const COPY_FIELD_LABELS: Record<string, string> = {
  'app.name': 'Shop name',
  'app.tagline': 'Tagline',

  'home.heading': 'Homepage headline',
  'home.subheading': 'Homepage subheading',
  'home.empty': 'Message when there are no links to sell',
  'home.browse': 'Homepage browse button',

  'paywall.chooseMethod': 'Payment method heading',
  'paywall.chooseMethodHint': 'Payment method guidance',
  'paywall.submit': 'Pay button',
  'paywall.noMethods': 'Message when no payment method is set up',
  'paywall.deliverable': 'What the customer receives',

  'paywall.closedTitle': 'Closed-paywall heading',
  'paywall.closedBody': 'Closed-paywall message',
  'paywall.closedContact': 'Label before the contact details',

  'order.reminder': 'Reminder heading',
  'order.reminderBody': 'Reminder message',
  'order.evidenceHint': 'Evidence upload guidance',
  'order.submitEvidence': 'Submit-evidence button',

  'notFound.title': 'Not-found heading',
  'notFound.body': 'Not-found message',
  'notFound.cta': 'Not-found button',

  'recovery.title': 'Recovery heading',
  'recovery.body': 'Recovery explanation',

  'evidence.chooseImage': 'Evidence image picker',
}

/** A curated key has a written name; anything else falls back to the derived one. */
export function fieldLabel(key: string): string {
  return COPY_FIELD_LABELS[key] ?? copyKeyLabel(key)
}

/** Walk a bundled message file the same way vue-i18n would. */
function resolve(source: unknown, key: string): string {
  let node: unknown = source
  for (const part of key.split('.')) {
    if (node && typeof node === 'object' && part in (node as Record<string, unknown>)) {
      node = (node as Record<string, unknown>)[part]
    } else {
      return ''
    }
  }
  return typeof node === 'string' ? node : ''
}

/** The shipped text, shown as the placeholder so the operator sees what they override. */
export function bundled(key: string, locale: 'bn' | 'en'): string {
  return resolve(locale === 'bn' ? bnCustomer : enCustomer, key)
}

export interface RenderedCopySection {
  id: string
  title: string
  keys: readonly string[]
}

/**
 * Matches the key, its operator label and the shipped wording in both languages, so
 * searching for a phrase the operator can see on the storefront finds the key that
 * produces it. Searching the key alone would only help whoever wrote the code.
 */
function matchesSearch(key: string, needle: string): boolean {
  if (!needle) return true
  const haystack = [key, fieldLabel(key), bundled(key, 'bn'), bundled(key, 'en')]
    .join(' ')
    .toLowerCase()
  return haystack.includes(needle)
}

/**
 * The sections to list, given the tier the operator picked and the search box.
 *
 * Both branches return the same shape, so the template has one rendering path rather
 * than two views that have to be kept in agreement. Empty sections are dropped: a
 * heading with nothing under it reads as broken rather than filtered.
 *
 * This only decides what is *listed*. The editor's dirty count and its save payload
 * are computed over every key in the registry regardless of the answer here, so
 * searching or filtering the list can never hide a pending edit or drop one on save.
 */
export function buildCopySections(showAll: boolean, search = ''): RenderedCopySection[] {
  const needle = search.trim().toLowerCase()

  const sections = showAll
    ? COPY_NAMESPACES.map((ns) => ({
        id: ns,
        title: NAMESPACE_TITLES[ns] ?? ns,
        keys: COPY_KEYS[ns] as readonly string[],
      }))
    : SIMPLE_COPY.map((section) => ({
        id: section.id,
        title: COPY_SECTION_TITLES[section.id] ?? section.id,
        keys: section.keys,
      }))

  return sections
    .map((section) => ({
      ...section,
      keys: section.keys.filter((key) => matchesSearch(key, needle)),
    }))
    .filter((section) => section.keys.length > 0)
}
