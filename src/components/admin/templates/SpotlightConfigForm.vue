<template>
  <div class="space-y-6">
    <!--
      Sections in the same order the customer sees them. The spotlight page
      has three content sections, so the whole form fits one screen.
    -->
    <CollapsibleSection
      panel-id="hero"
      :open="openSections['hero'] ?? false"
      @update:open="openSections['hero'] = $event"
      title="Hero"
    >
      <div class="space-y-4">
        <p class="hint">The hero title is the page's own title (set at the top of this form).</p>
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Subtitle (EN)</label>
            <textarea v-model="config.hero_subtitle_en" rows="2" class="field"></textarea>
          </div>
          <div>
            <label class="label">Subtitle (BN)</label>
            <textarea v-model="config.hero_subtitle_bn" rows="2" class="field"></textarea>
          </div>
        </div>
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Hero button (EN)</label>
            <input v-model="config.hero_cta_en" class="field" />
          </div>
          <div>
            <label class="label">Hero button (BN)</label>
            <input v-model="config.hero_cta_bn" class="field" />
          </div>
        </div>

        <p class="hint">
          Optional image. The page is fully typographic without one; assign it on the page's image
          screen if you want a framed visual under the title.
        </p>
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Image alt (EN)</label>
            <input v-model="config.hero_image_alt_en" class="field" />
          </div>
          <div>
            <label class="label">Image alt (BN)</label>
            <input v-model="config.hero_image_alt_bn" class="field" />
          </div>
        </div>
      </div>
    </CollapsibleSection>

    <CollapsibleSection
      panel-id="video"
      :open="openSections['video'] ?? false"
      @update:open="openSections['video'] = $event"
      title="Video"
    >
      <p class="hint mb-3">
        The page's centerpiece: a portrait video (9:16) hosted on Cloudflare R2 or any CDN. Paste
        the public URL.
      </p>
      <label class="label">Video URL</label>
      <input v-model="config.video_url" class="field" placeholder="https://…" />
    </CollapsibleSection>

    <CollapsibleSection
      panel-id="ending"
      :open="openSections['ending'] ?? false"
      @update:open="openSections['ending'] = $event"
      title="Ending"
    >
      <div class="space-y-4">
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Closing title (EN)</label>
            <input v-model="config.ending_title_en" class="field" />
          </div>
          <div>
            <label class="label">Closing title (BN)</label>
            <input v-model="config.ending_title_bn" class="field" />
          </div>
        </div>
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Closing note (EN)</label>
            <textarea v-model="config.ending_note_en" rows="2" class="field"></textarea>
          </div>
          <div>
            <label class="label">Closing note (BN)</label>
            <textarea v-model="config.ending_note_bn" rows="2" class="field"></textarea>
          </div>
        </div>
        <p class="hint">Leave the title empty to reuse the hero title.</p>
      </div>
    </CollapsibleSection>

    <CollapsibleSection
      panel-id="telegram"
      :open="openSections['telegram'] ?? false"
      @update:open="onTelegramOpen"
      title="Telegram delivery"
    >
      <p class="hint mb-3">
        When set, the checkout's post-payment button becomes a Telegram invite link (2 uses). The
        bot must be an admin in the target chat. Leave empty for non-Telegram pages.
      </p>

      <!-- Dropdown from the bot's discovered chats, falling back to a manual input. -->
      <template v-if="telegramChats.length > 0">
        <label class="label">Chat</label>
        <select :value="config.telegram_chat_id" class="field" @change="onChatSelect($event)">
          <option value="">— Select a chat —</option>
          <option v-for="c in telegramChats" :key="c.chat_id" :value="c.chat_id">
            {{ c.title }} ({{ c.type === 'supergroup' ? 'group' : c.type }})
          </option>
        </select>
      </template>
      <template v-else>
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label class="label">Chat ID</label>
            <input v-model="config.telegram_chat_id" class="field" placeholder="-1001234567890" />
          </div>
          <div>
            <label class="label">Chat type</label>
            <select v-model="config.telegram_chat_type" class="field">
              <option value="channel">Channel</option>
              <option value="group">Group</option>
            </select>
          </div>
        </div>
      </template>
      <div class="mt-4">
        <label class="label">Support chat URL (shows a floating TG bubble on the page)</label>
        <input
          v-model="config.telegram_support_url"
          class="field"
          placeholder="https://t.me/yourusername"
        />
      </div>
    </CollapsibleSection>
  </div>
</template>

<script setup lang="ts">
import CollapsibleSection from '@/components/admin/CollapsibleSection.vue'
import { ref } from 'vue'
import { rpc } from '@/lib/rpc'
import type { SpotlightConfig } from '@/pages/templates/registry'

const openSections = ref<Record<string, boolean>>({
  hero: true,
})

const config = defineModel<SpotlightConfig>({ required: true })

interface TgChat {
  chat_id: string
  title: string
  type: string
}

const telegramChats = ref<TgChat[]>([])
const chatsLoaded = ref(false)

async function onTelegramOpen(): Promise<void> {
  openSections.value['telegram'] = !(openSections.value['telegram'] ?? false)
  if (!chatsLoaded.value) {
    const { data } = await rpc<TgChat[]>('telegram_chats')
    if (Array.isArray(data)) {
      telegramChats.value = data
    }
    chatsLoaded.value = true
  }
}

/** Selecting from the dropdown sets both the chat id and the type. */
function onChatSelect(event: Event): void {
  const chatId = (event.target as HTMLSelectElement).value
  config.value.telegram_chat_id = chatId
  const chat = telegramChats.value.find((c) => c.chat_id === chatId)
  if (chat) {
    config.value.telegram_chat_type = chat.type === 'supergroup' ? 'group' : chat.type
  }
}
</script>
