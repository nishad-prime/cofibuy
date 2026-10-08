<template>
  <div>
    <!-- The image preview is the point: an operator who cannot see what the
         page will show is uploading blind. -->
    <img v-if="imageUrl" :src="imageUrl" alt="" class="max-h-48 w-full rounded-lg object-cover" />

    <div class="mt-2 flex items-center gap-2">
      <label
        class="flex cursor-pointer items-center gap-2 rounded-lg border border-dashed border-stone-300 bg-stone-50 px-3 py-2 text-sm text-stone-600 transition hover:border-brand-400 hover:text-brand-700"
      >
        <svg
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.6"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
          class="text-stone-400"
        >
          <path
            d="M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5m-13.5-9L12 3m0 0 4.5 4.5M12 3v13.5"
          ></path>
        </svg>
        <span>{{ uploading ? 'Uploading…' : imageUrl ? 'Replace image' : 'Choose image' }}</span>
        <input
          type="file"
          accept="image/jpeg,image/png,image/webp"
          class="sr-only"
          @change="onPick"
        />
      </label>
      <button
        v-if="imageUrl"
        type="button"
        class="text-xs text-red-600 hover:underline"
        @click="imageUrl = ''"
      >
        Remove
      </button>
    </div>
    <p v-if="error" class="mt-1 text-xs text-red-600">{{ error }}</p>
    <p v-else class="hint mt-1">JPG, PNG or WebP. Up to 5 MB.</p>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { usePageAssetUpload } from '@/composables/usePageAssetUpload'

/**
 * Uploads one image to the page-assets bucket and stores its public URL in
 * the template config. Replacing an image uploads a new object rather than
 * overwriting, so a CDN-cached old image can never show through.
 */
const imageUrl = defineModel<string>('imageUrl', { required: true })

const { upload, uploading } = usePageAssetUpload()
const error = ref<string | null>(null)

const onPick = async (event: Event): Promise<void> => {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return

  error.value = null
  const url = await upload(file)
  if (!url) {
    error.value = 'The image could not be uploaded. Try a smaller file.'
    return
  }
  imageUrl.value = url
  input.value = ''
}
</script>
