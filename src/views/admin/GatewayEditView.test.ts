import { mount, flushPromises } from '@vue/test-utils'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { defineComponent, h } from 'vue'
import GatewayEditView from '@/views/admin/GatewayEditView.vue'

/**
 * A regression test for the one thing this dispatcher view exists to do: hand the id it
 * resolved to the child form it renders.
 *
 * The bug it guards against is silent and duplicating. Both child forms derive `isEdit` from
 * a `gatewayId` prop, and both send `id: props.gatewayId ?? ''` to `api.admin_upsert_gateway`.
 * That function reads the id as `nullif(p_gateway ->> 'id', '')::uuid` and inserts when it is
 * null, so an edit route that renders a form without the prop does not fail - it saves a second
 * payment method and leaves the original untouched. The operator sees a success message and a
 * duplicated row, which is the worst shape this bug can take.
 *
 * Both children are replaced by one stub. Only one of them renders at a time, and `presetProvider`
 * tells the two apart from the outside: the automatic form is handed one and the manual form is
 * not. Asserting on a single stub therefore still proves which form was chosen and what it got.
 */

const GATEWAY_ID = '11111111-2222-3333-4444-555555555555'

/** Renders nothing identifiable, so only its props are of interest. */
const FormStub = defineComponent({
  name: 'GatewayFormStub',
  props: {
    gatewayId: { type: String, required: false, default: undefined },
    presetProvider: { type: String, required: false, default: undefined },
  },
  setup: () => () => h('div'),
})

const rpc = vi.fn()

vi.mock('@/lib/supabase', () => ({
  getSupabase: () => ({
    rpc: (...args: unknown[]) => rpc(...args),
  }),
}))

/** Mutated per test; `useRoute` reads it when the view calls it. */
let currentParams: { id?: string; mode?: string } = {}

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: currentParams }),
  useRouter: () => ({ push: vi.fn() }),
}))

function mountAt(params: { id?: string; mode?: string }) {
  currentParams = params
  return mount(GatewayEditView, {
    global: {
      stubs: {
        GatewayFormView: FormStub,
        AutoGatewayFormView: FormStub,
        RouterLink: true,
      },
    },
  })
}

/**
 * The props the child was handed, or undefined when no form rendered.
 *
 * Read off the found component rather than recorded in the stub's setup, because the view
 * renders once before the gateway loads and again after. Counting mounts would say more about
 * Vue's render schedule than about this view's wiring.
 */
function handed(
  wrapper: ReturnType<typeof mountAt>,
  prop: 'gatewayId' | 'presetProvider',
): string | undefined {
  const found = wrapper.findComponent(FormStub)
  return found.exists() ? (found.props(prop) as string | undefined) : undefined
}

beforeEach(() => {
  rpc.mockReset()
  // A manual row, so the dispatcher picks the manual form unless a test says otherwise.
  rpc.mockResolvedValue({ data: [{ id: GATEWAY_ID, provider: null }], error: null })
})

describe('GatewayEditView', () => {
  it('passes the resolved id to the manual form when editing', async () => {
    const wrapper = mountAt({ id: GATEWAY_ID })
    await flushPromises()

    expect(handed(wrapper, 'gatewayId')).toBe(GATEWAY_ID)
    expect(handed(wrapper, 'presetProvider')).toBeUndefined()
  })

  it('passes the resolved id to the automatic form when editing', async () => {
    rpc.mockResolvedValue({ data: [{ id: GATEWAY_ID, provider: 'bkash' }], error: null })
    const wrapper = mountAt({ id: GATEWAY_ID })
    await flushPromises()

    expect(handed(wrapper, 'gatewayId')).toBe(GATEWAY_ID)
    // The automatic form is the one that was rendered, identified by the prop only it receives.
    expect(handed(wrapper, 'presetProvider')).toBe('bkash')
  })

  /**
   * The regression itself, stated as the failure rather than as the prop.
   *
   * An empty-string id is what the child would put in the payload, and `admin_upsert_gateway`
   * turns exactly that string into an insert. So "not blank" is the assertion that means
   * "update, not duplicate".
   */
  it('never hands the form a blank id, which the database reads as "create"', async () => {
    const wrapper = mountAt({ id: GATEWAY_ID })
    await flushPromises()

    expect(handed(wrapper, 'gatewayId')).not.toBe('')
  })

  /**
   * The id comes from the route, not from the fetched row, so it is correct on the first
   * render too - before the gateway has loaded and while the view still says "Loading".
   *
   * This is the half that was broken before and is easy to reintroduce: reading the id off the
   * row it just fetched would leave a window in which the form mounts believing it is creating.
   */
  it('hands over the route id before the gateway row has loaded', () => {
    const wrapper = mountAt({ id: GATEWAY_ID })

    expect(handed(wrapper, 'gatewayId')).toBe(GATEWAY_ID)
  })

  it('leaves the id unset when creating, so the form still creates', async () => {
    const wrapper = mountAt({ mode: 'manual' })
    await flushPromises()

    expect(handed(wrapper, 'gatewayId') ?? '').toBe('')
  })

  it('renders the chooser only when creating with no mode', async () => {
    const wrapper = mountAt({ mode: '' })
    await flushPromises()

    expect(wrapper.findComponent(FormStub).exists()).toBe(false)
    expect(wrapper.text()).toContain('New payment method')
  })

  it('reports a bad id instead of rendering a form that would create a new one', async () => {
    rpc.mockResolvedValue({ data: [], error: null })
    const wrapper = mountAt({ id: GATEWAY_ID })
    await flushPromises()

    expect(wrapper.text()).toContain('no longer exists')
    expect(wrapper.findComponent(FormStub).exists()).toBe(false)
  })

  it('reports the database error instead of falling through to the chooser', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'permission denied' } })
    const wrapper = mountAt({ id: GATEWAY_ID })
    await flushPromises()

    expect(wrapper.text()).toContain('permission denied')
    expect(wrapper.findComponent(FormStub).exists()).toBe(false)
  })
})
