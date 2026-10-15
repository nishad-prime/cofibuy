import { getSupabase } from '@/lib/supabase'

export interface FileUploadResult {
  storage_path: string
}

export interface FileUploadOptions {
  maxMb?: number
  allowedMimeTypes?: string[]
}

const DEFAULT_MAX_MB = 5
const DEFAULT_ALLOWED_MIME = ['image/jpeg', 'image/png', 'image/webp']
const DEFAULT_ALLOWED_EXT = ['jpg', 'jpeg', 'png', 'webp']

function getFileExtension(filename: string, mimeType?: string): string {
  const parts = filename.split('.')
  if (parts.length > 1) {
    const ext = (parts[parts.length - 1] || '').toLowerCase()
    if (DEFAULT_ALLOWED_EXT.includes(ext)) {
      return ext
    }
  }

  if (mimeType === 'image/jpeg') return 'jpg'
  if (mimeType === 'image/png') return 'png'
  if (mimeType === 'image/webp') return 'webp'

  return 'jpg' as string
}

function isValidFieldKey(fieldKey: string): boolean {
  return /^[a-z][a-z0-9_]{0,31}$/.test(fieldKey)
}

function isValidUuid(uuid: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(uuid)
}

/**
 * A network-level failure during upload: the request never completed. Thrown
 * so callers can show a friendly "check your connection" message instead of
 * the browser's raw "Failed to fetch".
 */
export class UploadTransportError extends Error {
  constructor(cause: unknown) {
    super('upload transport failure')
    this.name = 'UploadTransportError'
    this.cause = cause
  }
}

const isTransportFailure = (err: unknown): boolean =>
  err instanceof TypeError ||
  (err instanceof Error && /failed to fetch|networkerror|load failed/i.test(err.message))

export function useFileUpload() {
  const supabase = getSupabase()

  const upload = async (
    file: File,
    fieldKey: string,
    orderId: string,
    options: FileUploadOptions = {},
  ): Promise<FileUploadResult> => {
    const maxMb = options.maxMb ?? DEFAULT_MAX_MB
    const allowedMimeTypes = options.allowedMimeTypes ?? DEFAULT_ALLOWED_MIME

    if (!isValidFieldKey(fieldKey)) {
      throw new Error('Invalid field key')
    }

    if (!isValidUuid(orderId)) {
      throw new Error('Invalid order ID')
    }

    if (!allowedMimeTypes.includes(file.type)) {
      throw new Error('Invalid file type')
    }

    const maxBytes = maxMb * 1024 * 1024
    if (file.size > maxBytes) {
      throw new Error('File too large')
    }

    const { data, error: authError } = await supabase.auth.getUser()
    if (authError || !data?.user) {
      // The session check itself can fail at the transport level; treat that
      // the same as an offline upload rather than "authentication required".
      if (isTransportFailure(authError)) throw new UploadTransportError(authError)
      throw new Error('Authentication required')
    }
    const user = data.user
    const maybeId = (user as { id?: unknown }).id
    const id = typeof maybeId === 'string' ? maybeId : ''
    if (!id || !isValidUuid(id)) {
      throw new Error('Invalid user ID')
    }
    const uid = id

    const fileUuid = crypto.randomUUID()
    const ext = getFileExtension(file.name, file.type) || 'jpg'
    const storagePath = `${uid}/${orderId}/${fieldKey}/${fileUuid}.${ext}`

    // One retry on a transport failure. Safe to repeat: every attempt uses a
    // fresh random path, so a dropped first attempt can never collide with a
    // second one, and a request that reached the server but lost its response
    // simply leaves an orphaned object behind.
    try {
      const { error } = await supabase.storage.from('proofs').upload(storagePath, file, {
        contentType: file.type,
        cacheControl: '3600',
        upsert: false,
      })

      if (error) {
        throw new Error(error.message || 'File upload failed')
      }
    } catch (err) {
      if (isTransportFailure(err)) {
        console.warn('[upload] transport failure, retrying once:', err)
        const { error: retryError } = await supabase.storage
          .from('proofs')
          .upload(storagePath, file, {
            contentType: file.type,
            cacheControl: '3600',
            upsert: false,
          })
        if (retryError) {
          throw new Error(retryError.message || 'File upload failed')
        }
        return { storage_path: storagePath }
      }
      throw err
    }

    return {
      storage_path: storagePath,
    }
  }

  return {
    upload,
  }
}
