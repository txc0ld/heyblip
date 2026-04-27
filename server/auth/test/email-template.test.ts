import { describe, it, expect } from "vitest";
import { emailTemplate } from "../src/index";

/**
 * Tests for `emailTemplate(code)` — the branded HTML + plain-text
 * verification email body added under BDEV-419.
 *
 * These are pure-function tests — no Resend mocking required.
 */
describe("emailTemplate", () => {
  it("returns both an html and a text variant", () => {
    const { html, text } = emailTemplate("VK9-ACP");
    expect(typeof html).toBe("string");
    expect(typeof text).toBe("string");
    expect(html.length).toBeGreaterThan(0);
    expect(text.length).toBeGreaterThan(0);
  });

  it("embeds the code in both html and text variants", () => {
    const code = "ABC-123";
    const { html, text } = emailTemplate(code);
    expect(html).toContain(code);
    expect(text).toContain(code);
  });

  it("emits a valid html5 document with viewport + dark-mode meta", () => {
    const { html } = emailTemplate("XYZ-789");
    expect(html).toMatch(/^<!DOCTYPE html>/);
    expect(html).toContain("<html");
    expect(html).toContain('name="viewport"');
    expect(html).toContain('content="light dark"');
  });

  it("uses table-based layout for email-client compatibility", () => {
    const { html } = emailTemplate("ABC-123");
    // No flexbox, no grid — those don't render in Outlook etc.
    expect(html).not.toMatch(/display\s*:\s*flex/i);
    expect(html).not.toMatch(/display\s*:\s*grid/i);
    // Tables present
    expect(html).toContain('<table');
    expect(html).toContain('role="presentation"');
  });

  it("uses HeyBlip branding (not legacy 'Blip' wordmark) and brand purple", () => {
    const { html, text } = emailTemplate("ABC-123");
    expect(html).toContain("HeyBlip");
    expect(text).toContain("HeyBlip");
    // Brand AccentPurple #6600FF appears for the wordmark + code accent.
    expect(html).toContain("#6600FF");
  });

  it("includes the 10-minute expiry note in both variants", () => {
    const { html, text } = emailTemplate("ABC-123");
    expect(html).toContain("10 minutes");
    expect(text).toContain("10 minutes");
  });

  it("includes the support contact in both variants", () => {
    const { html, text } = emailTemplate("ABC-123");
    expect(html).toContain("support@heyblip.au");
    expect(text).toContain("support@heyblip.au");
  });

  it("includes a reassurance line for users who didn't request it", () => {
    const { html, text } = emailTemplate("ABC-123");
    expect(html).toMatch(/didn'?t request/i);
    expect(text).toMatch(/didn'?t request/i);
  });

  it("includes a hidden preheader with the code for inbox preview", () => {
    const { html } = emailTemplate("DEF-456");
    // Preheader is a hidden span shown in the inbox preview line.
    expect(html).toMatch(/display:none/);
    expect(html).toMatch(/visibility:hidden/);
    // The code appears in the preheader so the inbox preview is useful.
    expect(html).toContain("DEF-456");
  });

  it("plain-text variant is materially shorter than html variant", () => {
    const { html, text } = emailTemplate("ABC-123");
    // Plain text should be << html (no markup, no css).
    expect(text.length).toBeLessThan(html.length / 4);
  });

  it("produces stable output for the same input (no random tokens)", () => {
    const a = emailTemplate("ABC-123");
    const b = emailTemplate("ABC-123");
    expect(a.html).toEqual(b.html);
    expect(a.text).toEqual(b.text);
  });
});
