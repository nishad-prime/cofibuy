import { ref } from 'vue'

/**
 * Uploads page art to the public `page-assets` bucket.
 *
 * The bucket is world-readable - page art is the thing the customer's browser
 * loads - but writes are staff-only, enforced by the bucket's storage
 * policies. The path is flat and derived from the original filename so an
 * operator replacing an image can find it again.
 */
export function usePageAssetUpload() {
  const uploading = ref(false)

  const upload = async (file: File): Promise<string | null> => {
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
      const path = `${Date.now()}-${safe || 'image'}.${ext}`

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
