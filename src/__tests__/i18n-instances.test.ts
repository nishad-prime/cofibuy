import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { defineComponent, h } from 'vue'
import { useI18n } from 'vue-i18n'
import { i18n } from '@/i18n'
import { ensureAdminMessages, useAdminI18n } from '@/i18n/admin'

const AdminProbe = defineComponent({
  setup() {
    const { t } = useAdminI18n()
    return () => h('span', t('admin.status.approved'))
  },
})

const CustomerProbe = defineComponent({
  setup() {
    const { t } = useI18n()
    return () => h('span', t('customer.notFound.title'))
  },
})

/**
 * The admin panel resolves `admin.*` through `adminI18n.global` while customer
 * pages resolve `customer.*` through the instance installed on the app.
 *
 * The regression this guards: `useI18n({ instance: adminI18n })` looks correct
 * but vue-i18n ignores the option in the global scope, so it returned the
 * customer composer and every admin key rendered raw. Installing `adminI18n` on
 * the app instead makes it the injected default and breaks customer keys the
 * other way. Both probes therefore mount with only the customer instance, which
 * is how the real app is wired.
 */
describe('i18n instances', () => {
  it('loads the admin bundle on demand', async () => {
    await ensureAdminMessages()
    // Gateway enum values are lowercase, so the key must match the enum.
    expect(useAdminI18n().t('admin.gateways.bkash')).toBe('bKash')
  })

  it('resolves admin keys while the customer instance is the only one installed', async () => {
    await ensureAdminMessages()
    const wrapper = mount(AdminProbe, { global: { plugins: [i18n] } })
    expect(wrapper.text()).toBe('Approved')
  })

  it('still resolves customer keys', async () => {
    await ensureAdminMessages()
    const wrapper = mount(CustomerProbe, { global: { plugins: [i18n] } })
    expect(wrapper.text()).not.toBe('customer.notFound.title')
    expect(wrapper.text().length).toBeGreaterThan(0)
  })
})
