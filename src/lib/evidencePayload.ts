/**
 * Shape the evidence submission the way the database reads it.
 *
 * `api.submit_evidence(p_order_id uuid, p_fields jsonb, p_files jsonb)` pulls values
 * with `p_fields ->> key` and `p_files ->> key`. Both of those yield null for a
 * nested object, so a payload shaped as `{ key: { value, storage_path } }` arrives
 * with every field empty and the order is rejected for missing evidence. The shape
 * is the whole contract, and it is not expressible in the generated types because
 * `jsonb` is `jsonb`.
 *
 * Lives outside the view so it can be tested: the shape is what broke, not the logic
 * around it, and the logic around it had no test either.
 */

export interface EvidenceUploadResult {
  storage_path: string
}

export type EvidenceUploader = (
  file: File,
  fieldKey: string,
  orderId: string,
) => Promise<EvidenceUploadResult>

export interface EvidencePayload {
  p_fields: Record<string, string>
  p_files: Record<string, string>
}

/**
 * Splits the form's one-value-per-field record into the two maps the RPC expects.
 *
 * Empty optional fields are omitted rather than sent as empty strings: the SQL turns
 * an empty string into null and skips the column, but omitting them also keeps the
 * required-field check reading as "was it actually filled in" rather than "was a key
 * present".
 */
export async function buildEvidencePayload(
  values: Record<string, unknown>,
  upload: EvidenceUploader,
  orderId: string,
): Promise<EvidencePayload> {
  const p_fields: Record<string, string> = {}
  const p_files: Record<string, string> = {}

  for (const [key, value] of Object.entries(values)) {
    if (value instanceof File) {
      const uploaded = await upload(value, key, orderId)
      p_files[key] = uploaded.storage_path
      continue
    }

    if (value === null || value === undefined) continue

    const text = String(value)
    if (text.trim() !== '') p_fields[key] = text
  }

  return { p_fields, p_files }
}
