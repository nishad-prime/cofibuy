<template>
  <div class="space-y-4">
    <div class="grid gap-4 sm:grid-cols-2">
      <label class="block">
        <span class="mb-1 block text-sm font-medium text-stone-700">Country</span>
        <select v-model="countryModel" class="field">
          <option value="">International (everywhere else)</option>
          <option v-for="c in COUNTRIES" :key="c.code" :value="c.code">
            {{ c.name }} ({{ c.code }})
          </option>
        </select>
        <span class="mt-1 block text-xs text-stone-500">
          Customers from this country see this method at home; everyone else only sees it if no
          method matches their country at all.
        </span>
      </label>

      <label class="flex items-start gap-2 self-end pb-1">
        <input
          v-model="primaryModel"
          type="checkbox"
          class="mt-0.5 rounded border-stone-300"
          :disabled="countryModel === '' && false"
        />
        <span>
          <span class="block text-sm font-medium text-stone-800">Primary for this country</span>
          <span class="block text-xs text-stone-500">
            The primary method gets the big banner at the top of the checkout. One primary per
            country - saving a second one moves the title.
          </span>
        </span>
      </label>
    </div>

    <div class="grid gap-4 sm:grid-cols-2">
      <div>
        <span class="mb-1 block text-sm font-medium text-stone-700">Big banner (3:1)</span>
        <div class="overflow-hidden rounded-xl border border-stone-200">
          <img
            v-if="bannerUrlModel"
            :src="bannerUrlModel"
            alt="Big banner preview"
            class="aspect-[3/1] w-full object-cover"
          />
          <div
            v-else
            class="flex aspect-[3/1] items-center justify-center border border-dashed border-stone-300 bg-stone-50 text-xs text-stone-400"
          >
            Not assigned
          </div>
        </div>
        <label
          class="mt-2 inline-flex cursor-pointer items-center gap-1.5 rounded-lg border border-dashed border-stone-300 px-3 py-1.5 text-xs text-stone-600 hover:border-brand-400"
        >
          {{ uploadingBig ? 'Uploading…' : bannerUrlModel ? 'Replace' : 'Upload big banner' }}
          <input
            type="file"
            accept="image/jpeg,image/png,image/webp"
            class="sr-only"
            @change="pick($event, 'big')"
          />
        </label>
        <button
          v-if="bannerUrlModel"
          type="button"
          class="ml-3 text-xs text-red-600 hover:underline"
          @click="removeBanner('big')"
        >
          Remove
        </button>
        <p class="mt-1 text-xs text-stone-500">Recommended 1200 × 400px.</p>
      </div>

      <div>
        <span class="mb-1 block text-sm font-medium text-stone-700">Normal banner (1.5:1)</span>
        <div class="overflow-hidden rounded-xl border border-stone-200">
          <img
            v-if="bannerSmallUrlModel"
            :src="bannerSmallUrlModel"
            alt="Normal banner preview"
            class="aspect-[1.5/1] w-full object-cover"
          />
          <div
            v-else
            class="flex aspect-[1.5/1] items-center justify-center border border-dashed border-stone-300 bg-stone-50 text-xs text-stone-400"
          >
            Not assigned
          </div>
        </div>
        <label
          class="mt-2 inline-flex cursor-pointer items-center gap-1.5 rounded-lg border border-dashed border-stone-300 px-3 py-1.5 text-xs text-stone-600 hover:border-brand-400"
        >
          {{
            uploadingSmall ? 'Uploading…' : bannerSmallUrlModel ? 'Replace' : 'Upload normal banner'
          }}
          <input
            type="file"
            accept="image/jpeg,image/png,image/webp"
            class="sr-only"
            @change="pick($event, 'normal')"
          />
        </label>
        <button
          v-if="bannerSmallUrlModel"
          type="button"
          class="ml-3 text-xs text-red-600 hover:underline"
          @click="removeBanner('normal')"
        >
          Remove
        </button>
        <p class="mt-1 text-xs text-stone-500">Recommended 600 × 400px.</p>
      </div>
    </div>

    <p v-if="error" class="rounded-lg bg-red-50 p-3 text-sm text-red-800">{{ error }}</p>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { useGatewayAssetUpload } from '@/composables/useGatewayAssetUpload'

/**
 * The country-and-banners block shared by both gateway forms. Banners upload
 * straight to the `gateway-assets` bucket; the URL lands in the gateway row
 * when the operator saves the form.
 */

const countryModel = defineModel<string | null>('country', { default: null })
const primaryModel = defineModel<boolean>('primary', { default: false })
const bannerUrlModel = defineModel<string | null>('bannerUrl', { default: null })
const bannerSmallUrlModel = defineModel<string | null>('bannerSmallUrl', { default: null })

const props = defineProps<{
  /** The gateway row's id, for the storage path. Absent while creating. */
  gatewayId?: string
}>()

const { upload } = useGatewayAssetUpload()
const uploadingBig = ref(false)
const uploadingSmall = ref(false)
const error = ref<string | null>(null)

const COUNTRIES: Array<{ code: string; name: string }> = [
  { code: 'BD', name: 'Bangladesh' },
  { code: 'IN', name: 'India' },
  { code: 'PK', name: 'Pakistan' },
  { code: 'MY', name: 'Malaysia' },
  { code: 'SG', name: 'Singapore' },
  { code: 'AE', name: 'United Arab Emirates' },
  { code: 'SA', name: 'Saudi Arabia' },
  { code: 'GB', name: 'United Kingdom' },
  { code: 'US', name: 'United States' },
]

const storagePathFromUrl = (url: string): string => {
  const marker = '/object/public/gateway-assets/'
  return url.includes(marker) ? url.slice(url.indexOf(marker) + marker.length) : url
}

const pick = async (event: Event, size: 'big' | 'normal'): Promise<void> => {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  if (!props.gatewayId) {
    error.value = 'Save the payment method once, then upload its banners.'
    input.value = ''
    return
  }

  error.value = null
  if (size === 'big') uploadingBig.value = true
  else uploadingSmall.value = true
  try {
    const url = await upload(file, props.gatewayId, size)
    if (!url) {
      error.value = 'The banner could not be uploaded. Try a smaller file.'
      return
    }
    // The replaced object goes, so the bucket does not fill with files
    // nothing references.
    const previous = size === 'big' ? bannerUrlModel.value : bannerSmallUrlModel.value
    if (size === 'big') bannerUrlModel.value = url
    else bannerSmallUrlModel.value = url

    if (previous) {
      const { getSupabase } = await import('@/lib/supabase')
      await getSupabase()
        .storage.from('gateway-assets')
        .remove([storagePathFromUrl(previous)])
    }
  } finally {
    if (size === 'big') uploadingBig.value = false
    else uploadingSmall.value = false
    input.value = ''
  }
}

const removeBanner = async (size: 'big' | 'normal'): Promise<void> => {
  const current = size === 'big' ? bannerUrlModel.value : bannerSmallUrlModel.value
  if (!current) return
  if (size === 'big') bannerUrlModel.value = null
  else bannerSmallUrlModel.value = null
  const { getSupabase } = await import('@/lib/supabase')
  await getSupabase()
    .storage.from('gateway-assets')
    .remove([storagePathFromUrl(current)])
}
</script>
