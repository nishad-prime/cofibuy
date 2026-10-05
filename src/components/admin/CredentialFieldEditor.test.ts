import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import CredentialFieldEditor, {
  type ProviderField,
} from '@/components/admin/CredentialFieldEditor.vue'

/**
 * This component's whole job is one non-obvious contract: the object it emits is *sparse*.
 *
 * `store_credential_bundle` reads an absent key as "leave the stored value alone" and rejects
 * a present-but-blank one. So a full credential object would be wrong twice over - it would
 * blank every secret the operator did not retype, and an empty draft would have to be encoded
 * as null rather than `{}`. Both failures are silent at the UI layer and surface as a
 * constraint error naming a field nobody touched, so the sparse behaviour is asserted here
 * rather than left to the shape of the payload.
 */

const FIELDS: ProviderField[] = [
  { key: 'username', label_en: 'Username' },
  { key: 'password', label_en: 'Password', secret: true },
]

function harness(props: Partial<InstanceType<typeof CredentialFieldEditor>['$props']> = {}) {
  return mount(CredentialFieldEditor, {
    props: { fields: FIELDS, modelValue: {}, ...props },
  })
}

/**
 * Nth input box. Asserting rather than asserting non-null on the element, because a
 * missing box is the failure a provider with fewer fields than expected would produce and
 * it deserves a message saying which box was not found.
 */
const box = (wrapper: ReturnType<typeof harness>, index: number) => {
  const found = wrapper.findAll('input')[index]
  if (!found) throw new Error(`no input at index ${index} (rendered ${wrapper.html()})`)
  return found
}

describe('CredentialFieldEditor', () => {
  it('emits only the key that was typed into', async () => {
    const wrapper = harness()

    await box(wrapper, 1).setValue('s3cret')

    const emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as Record<string, string>
    expect(emitted).toEqual({ password: 's3cret' })
    // `username` was never touched, so it must be absent - this is the entire point.
    expect('username' in emitted).toBe(false)
  })

  it('drops a key when its box is emptied rather than sending a blank value', async () => {
    const wrapper = harness({ modelValue: { password: 's3cret' } })

    await box(wrapper, 1).setValue('')

    const emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as Record<string, string>
    expect(emitted).toEqual({})
  })

  it('replaces rather than merges, so a cleared key cannot survive from the previous draft', async () => {
    const wrapper = harness({ modelValue: { password: 'old', username: 'keeper' } })

    await box(wrapper, 1).setValue('new')

    const emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as Record<string, string>
    expect(emitted).toEqual({ password: 'new', username: 'keeper' })
  })

  it('marks the fields the current draft would replace', () => {
    // The component is fully controlled: `modelValue` is the draft, and typing only emits.
    // So the marking is asserted from the prop, not from a `setValue` that the parent has
    // not applied yet - otherwise this test would pass or fail on the harness rather than
    // on the component.
    const wrapper = harness({ modelValue: { password: 'typed' } })
    const badges = wrapper.findAll('span').filter((s) => s.text() === 'will be replaced')

    expect(badges).toHaveLength(1)
    expect(wrapper.find('#cred-password-changed').exists()).toBe(true)
  })

  it('marks a newly typed field once the parent applies the emitted draft', async () => {
    const wrapper = harness({ modelValue: {} })

    await box(wrapper, 0).setValue('someone')
    const emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as Record<string, string>
    expect(wrapper.text()).not.toContain('will be replaced')

    // Apply it the way the form does, then the marking follows the new draft.
    await wrapper.setProps({ modelValue: emitted })

    const badges = wrapper.findAll('span').filter((s) => s.text() === 'will be replaced')
    expect(badges).toHaveLength(1)
    expect(wrapper.find('#cred-username-changed').exists()).toBe(true)
  })

  it('keeps the marking wired to the field it describes', () => {
    const wrapper = harness({ modelValue: { username: 'typed' } })
    // aria-describedby pointing at nothing is silent: the field still looks marked.
    expect(box(wrapper, 0).attributes('aria-describedby')).toBe('cred-username-changed')
    expect(box(wrapper, 1).attributes('aria-describedby')).toBeUndefined()
  })

  it('offers an "unchanged" placeholder only when credentials are already stored', () => {
    const stored = harness({ modelValue: {}, hasStored: true })
    const empty = harness({ modelValue: {}, hasStored: false })

    // The secret box is index 1. Reading it wrong here would tell an operator that a
    // never-configured gateway already has a password, which is the bug this guards.
    expect(box(stored, 1).attributes('placeholder')).toBe('Unchanged — type to replace')
    expect(box(empty, 1).attributes('placeholder')).toBe('••••••••')
  })

  it('masks secrets and tells the browser not to autofill them', () => {
    const wrapper = harness()
    const password = box(wrapper, 1)
    const username = box(wrapper, 0)

    expect(password.attributes('type')).toBe('password')
    expect(username.attributes('type')).toBe('text')
    // A browser filling a saved password into a merchant credential is a plausible and
    // hard-to-spot corruption; `new-password` is the standard way to opt out.
    expect(password.attributes('autocomplete')).toBe('new-password')
    expect(username.attributes('spellcheck')).toBe('false')
  })

  it('renders nothing to type into when no provider is selected', () => {
    const wrapper = harness({ fields: [] })
    expect(wrapper.findAll('input')).toHaveLength(0)
  })
})
