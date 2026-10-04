"""Customer-facing smoke flow.

Exercises the path that actually earns money: land on a paywalled link, pick a
payment method, create an order, and land on the order status page. This is a
smoke test, not a full end-to-end test: it stops before uploading evidence and
approving, because approving would mark a real order as paid.
"""

import pytest
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import re

SLUG = "demo-report"

# The seeded link's public copy. Assertions target this content rather than a
# generic marker so a broken teaser read, or an unlock-body leak, is caught.
TITLE = "SSC Exam Strategy Handbook"
TEASER = "A 34-page handbook for students sitting SSC this year"
UNLOCK_BODY = "Read the revision plan first"

needs_anon = pytest.mark.usefixtures("supabase_anon_signin_enabled")


def _require_anon(enabled):
    if not enabled:
        pytest.skip(
            "Supabase anonymous sign-ins are disabled for this project "
            "(Authentication -> Providers -> Email -> Enable anonymous sign-ins). "
            "Orders require an authenticated user, so checkout cannot be exercised."
        )


class TestCustomerLink:
    def test_paywalled_link_renders_teaser_only(self, driver, base_url, shots):
        driver.get(f"{base_url}/{SLUG}?lang=en")

        # The seeded link's teaser is what proves the RPC returned a row at all.
        WebDriverWait(driver, 20).until(
            lambda d: TITLE in d.find_element(By.TAG_NAME, "body").text
        )
        body = driver.find_element(By.TAG_NAME, "body").text

        assert TEASER in body, "teaser missing"
        assert UNLOCK_BODY not in body, "unlocked body leaked before payment"
        driver.save_screenshot(shots + "/10_link_teaser.png")

    @needs_anon
    def test_customer_can_create_an_order(self, driver, base_url, shots, supabase_anon_signin_enabled):
        _require_anon(supabase_anon_signin_enabled)
        driver.get(f"{base_url}/{SLUG}?lang=en")
        WebDriverWait(driver, 20).until(
            lambda d: TITLE in d.find_element(By.TAG_NAME, "body").text
        )

        # Pick the seeded payment method.
        radios = WebDriverWait(driver, 20).until(
            EC.presence_of_all_elements_located((By.CSS_SELECTOR, 'input[type="radio"]'))
        )
        assert radios, "no payment methods rendered; was the seed applied?"
        radios[0].click()

        amount = driver.find_element(By.CSS_SELECTOR, 'input[type="number"]')
        amount.clear()
        amount.send_keys("150")

        driver.find_element(
            By.XPATH, "//button[contains(normalize-space(), 'create order')]"
        ).click()

        # An anonymous sign-in happens here, so this also proves that Supabase
        # anonymous sign-ins are enabled for the project.
        WebDriverWait(driver, 30).until(
            lambda d: re.search(r"/%s/order/[0-9a-f-]{36}" % SLUG, d.current_url)
        )
        url = driver.current_url
        print("order url:", url)

        order_id = url.rstrip("/").rsplit("/", 1)[-1]
        driver.save_screenshot(shots + "/11_order_pending.png")

        body = driver.find_element(By.TAG_NAME, "body").text
        print("order page:", body.strip()[:400])

        assert "Nothing went wrong" not in body, f"order page reported an error: {body[:400]}"
        assert order_id, "no order id in the redirect url"
        return order_id

    @needs_anon
    def test_customer_can_open_their_order_directly(
        self, driver, base_url, shots, supabase_anon_signin_enabled
    ):
        _require_anon(supabase_anon_signin_enabled)
        order_id = TestCustomerLink().test_customer_can_create_an_order(
            driver, base_url, shots, supabase_anon_signin_enabled
        )

        # Reload the order by id: the session is anonymous but must persist, or
        # the ownership check inside create_order_lookup will reject us.
        driver.get(f"{base_url}/{SLUG}/order/{order_id}?lang=en")
        WebDriverWait(driver, 20).until(
            lambda d: "order" in d.find_element(By.TAG_NAME, "body").text.lower()
        )
        body = driver.find_element(By.TAG_NAME, "body").text
        assert "Nothing went wrong" not in body, f"reload lost the order: {body[:400]}"
        driver.save_screenshot(shots + "/12_order_reloaded.png")


class TestCustomerGuards:
    def test_unknown_slug_shows_not_found(self, driver, base_url):
        driver.get(f"{base_url}/no-such-link-abc123?lang=en")
        # An unknown slug matches the `/:slug` route, so the link view itself has
        # to render the not-found state; previously it rendered a blank page.
        WebDriverWait(driver, 20).until(
            lambda d: "Page not found" in d.find_element(By.TAG_NAME, "body").text
        )
        body = driver.find_element(By.TAG_NAME, "body").text
        assert "Demo report" not in body, "an unknown slug rendered the seeded link"
        assert TITLE not in body, "an unknown slug rendered the seeded link"

    def test_customer_cannot_open_admin_panel(self, driver, base_url):
        driver.get(f"{base_url}/admin/queue")
        WebDriverWait(driver, 20).until(
            lambda d: "/admin/login" in d.current_url
        )
        assert len(driver.find_elements(By.ID, "email")) > 0, (
            "an anonymous visitor reached the admin panel"
        )