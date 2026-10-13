import { ref } from 'vue'

/**
 * Uploads gateway banners to the public `gateway-assets` bucket.
 *
 * Same arrangement as `usePageAssetUpload`: world-readable (banners are what
 * the customer's browser loads), staff-only writes enforced by the bucket's
 * storage policies, and structured paths (`{gatewayId}/{size}/{file}`) so a
 * gateway's files can be listed and cleaned up without parsing names.
 *
 * A replaced banner is uploaded as a new object rather than overwriting, so a
 * CDN-cached old image can never show through; the caller deletes the old
 * object after the new upload lands.
 */
export function useGatewayAssetUpload() {
  const uploading = ref(false)

  const upload = async (
    file: File,
    gatewayId: string,
    size: 'big' | 'normal',
  ): Promise<string | null> => {
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
      const path = `${gatewayId}/${size}/${Date.now()}-${safe || 'banner'}.${ext}`

      const { error } = await supabase.storage.from('gateway-assets').upload(path, file, {
        contentType: file.type,
        upsert: false,
      })
      if (error) {
        console.error('[gateway-assets]', error.message)
        return null
      }

      const { data } = supabase.storage.from('gateway-assets').getPublicUrl(path)
      return data.publicUrl
    } catch (err) {
      console.error('[gateway-assets]', err)
      return null
    } finally {
      uploading.value = false
    }
  }

  return { upload, uploading }
}
