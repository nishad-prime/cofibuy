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
    if (DEFAULT_ALLOWED_EXT.includes(ext as any)) {
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
  return /^[0-9a-f-]{36}$/i.test(uuid)
}

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

    const {
      data: { user },
    } = await supabase.auth.getUser()
    if (!user) {
      throw new Error('Authentication required')
    }

    const maybeId = (user as any).id
    if (!maybeId || !isValidUuid(maybeId)) {
      throw new Error('Invalid user ID')
    }
    const uid = maybeId as string

    const fileUuid = crypto.randomUUID()
    const ext = getFileExtension(file.name, file.type) || ('jpg' as any)
    const storagePath = `${uid}/${orderId}/${fieldKey}/${fileUuid}.${ext}`

    const { error } = await supabase.storage.from('proofs').upload(storagePath, file, {
      contentType: file.type,
      cacheControl: '3600',
      upsert: false,
    })

    if (error) {
      throw new Error(error.message || 'File upload failed')
    }

    return {
      storage_path: storagePath,
    }
  }

  return {
    upload,
  }
}
