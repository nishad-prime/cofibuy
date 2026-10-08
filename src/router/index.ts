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
        // Where bKash sends the customer back to. The path is fixed in the merchant
        // dashboard and carries only a `paymentID`, so it has to be a route that can find
        // the order for itself. Declared before `:slug` because a link called `payment`
        // would otherwise shadow it.
        path: 'payment/return',
        name: 'payment-return',
        component: () => import('@/views/customer/PaymentReturnView.vue'),
      },
      {
        path: ':slug',
        name: 'page',
        component: () => import('@/views/customer/PageView.vue'),
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
        name: 'admin-dashboard',
        component: () => import('@/views/admin/DashboardView.vue'),
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
      // The old /admin/links paths redirect: URLs an operator has bookmarked,
      // or a stale tab, must not become a 404 after a rename.
      {
        path: 'links',
        redirect: '/admin/pages',
      },
      {
        path: 'links/new',
        redirect: '/admin/pages/new',
      },
      {
        path: 'links/:id/edit',
        redirect: '/admin/pages/:id/edit',
      },
      {
        path: 'pages',
        name: 'admin-pages',
        component: () => import('@/views/admin/PagesView.vue'),
      },
      {
        path: 'pages/new',
        name: 'admin-pages-new',
        component: () => import('@/views/admin/PageFormView.vue'),
      },
      {
        path: 'pages/:id/edit',
        name: 'admin-pages-edit',
        component: () => import('@/views/admin/PageFormView.vue'),
      },
      {
        path: 'gateways',
        name: 'admin-gateways',
        component: () => import('@/views/admin/GatewaysView.vue'),
      },
      // One component behind three paths: `gateways/new` asks which kind of method this is,
      // `gateways/new/:mode` is that choice already made, and `gateways/:id/edit` reads the
      // stored provider off the row. Keeping the decision here means neither form has to
      // know it can also be reached another way.
      {
        path: 'gateways/new/:mode(manual|automatic)',
        name: 'admin-gateways-new-mode',
        component: () => import('@/views/admin/GatewayEditView.vue'),
      },
      {
        path: 'gateways/new',
        name: 'admin-gateways-new',
        component: () => import('@/views/admin/GatewayEditView.vue'),
      },
      {
        path: 'gateways/:id/edit',
        name: 'admin-gateways-edit',
        component: () => import('@/views/admin/GatewayEditView.vue'),
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
        // The model provider's credential is a secret the shop spends, not one of
        // its own, so it is owner-only in the same way and for the same reason as
        // the credential pages under /admin/gateways.
        path: 'ai',
        name: 'admin-ai',
        component: () => import('@/views/admin/AiSettingsView.vue'),
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
