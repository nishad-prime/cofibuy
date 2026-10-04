import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import CollapsibleSection from '@/components/admin/CollapsibleSection.vue'

/**
 * The panel's two failure modes are both invisible in a screenshot.
 *
 *   - `v-if` on the body would pass every "is it open" assertion and still destroy the
 *     editor state the gateway form depends on, so the state-preservation case is the
 *     one worth writing first.
 *   - The header and body are wired together with generated ids. If either id drifts,
 *     `aria-controls` silently points at nothing and the panel still looks and behaves
 *     correctly, so the wiring is asserted directly.
 *
 * One-at-a-time is the parent's rule, so it is exercised through a parent here rather
 * than asserted against this component, which cannot enforce it alone.
 */

function harness(initial: boolean) {
  return mount(CollapsibleSection, {
    props: {
      panelId: 'basics',
      title: 'Basics',
      open: initial,
      'onUpdate:open': () => {},
    },
  })
}

describe('CollapsibleSection', () => {
  it('wires the header to the body it controls', () => {
    const wrapper = harness(true)
    const header = wrapper.get('button')
    const body = wrapper.get('[role="region"]')

    expect(header.attributes('aria-controls')).toBe(body.attributes('id'))
    expect(body.attributes('aria-labelledby')).toBe(header.attributes('id'))
    // The ids are derived from panelId, so two panels on one page cannot collide.
    expect(body.attributes('id')).toBe('basics-body')
  })

  it('reports its open state to assistive technology', async () => {
    const wrapper = harness(true)
    expect(wrapper.get('button').attributes('aria-expanded')).toBe('true')

    await wrapper.get('button').trigger('click')
    expect(wrapper.emitted('update:open')).toEqual([[false]])
  })

  it('asks to close when it is already open', async () => {
    const wrapper = harness(false)
    await wrapper.get('button').trigger('click')
    expect(wrapper.emitted('update:open')).toEqual([[true]])
  })

  it('keeps slot content and its state while closed', async () => {
    const wrapper = mount(CollapsibleSection, {
      props: {
        panelId: 'evidence',
        title: 'Evidence',
        open: true,
        'onUpdate:open': () => {},
      },
      slots: { default: '<input class="field" />' },
    })

    await wrapper.get('input.field').setValue('0171-2233-4455')

    // This is the assertion the `v-show` comment is about. Unmounting the body would
    // also pass a naive "is it hidden" check, so the proof has to be that the typed
    // value is still there afterwards - that is what the gateway form's template refs
    // read when it builds the save payload.
    await wrapper.setProps({ open: false })
    expect(wrapper.find('[role="region"]').isVisible()).toBe(false)

    await wrapper.setProps({ open: true })
    expect((wrapper.get('input.field').element as HTMLInputElement).value).toBe('0171-2233-4455')
  })

  it('marks a panel holding an invalid field', () => {
    const clean = harness(true)
    expect(clean.find('.badge-danger').exists()).toBe(false)

    const broken = mount(CollapsibleSection, {
      props: {
        panelId: 'evidence',
        title: 'Evidence',
        open: false,
        hasError: true,
        'onUpdate:open': () => {},
      },
    })
    // The badge sits in the header, so it is reachable while the body is folded away.
    expect(broken.get('.badge-danger').text()).toBe('Needs attention')
    expect(broken.find('[role="region"]').isVisible()).toBe(false)
  })

  it('shows an optional note in the header', () => {
    const withNote = mount(CollapsibleSection, {
      props: {
        panelId: 'accounts',
        title: 'Account details',
        open: true,
        note: '3',
        'onUpdate:open': () => {},
      },
    })
    expect(withNote.get('.badge-muted').text()).toBe('3')
  })

  it('keeps one panel open at a time when the parent holds a single id', async () => {
    const Parent = {
      components: { CollapsibleSection },
      data: () => ({ openId: 'first' }),
      template: `
        <CollapsibleSection panel-id="first" title="First" :open="openId === 'first'"
          @update:open="openId = null" />
        <CollapsibleSection panel-id="second" title="Second" :open="openId === 'second'"
          @update:open="openId = 'second'" />
      `,
    }

    const wrapper = mount(Parent)

    const isOpen = (index: number): boolean =>
      wrapper.findAllComponents(CollapsibleSection)[index]?.props('open') === true

    expect(isOpen(0)).toBe(true)
    expect(isOpen(1)).toBe(false)

    // Opening the second closes the first, because both read the same id.
    await wrapper.findAllComponents(CollapsibleSection)[1]!.get('button').trigger('click')
    expect(isOpen(0)).toBe(false)
    expect(isOpen(1)).toBe(true)
  })
})
