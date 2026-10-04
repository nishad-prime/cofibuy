import pytest
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from webdriver_manager.chrome import ChromeDriverManager
import os


@pytest.fixture(scope="function")
def driver():
    chrome_options = Options()
    chrome_options.add_argument("--headless=new")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--disable-dev-shm-usage")
    chrome_options.add_argument("--window-size=1920,1080")
    # Required for driver.get_log('browser').
    chrome_options.set_capability("goog:loggingPrefs", {"browser": "ALL"})

    service = Service(ChromeDriverManager().install())
    drv = webdriver.Chrome(service=service, options=chrome_options)
    drv.implicitly_wait(10)
    yield drv
    drv.quit()


@pytest.fixture
def base_url():
    return os.getenv("BASE_URL", "http://localhost:5173")


@pytest.fixture
def admin_email():
    return os.getenv("ADMIN_EMAIL", "endstudeo@gmail.com")


@pytest.fixture
def admin_password():
    return os.getenv("ADMIN_PASSWORD", "kelokelo")


@pytest.fixture
def shots():
    """Absolute path so screenshots do not depend on the invocation cwd."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "screenshots")
    os.makedirs(path, exist_ok=True)
    return path


@pytest.fixture
def login(driver, base_url, admin_email, admin_password):
    """Signs in and lands on the queue, asserting the admin panel rendered."""
    from pages import AdminLoginPage, AdminQueuePage

    login_page = AdminLoginPage(driver, base_url)
    login_page.open()
    login_page.submit_credentials(admin_email, admin_password)
    login_page.wait_until_signed_in()

    return AdminQueuePage(driver)


def _read_env(name):
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env.local")
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line.startswith(name + "="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return os.getenv(name)


@pytest.fixture(scope="session")
def supabase_anon_signin_enabled():
    """Orders require an authenticated user, and the store signs customers in
    anonymously.

    Anonymous sign-ins are a Supabase auth-dashboard setting, not something the
    schema can grant, so probe for it once and let the affected tests skip
    loudly instead of failing on an error the operator has to fix elsewhere.
    """
    import json
    import urllib.error
    import urllib.request

    url = _read_env("VITE_SUPABASE_URL")
    key = _read_env("VITE_SUPABASE_ANON_KEY")
    if not url or not key:
        pytest.skip("no Supabase credentials in .env.local")

    request = urllib.request.Request(
        url + "/auth/v1/signup",
        data=json.dumps({}).encode(),
        headers={
            "Content-Type": "application/json",
            "apikey": key,
            "Authorization": "Bearer " + key,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return True
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        if "Anonymous sign-ins are disabled" in body:
            return False
        # Any other error still means the endpoint is reachable.
        return True
    except Exception:
        pytest.skip("could not reach the Supabase auth endpoint")