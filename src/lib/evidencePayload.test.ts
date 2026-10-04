import { describe, expect, it, vi } from 'vitest'

import { buildEvidencePayload } from '@/lib/evidencePayload'

/** The bKash fixture from `_fixtures.sql`, as the evidence form would return it. */
const MANUAL_PAYMENT = {
  sender_number: '01712345678',
  amount: '500',
  trxid: 'ABC123XYZ9',
}

const noUpload = vi.fn()

function uploader(path: string) {
  return vi.fn(async () => ({ storage_path: path }))
}

describe('buildEvidencePayload', () => {
  it('sends text fields as flat scalars', async () => {
    // The regression guard. `->>` on a nested object is null, so a nested payload
    // looks like "no evidence supplied" to the database.
    const payload = await buildEvidencePayload(MANUAL_PAYMENT, noUpload, 'order-1')

    expect(payload.p_fields).toEqual({
      sender_number: '01712345678',
      amount: '500',
      trxid: 'ABC123XYZ9',
    })
    for (const value of Object.values(payload.p_fields)) {
      expect(typeof value).toBe('string')
    }
  })

  it('sends file paths in p_files, keyed by field', async () => {
    const upload = uploader('user-1/order-1/screenshot/photo.png')
    const payload = await buildEvidencePayload(
      { ...MANUAL_PAYMENT, screenshot: new File(['x'], 'photo.png', { type: 'image/png' }) },
      upload,
      'order-1',
    )

    expect(payload.p_files).toEqual({ screenshot: 'user-1/order-1/screenshot/photo.png' })
    expect(payload.p_fields).not.toHaveProperty('screenshot')
    expect(upload).toHaveBeenCalledWith(expect.any(File), 'screenshot', 'order-1')
  })

  it('keeps file paths out of p_fields and text out of p_files', async () => {
    // The two maps are checked against each other by the SQL: a text field that turns
    // up in p_files raises "takes text, not a file" and vice versa.
    const payload = await buildEvidencePayload(
      { trxid: 'ABC123XYZ9', shot: new File(['x'], 'a.png') },
      uploader('u/o/shot/f.png'),
      'order-1',
    )

    expect(Object.keys(payload.p_fields).sort()).toEqual(['trxid'])
    expect(Object.keys(payload.p_files).sort()).toEqual(['shot'])
  })

  it('omits empty optional fields instead of sending empty strings', async () => {
    const payload = await buildEvidencePayload(
      { trxid: 'ABC123XYZ9', screenshot: '', note: '   ', phone: null, extra: undefined },
      noUpload,
      'order-1',
    )

    expect(payload.p_fields).toEqual({ trxid: 'ABC123XYZ9' })
    expect(payload.p_files).toEqual({})
  })

  it('coerces non-string scalars, so a number field is not dropped', async () => {
    // `<input type="number">` yields a string, but a computed or restored value can
    // arrive as a number. The SQL reads with ->>, which stringifies anyway.
    const payload = await buildEvidencePayload({ amount: 499.5, paid: true }, noUpload, 'order-1')

    expect(payload.p_fields).toEqual({ amount: '499.5', paid: 'true' })
  })

  it('never nests a value under a `value` key', async () => {
    // Written as an explicit assertion because the original bug was exactly this and
    // it fails silently: the request succeeds and the order is refused for missing
    // evidence, which looks like a backend problem.
    const payload = await buildEvidencePayload(
      { trxid: 'ABC123XYZ9', shot: new File(['x'], 'a.png') },
      uploader('u/o/shot/f.png'),
      'order-1',
    )

    for (const map of [payload.p_fields, payload.p_files]) {
      for (const value of Object.values(map)) {
        expect(typeof value).toBe('string')
      }
    }
  })

  it('sends both maps even when there are no files', async () => {
    // PostgREST matches named arguments against the signature. Omitting `p_files`
    // relies on the default; sending `{}` states the intent and keeps the call shape
    // identical whether or not the gateway asks for an image.
    const payload = await buildEvidencePayload({ trxid: 'ABC123XYZ9' }, noUpload, 'order-1')

    expect(payload).toEqual({ p_fields: { trxid: 'ABC123XYZ9' }, p_files: {} })
  })
})
