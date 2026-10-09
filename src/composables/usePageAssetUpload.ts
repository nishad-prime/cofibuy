import { ref } from 'vue'

/**
 * Uploads page art to the public `page-assets` bucket.
 *
 * The bucket is world-readable - page art is the thing the customer's browser
 * loads - but writes are staff-only, enforced by the bucket's storage
 * policies. Paths are structured (`{pageId}/{slotKey}/{file}`) so an asset's
 * storage location says which page and slot it belongs to, and cleanup can
 * list a page's files without parsing names.
 *
 * A replaced image is uploaded as a new object rather than overwriting, so a
 * CDN-cached old image can never show through; the caller deletes the old
 * object after the new upload lands.
 */
export function usePageAssetUpload() {
  const uploading = ref(false)

  const upload = async (file: File, pageId: string, slotKey: string): Promise<string | null> => {
    uploading.value = true
    try {
      const { getSupabase } = await import('@/lib/supabase')
      const supabase = getSupabase()

      const ext = (file.name.split('.').pop() || 'jpg').toLowerCase()
      const safe = file.name
        .replace(/\.[^.]+$/, '')
        .toLowerCase()
        .replace(/[^a-z0-9-]+/g, '-')
        .replace(/^-+|-+$/g, '')
        .slice(0, 40)
      const path = `${pageId}/${slotKey}/${Date.now()}-${safe || 'image'}.${ext}`

      const { error } = await supabase.storage.from('page-assets').upload(path, file, {
        contentType: file.type,
        upsert: false,
      })
      if (error) {
        console.error('[page-assets]', error.message)
        return null
      }

      const { data } = supabase.storage.from('page-assets').getPublicUrl(path)
      return data.publicUrl
    } catch (err) {
      console.error('[page-assets]', err)
      return null
    } finally {
      uploading.value = false
    }
  }

  return { upload, uploading }
}
