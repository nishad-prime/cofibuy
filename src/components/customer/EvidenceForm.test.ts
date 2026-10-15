import { mount } from '@vue/test-utils'
import { describe, expect, it, vi, beforeAll, afterAll } from 'vitest'
import EvidenceForm from '@/components/customer/EvidenceForm.vue'
import { i18n } from '@/i18n'

/**
 * The screenshot attach's own rules: a chosen image shows a preview card the
 * customer can replace or remove, oversize and wrong-type files are refused
 * before any upload is attempted, and a clipboard paste lands on the first
 * image field without one.
 */

const imageField = {
  key: 'screenshot',
  type: 'image',
  label_en: 'Screenshot',
  label_bn: null,
  required: true,
  max_mb: 5,
}

const mountForm = (fields = [imageField]) =>
  mount(EvidenceForm, {
    props: { evidenceFields: fields, submitting: false },
    global: { plugins: [i18n] },
  })

const fakeImage = (name = 'proof.png', size = 1000): File => {
  const file = new File(['x'], name, { type: 'image/png' })
  Object.defineProperty(file, 'size', { value: size })
  return file
}

const pickFile = async (wrapper: ReturnType<typeof mount>, file: File): Promise<void> => {
  const input = wrapper.find('input[type="file"]').element as HTMLInputElement
  Object.defineProperty(input, 'files', { value: [file], configurable: true })
  await wrapper.find('input[type="file"]').trigger('change')
}

beforeAll(() => {
  vi.stubGlobal('URL', {
    ...URL,
    createObjectURL: vi.fn(() => 'blob:preview'),
    revokeObjectURL: vi.fn(),
  })
})

afterAll(() => {
  vi.unstubAllGlobals()
})

describe('EvidenceForm', () => {
  it('shows a preview card with the file name once a screenshot is chosen', async () => {
    const wrapper = mountForm()
    await pickFile(wrapper, fakeImage('payment-proof.png'))

    expect(wrapper.text()).toContain('payment-proof.png')
    expect(wrapper.text()).toContain(i18n.global.t('customer.evidence.attached') as string)
    expect(wrapper.find('img[alt="Screenshot"]').exists()).toBe(true)
    // The dropzone is gone; the input stays mounted so Replace can drive it.
    expect(wrapper.find('input[type="file"]').exists()).toBe(true)
  })

  it('refuses an oversize file without attaching it', async () => {
    const wrapper = mountForm()
    await pickFile(wrapper, fakeImage('big.png', 6 * 1024 * 1024))

    expect(wrapper.text()).toContain(i18n.global.t('customer.evidence.errFileSize') as string)
    expect(wrapper.find('img').exists()).toBe(false)
  })

  it('refuses a file that is not an image', async () => {
    const wrapper = mountForm()
    const file = new File(['x'], 'notes.txt', { type: 'text/plain' })
    await pickFile(wrapper, file)

    expect(wrapper.text()).toContain(i18n.global.t('customer.evidence.errFileType') as string)
    expect(wrapper.find('img').exists()).toBe(false)
  })

  it('removes an attached screenshot and returns to the dropzone', async () => {
    const wrapper = mountForm()
    await pickFile(wrapper, fakeImage())

    await wrapper.find('button[aria-label]').trigger('click')
    expect(wrapper.find('img').exists()).toBe(false)
    expect(wrapper.find('input[type="file"]').exists()).toBe(true)
  })

  it('a clipboard paste lands on the image field without a file', async () => {
    const wrapper = mountForm()
    const file = fakeImage('pasted.png')
    const event = new Event('paste') as ClipboardEvent
    Object.defineProperty(event, 'clipboardData', {
      value: { items: [{ kind: 'file', type: 'image/png', getAsFile: () => file }] },
    })
    window.dispatchEvent(event)
    await wrapper.vm.$nextTick()

    expect(wrapper.text()).toContain('pasted.png')
  })

  it('an already-attached field is not overwritten by another paste', async () => {
    const wrapper = mountForm()
    await pickFile(wrapper, fakeImage('first.png'))

    const file = fakeImage('second.png')
    const event = new Event('paste') as ClipboardEvent
    Object.defineProperty(event, 'clipboardData', {
      value: { items: [{ kind: 'file', type: 'image/png', getAsFile: () => file }] },
    })
    window.dispatchEvent(event)
    await wrapper.vm.$nextTick()

    expect(wrapper.text()).toContain('first.png')
  })

  it('a required empty image field blocks submission', async () => {
    const wrapper = mountForm()
    await wrapper.find('form').trigger('submit')

    expect(wrapper.emitted('submit')).toBeUndefined()
  })

  it('a filled required image field lets the form submit', async () => {
    const wrapper = mountForm()
    await pickFile(wrapper, fakeImage())

    await wrapper.find('form').trigger('submit')
    expect(wrapper.emitted('submit')).toHaveLength(1)
  })
})
