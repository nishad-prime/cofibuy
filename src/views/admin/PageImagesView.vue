<template>
  <div>
    <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <router-link
          to="/admin/pages"
          class="mb-2 inline-flex items-center gap-1.5 text-sm text-stone-500 hover:text-stone-800"
        >
          <AppIcon name="arrowLeft" :size="14" />
          Back to pages
        </router-link>
        <h1 class="page-title">Images</h1>
        <p class="page-subtitle">{{ pageTitle }} · {{ templateLabel }} template</p>
      </div>
      <div class="text-right">
        <p class="text-2xl font-bold text-stone-900 ltr-value">
          {{ assignedCount }}<span class="text-base text-stone-400">/{{ slotEntries.length }}</span>
        </p>
        <p class="hint">{{ t('admin.images.assignedOf') }}</p>
      </div>
    </header>

    <div v-if="loading" class="empty-state">{{ t('admin.common.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <template v-else>
      <p v-if="slots.length > 0" class="hint mb-4">
        Click or drop an image onto a slot to assign it. Details hold the AI brief and alt text.
      </p>
      <p v-if="hasPerItemSlots" class="hint mb-4">
        {{ t('admin.images.perItemCaveat') }}
      </p>

      <!--
        One slot per card, top to bottom in the order the customer sees the
        sections. The preview is the primary surface; brief and alt live
        behind Details so the common path - upload, done - is two clicks.
      -->
      <div class="space-y-6">
        <article v-for="entry in slotEntries" :key="entry.key" class="card overflow-hidden">
          <div class="border-b border-stone-100 px-5 py-4">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h2 class="font-semibold text-stone-900">{{ entry.title }}</h2>
                <p class="hint mt-0.5">{{ entry.slot.location }}</p>
              </div>
              <span :class="entry.assigned ? 'badge-ok' : 'badge-warn'">
                <AppIcon
                  :name="entry.assigned ? 'check' : 'clock'"
                  :size="12"
                  class="mr-1 inline"
                />
                {{ entry.assigned ? t('admin.images.assigned') : t('admin.images.missing') }}
              </span>
            </div>
            <p class="mt-2 text-sm text-stone-600">{{ entry.slot.purpose }}</p>
          </div>

          <!-- Preview / drop zone: click or drop a file to assign. -->
          <label
            class="group relative block cursor-pointer"
            :class="entry.assigned ? '' : 'border-b border-stone-100'"
            @dragover.prevent
            @drop.prevent="onDrop($event, entry)"
          >
            <img
              v-if="entry.url"
              :src="entry.url"
              :alt="altText(entry)"
              class="max-h-96 w-full object-cover"
            />
            <div
              v-else
              class="flex min-h-56 flex-col items-center justify-center gap-1 border border-dashed border-stone-300 bg-stone-50 px-6 py-12 text-center"
            >
              <AppIcon name="upload" :size="24" class="text-stone-300" />
              <p class="text-sm font-medium text-stone-600">{{ t('admin.images.dropHere') }}</p>
              <p class="hint ltr-value">
                {{ t('admin.images.recommended') }}: {{ entry.slot.recommendedWidth }} ×
                {{ entry.slot.recommendedHeight }}px
              </p>
            </div>

            <div
              v-if="entry.uploading"
              class="absolute inset-0 flex items-center justify-center bg-white/70"
            >
              <span class="text-sm font-medium text-stone-600">
                {{ t('admin.images.uploading') }}
              </span>
            </div>
            <div
              v-else-if="entry.assigned"
              class="absolute inset-0 hidden items-center justify-center bg-stone-950/40 group-hover:flex"
            >
              <span
                class="rounded-lg bg-white px-3 py-1.5 text-xs font-medium text-stone-700 shadow"
              >
                {{ t('admin.images.replace') }}
              </span>
            </div>

            <input
              type="file"
              accept="image/jpeg,image/png,image/webp"
              class="sr-only"
              @change="onPick($event, entry)"
            />
          </label>

          <div class="flex items-center justify-between gap-3 px-5 py-3">
            <label
              class="cursor-pointer rounded-lg border border-dashed border-stone-300 px-3 py-1.5 text-xs font-medium text-stone-600 hover:border-brand-400 hover:text-stone-800"
            >
              {{
                entry.uploading
                  ? t('admin.images.uploading')
                  : entry.assigned
                    ? t('admin.images.replace')
                    : t('admin.images.upload')
              }}
              <input
                type="file"
                accept="image/jpeg,image/png,image/webp"
                class="sr-only"
                @change="onPick($event, entry)"
              />
            </label>

            <div class="flex items-center gap-3">
              <span v-if="entry.legacy" class="hint">
                {{ t('admin.images.legacyHero') }}
              </span>
              <button
                v-if="entry.assigned && !entry.legacy"
                type="button"
                class="inline-flex items-center gap-1 text-xs text-red-600 hover:underline"
                @click="removeAsset(entry)"
              >
                <AppIcon name="close" :size="12" />
                {{ t('admin.images.remove') }}
              </button>
              <button
                type="button"
                class="flex items-center gap-1.5 text-xs font-medium text-stone-600 hover:text-stone-900"
                @click="toggleDetails(entry.key)"
              >
                {{ t('admin.images.details') }}
                <span
                  v-if="dirty[entry.key]"
                  class="size-1.5 rounded-full bg-amber-500"
                  :title="t('admin.images.detailsDirty')"
                />
                <AppIcon :name="openDetails[entry.key] ? 'close' : 'plus'" :size="12" />
              </button>
            </div>
          </div>

          <div
            v-if="openDetails[entry.key]"
            class="border-t border-stone-100 bg-stone-50 px-5 py-4"
          >
            <p class="hint mb-3">{{ t('admin.images.detailsHint') }}</p>
            <div class="grid gap-2">
              <input
                v-model="draftFor(entry).brief_en"
                :placeholder="t('admin.images.briefEn')"
                class="field text-sm"
                @input="dirty[entry.key] = true"
              />
              <input
                v-model="draftFor(entry).brief_bn"
                :placeholder="t('admin.images.briefBn')"
                class="field text-sm"
                @input="dirty[entry.key] = true"
              />
              <div class="grid gap-2 sm:grid-cols-2">
                <input
                  v-model="draftFor(entry).alt_en"
                  :placeholder="t('admin.images.altEn')"
                  class="field text-sm"
                  @input="dirty[entry.key] = true"
                />
                <input
                  v-model="draftFor(entry).alt_bn"
                  :placeholder="t('admin.images.altBn')"
                  class="field text-sm"
                  @input="dirty[entry.key] = true"
                />
              </div>
            </div>
            <div class="mt-3 flex items-center gap-3">
              <button
                type="button"
                class="btn-primary !py-1.5 text-xs"
                :disabled="savingDetails[entry.key]"
                @click="saveDetails(entry)"
              >
                {{
                  savingDetails[entry.key]
                    ? t('admin.images.uploading')
                    : t('admin.images.saveDetails')
                }}
              </button>
              <span v-if="detailsSaved[entry.key]" class="text-xs font-medium text-emerald-700">
                {{ t('admin.images.detailsSaved') }}
              </span>
              <span v-else-if="dirty[entry.key]" class="text-xs font-medium text-amber-600">
                {{ t('admin.images.detailsDirty') }}
              </span>
            </div>
          </div>
        </article>
      </div>

      <div v-if="slots.length === 0" class="card empty-state">
        <p class="font-medium text-stone-700">{{ t('admin.images.noSlots') }}</p>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { useRoute } from 'vue-router'
import AppIcon from '@/components/AppIcon.vue'
import { rpc, rpcList } from '@/lib/rpc'
import { usePageAssetUpload } from '@/composables/usePageAssetUpload'
import { useAdminI18n } from '@/i18n/admin'
import { normalizeConfig, templateFor, type PageImageSlot } from '@/pages/templates/registry'

/**
 * Every image slot the page's template declares, on one page, one column.
 *
 * The preview is the whole interaction: click or drop to assign. Brief and
 * alt live behind Details with an explicit Save - they used to save only as
 * a side effect of re-uploading, which silently discarded edits. Saving a
 * slot writes a `page_assets` row - the URL plus its alt and brief - so the
 * customer renderer can find it by name.
 */

const route = useRoute()
const { t } = useAdminI18n()
const { upload } = usePageAssetUpload()

const pageId = computed(() => route.params.id as string)

interface PageRow {
  id: string
  slug: string
  title_en: string | null
  title_bn: string | null
  template: string
  template_config: Record<string, unknown>
}

interface AssetRow {
  slot_key: string
  item_index: number
  storage_path: string | null
  public_url: string | null
  alt_en: string | null
  alt_bn: string | null
  brief_en: string | null
  brief_bn: string | null
}

/** One renderable card: a slot at one item index. */
interface SlotEntry {
  key: string
  slot: PageImageSlot
  /** Item index for repeated slots, 0 for single slots. */
  index: number
  /** The item's own title, for repeated slots. */
  title: string
  assigned: boolean
  url: string | null
  uploading: boolean
  /**
   * The image comes from the page form's legacy config field, not from a
   * `page_assets` row: shown and counted, but not removable here.
   */
  legacy?: boolean
}

const pageRow = ref<PageRow | null>(null)
const assets = ref<AssetRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const template = computed(() => templateFor(pageRow.value?.template))
const slots = computed(() => template.value.imageSlots)
/** Slots that repeat per config item: their images bind by position. */
const hasPerItemSlots = computed(() => slots.value.some((slot) => slot.perItemConfigKey))
const pageTitle = computed(() =>
  pageRow.value ? pageRow.value.title_en || pageRow.value.title_bn || pageRow.value.slug : '',
)
const templateLabel = computed(() => template.value.label)

/** Per-slot editable drafts, seeded lazily from the loaded rows. */
interface SlotDraft {
  brief_en: string
  brief_bn: string
  alt_en: string
  alt_bn: string
}

const drafts = reactive<Record<string, SlotDraft>>({})

const draftKey = (slot: string, index: number): string => `${slot}.${index}`

const seedDraft = (slot: string, index: number): SlotDraft => {
  const key = draftKey(slot, index)
  const existing = drafts[key]
  if (existing) return existing
  const row = assets.value.find((a) => a.slot_key === slot && a.item_index === index)
  const fresh: SlotDraft = {
    brief_en: row?.brief_en ?? '',
    brief_bn: row?.brief_bn ?? '',
    alt_en: row?.alt_en ?? '',
    alt_bn: row?.alt_bn ?? '',
  }
  drafts[key] = fresh
  return fresh
}

const isAssigned = (slot: string, index: number): boolean =>
  assets.value.some((a) => a.slot_key === slot && a.item_index === index && !!a.public_url)

const assetUrl = (slot: string, index: number): string | null =>
  assets.value.find((a) => a.slot_key === slot && a.item_index === index)?.public_url ?? null

const config = computed(() => normalizeConfig(template.value.id, pageRow.value?.template_config))

const itemCount = (configKey: string): number => {
  const items = config.value[configKey]
  return Array.isArray(items) ? items.length : 0
}

const itemTitle = (configKey: string, index: number): string => {
  const items = config.value[configKey]
  if (!Array.isArray(items)) return ''
  const item = items[index] as { title_en?: string; title_bn?: string } | undefined
  return (item?.title_en || item?.title_bn || '').trim()
}

/**
 * The page form's own hero image field (a legacy config URL rather than a
 * `page_assets` row). The renderer uses it when no row is assigned, so the
 * images screen must count it too - otherwise the page shows a hero while
 * this list calls the slot missing.
 */
const legacyHeroUrl = computed(() => {
  const url = config.value.hero_image_url
  return typeof url === 'string' && url !== '' ? url : null
})

const uploadStates = reactive<Record<string, boolean>>({})
const openDetails = reactive<Record<string, boolean>>({})
const dirty = reactive<Record<string, boolean>>({})
const savingDetails = reactive<Record<string, boolean>>({})
const detailsSaved = reactive<Record<string, boolean>>({})

/** Expands every declared slot into its renderable cards, in display order. */
const slotEntries = computed<SlotEntry[]>(() => {
  const entries: SlotEntry[] = []
  for (const slot of slots.value) {
    if (slot.perItemConfigKey) {
      const count = itemCount(slot.perItemConfigKey)
      for (let index = 0; index < count; index += 1) {
        const key = draftKey(slot.key, index)
        seedDraft(slot.key, index)
        entries.push({
          key,
          slot,
          index,
          title: itemTitle(slot.perItemConfigKey, index) || `${slot.label} ${index + 1}`,
          assigned: isAssigned(slot.key, index),
          url: assetUrl(slot.key, index),
          uploading: uploadStates[key] === true,
        })
      }
    } else {
      const key = draftKey(slot.key, 0)
      seedDraft(slot.key, 0)
      // The hero can be assigned two ways: a `page_assets` row from here, or
      // the page form's legacy image field. Both count as assigned; only the
      // row is removable on this screen.
      const legacy = slot.key === 'hero' ? legacyHeroUrl.value : null
      entries.push({
        key,
        slot,
        index: 0,
        title: slot.label,
        assigned: isAssigned(slot.key, 0) || !!legacy,
        url: assetUrl(slot.key, 0) ?? legacy,
        uploading: uploadStates[key] === true,
        legacy: !!legacy && !isAssigned(slot.key, 0),
      })
    }
  }
  return entries
})

const altText = (entry: SlotEntry): string => {
  const row = assets.value.find(
    (a) => a.slot_key === entry.slot.key && a.item_index === entry.index,
  )
  if (row) return row.alt_en || row.alt_bn || entry.title
  // Legacy hero: its alt lives in the page config, next to its URL.
  if (entry.slot.key === 'hero') {
    const alt = config.value.hero_image_alt_en ?? config.value.hero_image_alt_bn
    if (typeof alt === 'string' && alt !== '') return alt
  }
  return entry.title
}

/** Assigned slots, including the legacy hero, for the header counter. */
const assignedCount = computed(() => slotEntries.value.filter((entry) => entry.assigned).length)

/** Seeded lookup for the template: guaranteed non-null after slotEntries ran. */
const draftFor = (entry: SlotEntry): SlotDraft => seedDraft(entry.slot.key, entry.index)

const toggleDetails = (key: string): void => {
  openDetails[key] = !openDetails[key]
}

const saveSlot = async (
  slotKey: string,
  index: number,
  storagePath: string | null,
  publicUrl: string | null,
): Promise<void> => {
  const key = draftKey(slotKey, index)
  const d = drafts[key] ?? {
    brief_en: '',
    brief_bn: '',
    alt_en: '',
    alt_bn: '',
  }
  const { error: rpcError } = await rpc<Record<string, unknown>>('admin_upsert_page_asset', {
    p_page_id: pageId.value,
    p_slot_key: slotKey,
    p_item_index: index,
    p_storage_path: storagePath,
    p_public_url: publicUrl,
    p_alt_en: d.alt_en,
    p_alt_bn: d.alt_bn,
    p_brief_en: d.brief_en,
    p_brief_bn: d.brief_bn,
  })
  if (rpcError) {
    error.value = rpcError.message
    return
  }
  // Adopt the saved row into the local list so badges and previews update
  // without a refetch.
  const existing = assets.value.find((a) => a.slot_key === slotKey && a.item_index === index)
  if (existing) {
    existing.storage_path = storagePath
    existing.public_url = publicUrl
    existing.alt_en = d.alt_en
    existing.alt_bn = d.alt_bn
    existing.brief_en = d.brief_en
    existing.brief_bn = d.brief_bn
  } else {
    assets.value.push({
      slot_key: slotKey,
      item_index: index,
      storage_path: storagePath,
      public_url: publicUrl,
      alt_en: d.alt_en,
      alt_bn: d.alt_bn,
      brief_en: d.brief_en,
      brief_bn: d.brief_bn,
    })
  }
}

const onPick = async (event: Event, entry: SlotEntry): Promise<void> => {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  await uploadFile(file, entry)
  input.value = ''
}

const onDrop = async (event: DragEvent, entry: SlotEntry): Promise<void> => {
  const file = event.dataTransfer?.files?.[0]
  if (!file) return
  if (!file.type.startsWith('image/')) return
  await uploadFile(file, entry)
}

const uploadFile = async (file: File, entry: SlotEntry): Promise<void> => {
  const stateKey = entry.key
  uploadStates[stateKey] = true
  error.value = null
  try {
    const previousPath = assets.value.find(
      (a) => a.slot_key === entry.slot.key && a.item_index === entry.index,
    )?.storage_path

    const url = await upload(file, pageId.value, entry.slot.key)
    if (!url) {
      error.value = 'The image could not be uploaded. Try a smaller file.'
      return
    }

    // Derive the storage path from the public URL: the bucket is public, so
    // the path after `/object/public/page-assets/` is the object key.
    const marker = '/object/public/page-assets/'
    const storagePath = url.includes(marker) ? url.slice(url.indexOf(marker) + marker.length) : url

    await saveSlot(entry.slot.key, entry.index, storagePath, url)

    // The new image landed; the replaced object goes, so the bucket does not
    // fill with files nothing references.
    if (previousPath) {
      const { getSupabase } = await import('@/lib/supabase')
      await getSupabase().storage.from('page-assets').remove([previousPath])
    }
  } finally {
    uploadStates[stateKey] = false
  }
}

const saveDetails = async (entry: SlotEntry): Promise<void> => {
  const stateKey = entry.key
  savingDetails[stateKey] = true
  detailsSaved[stateKey] = false
  error.value = null
  try {
    const row = assets.value.find(
      (a) => a.slot_key === entry.slot.key && a.item_index === entry.index,
    )
    // Details save on their own: the URL and path stay exactly as they are,
    // so text edits never require a re-upload.
    await saveSlot(entry.slot.key, entry.index, row?.storage_path ?? null, row?.public_url ?? null)
    if (!error.value) {
      dirty[stateKey] = false
      detailsSaved[stateKey] = true
      setTimeout(() => {
        detailsSaved[stateKey] = false
      }, 2000)
    }
  } finally {
    savingDetails[stateKey] = false
  }
}

const removeAsset = async (entry: SlotEntry): Promise<void> => {
  if (!window.confirm(t('admin.images.removeConfirm'))) return
  error.value = null
  const { data: path } = await rpc<string | null>('admin_remove_page_asset', {
    p_page_id: pageId.value,
    p_slot_key: entry.slot.key,
    p_item_index: entry.index,
  })

  if (path) {
    const { getSupabase } = await import('@/lib/supabase')
    await getSupabase().storage.from('page-assets').remove([path])
  }

  assets.value = assets.value.filter(
    (a) => !(a.slot_key === entry.slot.key && a.item_index === entry.index),
  )
  delete drafts[entry.key]
}

onMounted(async () => {
  try {
    const { data: pages, error: pagesError } = await rpcList<PageRow>('admin_pages')
    if (pagesError) {
      error.value = pagesError.message
      loading.value = false
      return
    }
    pageRow.value = (pages ?? []).find((p) => p.id === pageId.value) ?? null
    if (!pageRow.value) {
      error.value = 'Page not found'
      loading.value = false
      return
    }

    const { data: assetsData, error: assetsError } = await rpc<AssetRow[]>('admin_page_assets', {
      p_page_id: pageId.value,
    })
    if (assetsError) {
      error.value = assetsError.message
      loading.value = false
      return
    }
    assets.value = (assetsData ?? []) as unknown as AssetRow[]
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load images'
  } finally {
    loading.value = false
  }
})
</script>
