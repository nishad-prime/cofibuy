import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'
import { useAdminGuard } from '@/composables/useAdminGuard'
import { ensureAdminMessages } from '@/i18n/admin'

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    component: () => import('@/layouts/CustomerLayout.vue'),
    children: [
      {
        path: '',
        name: 'home',
        component: () => import('@/views/HomeView.vue'),
      },
      {
        path: ':slug',
        name: 'link',
        component: () => import('@/views/customer/LinkView.vue'),
      },
      {
        path: ':slug/order/:orderId',
        name: 'order',
        component: () => import('@/views/customer/OrderView.vue'),
      },
      {
        path: 'recover',
        name: 'recover',
        component: () => import('@/views/customer/RecoveryRequestView.vue'),
      },
      {
        path: 'recover/verify',
        name: 'recover-verify',
        component: () => import('@/views/customer/RecoveryVerifyView.vue'),
      },
      {
        path: ':pathMatch(.*)*',
        name: 'not-found',
        component: () => import('@/views/NotFoundView.vue'),
      },
    ],
  },
  {
    path: '/admin/login',
    name: 'admin-login',
    component: () => import('@/views/admin/LoginView.vue'),
  },
  {
    path: '/admin',
    component: () => import('@/views/admin/AdminLayout.vue'),
    meta: { requiresStaff: true },
    children: [
      {
        path: '',
        redirect: '/admin/queue',
      },
      {
        path: 'queue',
        name: 'admin-queue',
        component: () => import('@/views/admin/QueueView.vue'),
      },
      {
        path: 'orders/:id',
        name: 'admin-order-detail',
        component: () => import('@/views/admin/OrderDetailView.vue'),
      },
      {
        path: 'links',
        name: 'admin-links',
        component: () => import('@/views/admin/LinksView.vue'),
      },
      {
        path: 'links/new',
        name: 'admin-links-new',
        component: () => import('@/views/admin/LinkFormView.vue'),
      },
      {
        path: 'links/:id/edit',
        name: 'admin-links-edit',
        component: () => import('@/views/admin/LinkFormView.vue'),
      },
      {
        path: 'gateways',
        name: 'admin-gateways',
        component: () => import('@/views/admin/GatewaysView.vue'),
      },
      {
        path: 'gateways/new',
        name: 'admin-gateways-new',
        component: () => import('@/views/admin/GatewayFormView.vue'),
      },
      {
        path: 'gateways/:id/edit',
        name: 'admin-gateways-edit',
        component: () => import('@/views/admin/GatewayFormView.vue'),
      },
      {
        path: 'team',
        name: 'admin-team',
        component: () => import('@/views/admin/TeamView.vue'),
        meta: { requiresOwner: true },
      },
      {
        path: 'settings',
        name: 'admin-settings',
        component: () => import('@/views/admin/SettingsView.vue'),
        meta: { requiresOwner: true },
      },
      {
        // Copy rewrites what the shopfront says, including the text of the
        // buttons that take a payment, so it sits with the other owner-only
        // surfaces rather than with the review queue.
        path: 'copy',
        name: 'admin-copy',
        component: () => import('@/views/admin/CopyView.vue'),
        meta: { requiresOwner: true },
      },
    ],
  },
]

export const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes,
  scrollBehavior(_to, _from, savedPosition) {
    return savedPosition ?? { top: 0 }
  },
})

router.beforeEach(async (to, from, next) => {
  // The admin message bundle is a dynamic import, so it is fetched on the first
  // admin navigation rather than shipping to customers. Awaiting it here means
  // the panel never paints with raw keys.
  if (to.path.startsWith('/admin')) {
    await ensureAdminMessages()
  }

  const { requireStaff, requireOwner } = useAdminGuard()

  if (to.meta.requiresOwner) {
    await requireOwner(to, from, next)
    return
  }

  if (to.meta.requiresStaff) {
    await requireStaff(to, from, next)
    return
  }

  next()
})

export default router
