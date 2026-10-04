<template>
  <div>
    <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="page-title">{{ t('admin.copy.heading') }}</h1>
        <p class="page-subtitle">{{ t('admin.copy.subtitle') }}</p>
      </div>

      <div class="flex items-center gap-2">
        <button
          type="button"
          class="btn-secondary"
          :disabled="saving || dirtyCount === 0"
          @click="revert"
        >
          {{ t('admin.copy.revert') }}
        </button>
        <button
          type="button"
          class="btn-primary"
          :disabled="saving || dirtyCount === 0"
          @click="save"
        >
          {{ saving ? t('admin.copy.saving') : t('admin.copy.save') }}
          <span v-if="dirtyCount > 0" class="ml-1 opacity-80">({{ dirtyCount }})</span>
        </button>
      </div>
    </header>

    <!-- A div, not a p: <ul> is not valid inside <p> and the browser closes the
         paragraph early, which swallows the list styling. -->
    <div v-if="errors.length > 0" class="alert-error mb-4" role="alert">
      <ul class="list-disc pl-5">
        <li v-for="e in errors" :key="e">{{ e }}</li>
      </ul>
    </div>

    <p v-if="success" class="alert-success mb-4" role="status">{{ t('admin.copy.saved') }}</p>

    <div v-if="loading" class="empty-state">{{ t('admin.copy.loading') }}</div>

    <template v-else>
      <p class="hint mb-4">{{ t('admin.copy.fallbackHint') }}</p>

      <!-- One view, two tiers. The toggle swaps which sections are listed; the draft,
           the dirty count and the save payload are computed over every key either way,
           so filtering the list can never hide an unsaved edit from the operator. -->
      <div class="mb-4 flex flex-wrap items-center gap-3">
        <button type="button" class="btn-secondary" @click="showAll = !showAll">
          {{ showAll ? t('admin.copy.showFewer') : t('admin.copy.showAll') }}
        </button>
        <span class="hint">{{
          showAll ? t('admin.copy.allHint') : t('admin.copy.simpleHint')
        }}</span>
        <input
          v-if="showAll"
          v-model="search"
          type="search"
          class="field max-w-xs"
          :placeholder="t('admin.copy.search')"
          :aria-label="t('admin.copy.search')"
        />
      </div>

      <p v-if="visibleSections.length === 0" class="empty-state">
        {{ t('admin.copy.noMatches') }}
      </p>

      <div class="space-y-3">
        <CollapsibleSection
          v-for="section in visibleSections"
          :key="section.id"
          :panel-id="`copy-${section.id}`"
          :title="section.title"
          :open="openSection === section.id"
          :has-error="(sectionProblems.get(section.id) ?? 0) > 0"
          @update:open="toggleSection(section.id)"
        >
          <div v-for="key in section.keys" :key="key" class="mt-4 first:mt-0">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <label class="label" :for="`bn-${key}`">{{ fieldLabel(key) }}</label>
              <!-- The raw key is admin chrome for the person debugging a missing string,
                   and noise on the page most operators ever see. -->
              <span v-if="showAll" class="font-mono text-[11px] text-stone-400">{{ key }}</span>
              <button
                v-if="differs(key)"
                type="button"
                class="text-xs text-stone-500 underline underline-offset-2"
                @click="resetField(key)"
              >
                {{ t('admin.copy.resetField') }}
              </button>
            </div>

            <textarea
              v-if="allowsMarkdown(key)"
              :id="`bn-${key}`"
              v-model="draft.bn[key]"
              rows="3"
              class="field mt-1"
            ></textarea>
            <input v-else :id="`bn-${key}`" v-model="draft.bn[key]" class="field mt-1" />

            <label class="mt-3 block text-xs font-medium text-stone-600" :for="`en-${key}`">
              EN
            </label>
            <textarea
              :id="`en-${key}`"
              v-model="draft.en[key]"
              rows="2"
              class="field mt-1"
              :placeholder="bundled(key, 'en')"
            ></textarea>

            <p v-if="placeholderWarning(key)" class="mt-1 text-xs text-amber-700">
              {{ placeholderWarning(key) }}
            </p>

            <div class="mt-2 flex flex-wrap items-center gap-4">
              <label v-if="allowsMarkdown(key)" class="flex items-center text-xs text-stone-600">
                <input v-model="draft.markdown[key]" type="checkbox" class="mr-1.5 rounded" />
                {{ t('admin.copy.markdown') }}
              </label>
              <span class="text-xs text-stone-400">
                {{ isSet(key) ? t('admin.copy.overridden') : t('admin.copy.usingBundle') }}
              </span>
            </div>

            <!-- Only once the key is actually flagged. Ticking the box with no preview
                 would mean saving blind and then discovering on the storefront that a
                 stray asterisk ate the rest of the sentence. Falls back to the bundled
                 text so the box is not empty before anything is typed. -->
            <div v-if="allowsMarkdown(key) && draft.markdown[key]" class="mt-3">
              <p class="text-xs font-medium text-stone-600">{{ t('admin.copy.preview') }}</p>
              <div
                v-for="locale in PREVIEW_LOCALES"
                :key="locale"
                class="mt-1 rounded-lg border border-stone-200 bg-stone-50 p-3"
              >
                <p class="mb-1 font-mono text-[11px] text-stone-400">
                  {{ locale === 'bn' ? 'বাংলা' : 'EN' }}
                </p>
                <MarkdownBody :source="previewSource(key, locale)" />
              </div>
            </div>
          </div>
        </CollapsibleSection>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue'
import { getSupabase } from '@/lib/supabase'
import MarkdownBody from '@/components/MarkdownBody.vue'
import CollapsibleSection from '@/components/admin/CollapsibleSection.vue'
import { useAdminI18n } from '@/i18n/admin'
import {
  COPY_KEYS,
  COPY_NAMESPACES,
  allowsMarkdown,
  copyKeyLabel,
  missingPlaceholders,
  placeholdersIn,
} from '@/config/copyKeys'
import { bundled, buildCopySections, fieldLabel } from '@/config/copySections'

const supabase = getSupabase()
const { t } = useAdminI18n()

interface CopyRow {
  key: string
  value_bn: string | null
  value_en: string | null
  is_markdown: boolean
}

/**
 * The editor starts from what is *stored*, not from the bundled defaults.
 *
 * Seeding each box with the shipped text would make every field look like a live
 * setting, and an operator clearing one to go back to the original wording would
 * instead be writing an explicit override that happens to match. Starting blank
 * keeps those two states apart: untouched means "not overridden".
 */
const stored = ref<Record<string, CopyRow>>({})
const draft = reactive({
  bn: {} as Record<string, string>,
  en: {} as Record<string, string>,
  markdown: {} as Record<string, boolean>,
})

const loading = ref(true)
const saving = ref(false)
const success = ref(false)
const errors = ref<string[]>([])

/**
 * The curated tier and the full registry, rendered by the same loop.
 *
 * `buildCopySections` owns which sections are listed. Nothing here depends on the
 * answer: `dirtyCount`, `resetDraft` and `save` all iterate `allKeys`, so a filtered
 * or searched list cannot swallow an edit or make the save bar lie about what is
 * pending.
 */
const showAll = ref(false)
const search = ref('')

/** Every key, regardless of what the list is showing. */
const allKeys = COPY_NAMESPACES.flatMap((ns) => [...COPY_KEYS[ns]])

const visibleSections = computed(() => buildCopySections(showAll.value, search.value))

/**
 * Which panel is open, as a section id rather than a boolean per panel so that
 * "one at a time" is the only thing the template has to express.
 *
 * The set of sections is not fixed: switching tiers or typing in the search box
 * replaces it, and ids do not carry across the two views. The watcher below re-points
 * the open panel at whatever came first, which is also what makes the curated view
 * open on Shop identity without naming it - the registry decides the order.
 */
const openSection = ref<string | null>(null)

function toggleSection(id: string): void {
  openSection.value = openSection.value === id ? null : id
}

watch(
  visibleSections,
  (sections) => {
    const ids = sections.map((section) => section.id)
    if (!openSection.value || !ids.includes(openSection.value)) {
      openSection.value = ids[0] ?? null
    }
  },
  { immediate: true },
)

/**
 * Placeholder warnings per section, so a panel holding a bad string is marked even
 * while folded. The badge lives in the header, which is the only part on screen.
 */
const sectionProblems = computed(() => {
  const counts = new Map<string, number>()
  for (const section of visibleSections.value) {
    counts.set(section.id, section.keys.filter((key) => placeholderWarning(key) !== '').length)
  }
  return counts
})

/** Puts one field back to the stored value, without discarding the rest of the draft. */
function resetField(key: string): void {
  const row = stored.value[key]
  draft.bn[key] = row?.value_bn ?? ''
  draft.en[key] = row?.value_en ?? ''
  draft.markdown[key] = allowsMarkdown(key) ? (row?.is_markdown ?? false) : false
}

function isSet(key: string): boolean {
  const row = stored.value[key]
  return Boolean(row && (row.value_bn || row.value_en))
}

const PREVIEW_LOCALES = ['bn', 'en'] as const

/**
 * What the storefront would render for this key and locale right now.
 *
 * Prefers the draft, then the stored override, then the bundled text, so the box
 * shows the sentence that is actually in force rather than going blank while an
 * operator decides what to type. A key cleared in the draft is not overridden, so
 * falling through to the bundle is the honest answer for it.
 */
function previewSource(key: string, locale: 'bn' | 'en'): string {
  return (
    draft[locale][key] ||
    stored.value[key]?.[locale === 'bn' ? 'value_bn' : 'value_en'] ||
    bundled(key, locale)
  )
}

function differs(key: string): boolean {
  const row = stored.value[key]
  return (
    (row?.value_bn ?? '') !== (draft.bn[key] ?? '') ||
    (row?.value_en ?? '') !== (draft.en[key] ?? '') ||
    (row?.is_markdown ?? false) !== (draft.markdown[key] ?? false)
  )
}

const dirtyCount = computed(() => allKeys.filter(differs).length)

/**
 * Placeholder guard.
 *
 * `{amount}` and friends are filled in at render time, so retyping a string can
 * easily drop the token and ship "Minimum" with no number attached. That is worse
 * than slightly wrong wording, so it is refused here rather than found by a
 * customer.
 */
function placeholderWarning(key: string): string {
  const written = draft.bn[key] || draft.en[key]
  if (!written) return ''

  const missing = missingPlaceholders(
    written,
    placeholdersIn(key, bundled(key, 'en'), bundled(key, 'bn')),
  )
  return missing.length > 0 ? `${t('admin.copy.missingPlaceholder')} ${missing.join(', ')}` : ''
}

function resetDraft(): void {
  draft.bn = {}
  draft.en = {}
  draft.markdown = {}

  for (const key of allKeys) {
    const row = stored.value[key]
    draft.bn[key] = row?.value_bn ?? ''
    draft.en[key] = row?.value_en ?? ''
    // Forced off for labels regardless of what is stored. `allowsMarkdown` is the
    // rule; letting a stored flag win would reopen the injection surface on a row
    // written before the rule existed.
    draft.markdown[key] = allowsMarkdown(key) ? (row?.is_markdown ?? false) : false
  }
}

async function readRows(): Promise<void> {
  const { data, error } = await supabase.rpc('admin_copy')
  if (error) throw error

  stored.value = {}
  for (const row of (data ?? []) as CopyRow[]) stored.value[row.key] = row
}

onMounted(async () => {
  try {
    await readRows()
  } catch (err) {
    errors.value = [err instanceof Error ? err.message : String(err)]
  } finally {
    resetDraft()
    loading.value = false
  }
})

function revert(): void {
  resetDraft()
  success.value = false
  errors.value = []
}

async function save(): Promise<void> {
  errors.value = []
  success.value = false

  for (const key of allKeys) {
    const warning = placeholderWarning(key)
    if (warning) errors.value.push(`${copyKeyLabel(key)}: ${warning}`)
  }
  if (errors.value.length > 0) {
    // Folding the panels means the field that stopped the save is usually off screen,
    // and an alert naming a key the operator cannot see reads as a broken editor. Open
    // the first panel that holds one.
    //
    // A warning on a key that no visible panel lists is still reported by name above
    // and is reachable through the search box; that gap predates the folding, since
    // the curated tier has never rendered every key.
    const first = visibleSections.value.find(
      (section) => (sectionProblems.value.get(section.id) ?? 0) > 0,
    )
    if (first) openSection.value = first.id
    return
  }

  const items = allKeys.filter(differs).map((key) => ({
    key,
    value_bn: draft.bn[key] ?? '',
    value_en: draft.en[key] ?? '',
    is_markdown: allowsMarkdown(key) ? (draft.markdown[key] ?? false) : false,
  }))

  saving.value = true
  try {
    // `api.admin_set_copy` takes one jsonb array; PostgREST matches the argument
    // list exactly, so the name has to be p_items.
    if (items.length > 0) {
      const { error } = await supabase.rpc('admin_set_copy', { p_items: items })
      if (error) throw error
    }

    // Re-read rather than trusting the payload: the database drops a row when both
    // languages are cleared, so the editor has to reflect the delete to stay honest.
    await readRows()
    resetDraft()
    success.value = true
  } catch (err) {
    errors.value = [err instanceof Error ? err.message : String(err)]
  } finally {
    saving.value = false
  }
}
</script>
