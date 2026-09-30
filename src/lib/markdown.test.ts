import { describe, expect, it } from 'vitest'
import { renderMarkdown } from './markdown'

/**
 * Database content is authored by an admin and is therefore untrusted input.
 * These tests pin the properties the customer-facing renderer must hold.
 */
describe('renderMarkdown', () => {
  it('returns an empty string for absent content', () => {
    expect(renderMarkdown(null)).toBe('')
    expect(renderMarkdown(undefined)).toBe('')
    expect(renderMarkdown('')).toBe('')
  })

  it('renders ordinary Markdown', () => {
    expect(renderMarkdown('**bold**')).toContain('<strong>bold</strong>')
    expect(renderMarkdown('# Title')).toContain('<h1')
  })

  it('strips script tags', () => {
    const html = renderMarkdown('hello <script>alert(1)</script>')
    expect(html).not.toContain('<script')
    expect(html).not.toContain('alert(1)')
  })

  it('strips inline event handlers', () => {
    const html = renderMarkdown('<img src=x onerror="alert(1)">')
    expect(html.toLowerCase()).not.toContain('onerror')
  })

  it('strips javascript: URLs', () => {
    const html = renderMarkdown('[click](javascript:alert(1))')
    expect(html.toLowerCase()).not.toContain('javascript:')
  })

  it('strips iframes', () => {
    expect(renderMarkdown('<iframe src="https://evil.example"></iframe>')).not.toContain('<iframe')
  })

  it('forces links to open safely in a new tab', () => {
    const html = renderMarkdown('[x](https://example.com)')
    expect(html).toContain('target="_blank"')
    expect(html).toContain('rel="noopener noreferrer"')
  })

  it('lazy-loads images', () => {
    const html = renderMarkdown('![a](https://example.com/a.png)')
    expect(html).toContain('loading="lazy"')
  })
})
