"""Page objects for the admin panel.

The selectors here deliberately avoid bare tag names. The admin layout renders a
language toggle before the sign-in form, so `//button` picks the toggle and the
test silently never submits anything.
"""

from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait
import os

SUBMIT = (By.CSS_SELECTOR, 'form button[type="submit"]')
NAV_LINK = (By.CSS_SELECTOR, "nav a")
HEADING = (By.TAG_NAME, "h1")


class AdminLoginPage:
    EMAIL = (By.ID, "email")
    PASSWORD = (By.ID, "password")
    # `.alert-error`, not `.bg-red-50`: the design-system class composes the red
    # background with `@apply`, which emits styles without putting a `bg-red-50`
    # class on the element.
    ERROR = (By.CSS_SELECTOR, ".alert-error")

    def __init__(self, driver, base_url):
        self.driver = driver
        self.base_url = base_url

    def open(self):
        self.driver.get(f"{self.base_url}/admin/login")

    def submit_credentials(self, email, password):
        WebDriverWait(self.driver, 10).until(EC.presence_of_element_located(self.EMAIL))
        email_input = self.driver.find_element(*self.EMAIL)
        email_input.clear()
        email_input.send_keys(email)

        password_input = self.driver.find_element(*self.PASSWORD)
        password_input.clear()
        password_input.send_keys(password)

        self.driver.find_element(*SUBMIT).click()

    def wait_until_signed_in(self, timeout=30):
        WebDriverWait(self.driver, timeout).until(
            lambda d: "/admin/login" not in d.current_url
        )
        return self.driver.current_url

    def error_message(self):
        try:
            return self.driver.find_element(*self.ERROR).text.strip()
        except Exception:
            return None

    def save(self, directory, name):
        return _save(self.driver, directory, name)


class AdminQueuePage:
    def __init__(self, driver):
        self.driver = driver

    def heading(self):
        return self.driver.find_element(*HEADING).text.strip()

    def body_text(self):
        return self.driver.find_element(By.TAG_NAME, "body").text

    def nav_links(self):
        return [e.text.strip() for e in self.driver.find_elements(*NAV_LINK)]

    def has_login_form(self):
        """The login form must not still be mounted once inside the panel."""
        return len(self.driver.find_elements(*AdminLoginPage.EMAIL)) > 0

    def wait_until_panel_ready(self, timeout=20):
        """Wait for the admin layout and for its page data to settle.

        The route guard awaits the persisted session plus two role probes, so the
        layout mounts well after `document.readyState`. Checking for the absence
        of "Loading..." alone is not enough either: the surrounding app shell has
        no such text either and would match immediately.
        """
        WebDriverWait(self.driver, timeout).until(
            lambda d: len(d.find_elements(*NAV_LINK)) > 0
        )
        WebDriverWait(self.driver, timeout).until_not(
            lambda d: "Loading..." in d.find_element(By.TAG_NAME, "body").text
        )

    def save(self, directory, name):
        return _save(self.driver, directory, name)


def _save(driver, directory, name):
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, name)
    driver.save_screenshot(path)
    return path