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
          {{ assignedCount }}<span class="text-base text-stone-400">/{{ slots.length }}</span>
        </p>
        <p class="hint">{{ t('admin.images.assignedOf') }}</p>
      </div>
    </header>

    <div v-if="loading" class="empty-state">{{ t('admin.common.loading') }}</div>

    <p v-else-if="error" class="alert-error" role="alert">{{ error }}</p>

    <template v-else>
      <!--
        One card per image slot, in the order the customer sees the sections.
        The card says where the image goes and what belongs in it, so the
        operator can fill every slot from this one page without opening the
        page form.
      -->
      <div class="grid gap-6 lg:grid-cols-2">
        <div v-for="slot in slots" :key="slot.key" class="card card-pad">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="font-semibold text-stone-900">{{ slot.label }}</h2>
              <p class="hint mt-0.5">{{ slot.location }}</p>
            </div>
            <span :class="isAssigned(slot.key, 0) ? 'badge-ok' : 'badge-warn'">
              {{ isAssigned(slot.key, 0) ? 'Assigned' : 'Missing' }}
            </span>
          </div>

          <p class="mt-2 text-sm text-stone-600">{{ slot.purpose }}</p>
          <p class="hint mt-1 ltr-value">
            {{ t('admin.images.recommended') }}: {{ slot.recommendedWidth }} ×
            {{ slot.recommendedHeight }}px
          </p>

          <img
            v-if="assetUrl(slot.key, 0)"
            :src="assetUrl(slot.key, 0) ?? ''"
            :alt="alt(slot.key, 0, 'en') || ''"
            class="mt-3 max-h-56 w-full rounded-lg object-cover"
          />

          <template v-if="slot.perItemConfigKey">
            <!-- Repeated slots: one card per item of the config array. -->
            <div
              v-for="index in itemCount(slot.perItemConfigKey)"
              :key="`${slot.key}.${index}`"
              class="mt-4 rounded-lg border border-stone-200 p-3"
            >
              <div class="flex items-center justify-between gap-3">
                <p class="text-xs font-medium text-stone-500">
                  {{ itemLabel(slot.perItemConfigKey!, index - 1) || `Item ${index}` }}
                </p>
                <span :class="isAssigned(slot.key, index - 1) ? 'badge-ok' : 'badge-warn'">
                  {{ isAssigned(slot.key, index - 1) ? 'Assigned' : 'Missing' }}
                </span>
              </div>
              <img
                v-if="assetUrl(slot.key, index - 1)"
                :src="assetUrl(slot.key, index - 1) ?? ''"
                :alt="alt(slot.key, index - 1, 'en') || ''"
                class="mt-2 max-h-32 w-full rounded-md object-cover"
              />
              <div class="mt-2 grid gap-2">
                <input
                  v-model="draft(slot.key, index - 1).brief_en"
                  :placeholder="t('admin.images.briefEn')"
                  class="field text-sm"
                />
                <input
                  v-model="draft(slot.key, index - 1).brief_bn"
                  :placeholder="t('admin.images.briefBn')"
                  class="field text-sm"
                />
                <div class="grid gap-2 sm:grid-cols-2">
                  <input
                    v-model="draft(slot.key, index - 1).alt_en"
                    :placeholder="t('admin.images.altEn')"
                    class="field text-sm"
                  />
                  <input
                    v-model="draft(slot.key, index - 1).alt_bn"
                    :placeholder="t('admin.images.altBn')"
                    class="field text-sm"
                  />
                </div>
              </div>
              <div class="mt-2 flex items-center justify-between gap-2">
                <label
                  class="cursor-pointer rounded-lg border border-dashed border-stone-300 bg-stone-50 px-3 py-1.5 text-xs text-stone-600 hover:border-brand-400"
                >
                  {{ uploadStates[`${slot.key}.${index - 1}`] ? 'Uploading…' : 'Choose image' }}
                  <input
                    type="file"
                    accept="image/jpeg,image/png,image/webp"
                    class="sr-only"
                    @change="onPick($event, slot.key, index - 1)"
                  />
                </label>
                <button
                  v-if="isAssigned(slot.key, index - 1)"
                  type="button"
                  class="text-xs text-red-600 hover:underline"
                  @click="removeAsset(slot.key, index - 1)"
                >
                  Remove
                </button>
              </div>
            </div>
          </template>

          <template v-else>
            <div class="mt-4 grid gap-2">
              <input
                v-model="draft(slot.key, 0).brief_en"
                :placeholder="t('admin.images.briefEn')"
                class="field text-sm"
              />
              <input
                v-model="draft(slot.key, 0).brief_bn"
                :placeholder="t('admin.images.briefBn')"
                class="field text-sm"
              />
              <div class="grid gap-2 sm:grid-cols-2">
                <input
                  v-model="draft(slot.key, 0).alt_en"
                  :placeholder="t('admin.images.altEn')"
                  class="field text-sm"
                />
                <input
                  v-model="draft(slot.key, 0).alt_bn"
                  :placeholder="t('admin.images.altBn')"
                  class="field text-sm"
                />
              </div>
            </div>
            <div class="mt-3 flex items-center justify-between gap-2">
              <label
                class="cursor-pointer rounded-lg border border-dashed border-stone-300 bg-stone-50 px-3 py-1.5 text-xs text-stone-600 hover:border-brand-400"
              >
                {{
                  uploadStates[slot.key]
                    ? 'Uploading…'
                    : isAssigned(slot.key, 0)
                      ? 'Replace image'
                      : 'Choose image'
                }}
                <input
                  type="file"
                  accept="image/jpeg,image/png,image/webp"
                  class="sr-only"
                  @change="onPick($event, slot.key, 0)"
                />
              </label>
              <button
                v-if="isAssigned(slot.key, 0)"
                type="button"
                class="text-xs text-red-600 hover:underline"
                @click="removeAsset(slot.key, 0)"
              >
                Remove
              </button>
            </div>
          </template>
        </div>
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
import { normalizeConfig, templateFor } from '@/pages/templates/registry'

/**
 * Every image slot the page's template declares, on one page.
 *
 * The AI fills words; images are assigned here, slot by slot, each with a
 * sentence about where it appears and what belongs in it. Saving a slot
 * writes a `page_assets` row - the URL plus its alt and brief - so the
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

const pageRow = ref<PageRow | null>(null)
const assets = ref<AssetRow[]>([])
const loading = ref(true)
const error = ref<string | null>(null)

const template = computed(() => templateFor(pageRow.value?.template))
const slots = computed(() => template.value.imageSlots)
const pageTitle = computed(() =>
  pageRow.value ? pageRow.value.title_en || pageRow.value.title_bn || pageRow.value.slug : '',
)
const templateLabel = computed(() => template.value.label)

const assignedCount = computed(() => assets.value.filter((a) => a.public_url).length)

/** Per-slot editable drafts, seeded from the loaded rows. */
const drafts = reactive<
  Record<string, { brief_en: string; brief_bn: string; alt_en: string; alt_bn: string }>
>({})

const draftKey = (slot: string, index: number): string => `${slot}.${index}`

const draft = (slot: string, index: number) => {
  const key = draftKey(slot, index)
  if (!drafts[key]) {
    const row = assets.value.find((a) => a.slot_key === slot && a.item_index === index)
    drafts[key] = {
      brief_en: row?.brief_en ?? '',
      brief_bn: row?.brief_bn ?? '',
      alt_en: row?.alt_en ?? '',
      alt_bn: row?.alt_bn ?? '',
    }
  }
  return drafts[key]
}

const isAssigned = (slot: string, index: number): boolean =>
  assets.value.some((a) => a.slot_key === slot && a.item_index === index && !!a.public_url)

const assetUrl = (slot: string, index: number): string | null =>
  assets.value.find((a) => a.slot_key === slot && a.item_index === index)?.public_url ?? null

const alt = (slot: string, index: number, lang: 'en' | 'bn'): string | null => {
  const row = assets.value.find((a) => a.slot_key === slot && a.item_index === index)
  return lang === 'en' ? (row?.alt_en ?? null) : (row?.alt_bn ?? null)
}

const config = computed(() => normalizeConfig(template.value.id, pageRow.value?.template_config))

const itemCount = (configKey: string): number => {
  const items = config.value[configKey]
  return Array.isArray(items) ? items.length : 0
}

const itemLabel = (configKey: string, index: number): string => {
  const items = config.value[configKey]
  if (!Array.isArray(items)) return ''
  const item = items[index] as { title_en?: string; title_bn?: string } | undefined
  return (item?.title_en || item?.title_bn || '').trim()
}

const uploadStates = reactive<Record<string, boolean>>({})

const saveSlot = async (
  slotKey: string,
  index: number,
  storagePath: string | null,
  publicUrl: string | null,
): Promise<void> => {
  const d = draft(slotKey, index)
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

const onPick = async (event: Event, slotKey: string, index: number): Promise<void> => {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return

  const stateKey = draftKey(slotKey, index)
  uploadStates[stateKey] = true
  error.value = null
  try {
    const previousPath = assets.value.find(
      (a) => a.slot_key === slotKey && a.item_index === index,
    )?.storage_path

    const url = await upload(file, pageId.value, slotKey)
    if (!url) {
      error.value = 'The image could not be uploaded. Try a smaller file.'
      return
    }

    // Derive the storage path from the public URL: the bucket is public, so
    // the path after `/object/public/page-assets/` is the object key.
    const marker = '/object/public/page-assets/'
    const storagePath = url.includes(marker) ? url.slice(url.indexOf(marker) + marker.length) : url

    await saveSlot(slotKey, index, storagePath, url)

    // The new image landed; the replaced object goes, so the bucket does not
    // fill with files nothing references.
    if (previousPath) {
      const { getSupabase } = await import('@/lib/supabase')
      await getSupabase().storage.from('page-assets').remove([previousPath])
    }
  } finally {
    uploadStates[stateKey] = false
    input.value = ''
  }
}

const removeAsset = async (slotKey: string, index: number): Promise<void> => {
  error.value = null
  const { data: path } = await rpc<string | null>('admin_remove_page_asset', {
    p_page_id: pageId.value,
    p_slot_key: slotKey,
    p_item_index: index,
  })

  if (path) {
    const { getSupabase } = await import('@/lib/supabase')
    await getSupabase().storage.from('page-assets').remove([path])
  }

  assets.value = assets.value.filter((a) => !(a.slot_key === slotKey && a.item_index === index))
  delete drafts[draftKey(slotKey, index)]
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
