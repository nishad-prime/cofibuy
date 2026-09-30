import DOMPurify from 'dompurify'
import { marked } from 'marked'

/**
 * Markdown rendering for admin-authored content.
 *
 * Database content is untrusted input, so it is parsed to HTML and then
 * sanitised — never assigned to `v-html` unsanitised. DOMPurify strips script
 * and event handlers by default; the configuration below additionally:
 *
 *  - forces every link to open in a new tab with `rel="noopener noreferrer"`,
 *    which severs the `window.opener` reference a target-controlled page
 *    would otherwise get
 *  - lazy-loads images, so a body with media does not stall first paint
 */

marked.setOptions({ gfm: true, breaks: true })

let hookInstalled = false

function installHook(): void {
  if (hookInstalled) return
  hookInstalled = true

  DOMPurify.addHook('afterSanitizeAttributes', (node) => {
    if (node.tagName === 'A') {
      node.setAttribute('target', '_blank')
      node.setAttribute('rel', 'noopener noreferrer')
    }

    if (node.tagName === 'IMG') {
      node.setAttribute('loading', 'lazy')
      node.setAttribute('decoding', 'async')
    }
  })
}

export function renderMarkdown(source: string | null | undefined): string {
  if (!source) return ''

  installHook()

  const parsed = marked.parse(source, { async: false })
  return DOMPurify.sanitize(parsed, {
    USE_PROFILES: { html: true },
    ADD_ATTR: ['target', 'rel', 'loading', 'decoding'],
  })
}

export { DOMPurify, marked }
