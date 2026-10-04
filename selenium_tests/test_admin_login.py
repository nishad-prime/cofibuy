import os
from pages import AdminLoginPage, AdminQueuePage

# The nav labels and each page's own <h1>. Asserting the per-route heading is
# stronger than the old "heading is always Cofibuy Admin" check: it proves the
# route actually mounted its own view rather than a shared shell.
OWNER_NAV = ["Order queue", "Links", "Payment methods", "Team", "Settings"]

ADMIN_ROUTES = [
    ("/admin/queue", "Order queue"),
    ("/admin/links", "Links"),
    ("/admin/gateways", "Payment methods"),
    ("/admin/team", "Team"),
    ("/admin/settings", "Settings"),
]


class TestAdminLogin:
    def test_login_form_renders(self, driver, base_url, shots):
        page = AdminLoginPage(driver, base_url)
        page.open()
        assert driver.find_element(*page.EMAIL).is_displayed()
        assert driver.find_element(*page.PASSWORD).is_displayed()
        page.save(shots, "01_login_form.png")

    def test_login_rejects_bad_password(self, driver, base_url):
        page = AdminLoginPage(driver, base_url)
        page.open()
        page.submit_credentials("endstudeo@gmail.com", "definitely-not-the-password")
        assert page.error_message(), "expected a visible error for a bad password"
        assert "/admin/login" in driver.current_url

    def test_login_rejects_unknown_user(self, driver, base_url):
        page = AdminLoginPage(driver, base_url)
        page.open()
        page.submit_credentials("nobody@nowhere.invalid", "kelokelo")
        assert page.error_message(), "expected a visible error for an unknown user"
        assert "/admin/login" in driver.current_url

    def test_login_redirects_to_admin_panel(self, driver, base_url, shots):
        """The regression this suite exists for: submit must leave the form."""
        page = AdminLoginPage(driver, base_url)
        page.open()
        page.save(shots, "02_before_submit.png")

        page.submit_credentials("endstudeo@gmail.com", "kelokelo")
        url = page.wait_until_signed_in()
        assert url.rstrip("/").endswith("/admin/queue"), f"unexpected url: {url}"

        queue = AdminQueuePage(driver)
        queue.wait_until_panel_ready()
        queue.save(shots, "03_admin_queue.png")

        # Prove the panel rendered rather than the form lingering behind it.
        assert not queue.has_login_form(), "login form is still mounted"
        assert queue.heading() == "Order queue", f"unexpected heading: {queue.heading()}"

        links = queue.nav_links()
        print("nav links:", links)
        for expected in OWNER_NAV:
            assert expected in links, f"{expected} missing from nav: {links}"


class TestAdminPages:
    def test_every_admin_route_renders_for_owner(self, login, driver, shots):
        """A hard navigation must reproduce the panel, not just an empty shell.

        The route guard awaits the persisted session plus two role probes, so the
        layout mounts well after `document.readyState`. Assert against the
        settled page.
        """
        queue = AdminQueuePage(driver)
        dump = []

        for path, expected_heading in ADMIN_ROUTES:
            driver.get(f"http://localhost:5173{path}")
            assert "/admin/login" not in driver.current_url, f"{path} bounced to the login form"

            queue.wait_until_panel_ready()
            body = queue.body_text()

            assert queue.heading() == expected_heading, (
                f"{path}: heading is {queue.heading()!r}, expected {expected_heading!r}"
            )
            for expected in OWNER_NAV:
                assert expected in queue.nav_links(), f"{path}: nav lost {expected}"
            assert "Sign in" not in body, f"{path} fell back to the login form"
            assert "Loading..." not in body, f"{path} never finished loading"

            # Any red banner is a surfaced RPC failure.
            assert "subquery must return" not in body, f"{path} hit a broken RPC"
            assert "must match expected type" not in body, f"{path} hit an RPC type mismatch"

            # An unresolved translation key means the admin message bundle was not
            # loaded (or the wrong i18n instance answered), and a NaN amount means a
            # view is reading a column the RPC does not return.
            assert "admin." not in body, f"{path} rendered raw admin i18n keys"
            assert "NaN" not in body, f"{path} rendered a NaN amount"

            queue.save(shots, f"04{path.replace('/', '_')}.png")
            dump.append(f"=== {path}\n{body.strip()[:600]}\n")

        with open(os.path.join(shots, "admin_routes.txt"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(dump))

    def test_team_lists_the_owner(self, login, driver):
        """`admin_team` returns `role`; the view used to read fields that never existed."""
        queue = AdminQueuePage(driver)
        driver.get("http://localhost:5173/admin/team")
        queue.wait_until_panel_ready()
        body = queue.body_text()
        assert "endstudeo@gmail.com" in body, "owner email missing from the team table"
        assert "owner" in body.lower(), "owner role missing from the team table"

    def test_settings_form_loads(self, login, driver):
        """`admin_settings` used to raise `subquery must return only one column`.

        The form also bound to `min_amount_minor` and `hide_min`, neither of
        which is a column, so the panel saved nothing and the minimum field came
        up empty. Asserting the rendered value catches both faults, and unlike a
        prose check it survives the label being reworded or translated.
        """
        queue = AdminQueuePage(driver)
        driver.get("http://localhost:5173/admin/settings")
        queue.wait_until_panel_ready()
        body = queue.body_text()
        assert "Save settings" in body, "settings save control missing"

        minimum = driver.find_element("id", "min_amount")
        assert minimum.is_displayed(), "the minimum amount input is missing"
        value = minimum.get_attribute("value")
        assert value not in (None, ""), "the minimum amount input loaded no value"
        assert float(value) >= 0, f"the minimum is not a number: {value!r}"

    def test_gateways_list_shows_evidence_fields(self, login, driver):
        """The seeded bKash method carries the manual evidence schema.

        The keys are what the order evidence form is built from, so they have to
        survive the round trip through `admin_upsert_gateway`.
        """
        queue = AdminQueuePage(driver)
        driver.get("http://localhost:5173/admin/gateways")
        queue.wait_until_panel_ready()
        body = queue.body_text()
        for key in ("trxid", "screenshot"):
            assert key in body, f"evidence field {key} missing from the gateway table: {body[:400]}"

    def test_sign_out_returns_to_login(self, login, driver, shots):
        from selenium.webdriver.common.by import By
        from selenium.webdriver.support.ui import WebDriverWait

        queue = AdminQueuePage(driver)
        queue.wait_until_panel_ready()

        driver.find_element(By.XPATH, "//button[normalize-space()='Sign out']").click()
        WebDriverWait(driver, 20).until(
            lambda d: "/admin/login" in d.current_url
        )
        driver.save_screenshot(os.path.join(shots, "05_signed_out.png"))

        # The session must be gone, so a guarded route must not reopen.
        driver.get("http://localhost:5173/admin/queue")
        WebDriverWait(driver, 20).until(
            lambda d: "/admin/login" in d.current_url
        )