(() => {
  const boot = document.getElementById("auth-boot");
  const root = document.getElementById("login-root");
  const form = document.getElementById("login-form");
  const userEl = document.getElementById("login-user");
  const passEl = document.getElementById("login-pass");
  const errEl = document.getElementById("login-error");
  const submitEl = document.getElementById("login-submit");
  const togglePw = document.getElementById("login-toggle-pw");
  const asideEl = document.getElementById("login-aside");
  const titleEl = document.getElementById("login-title");
  const subEl = document.querySelector(".login-sub");

  const copy = {
    zh: {
      title: "登录到电脑配置扫描",
      sub: "使用本机账号继续",
      username: "用户名",
      password: "密码",
      show: "显示",
      hide: "隐藏",
      submit: "登录",
      submitting: "登录中…",
      fail: "登录失败",
      network: "网络错误",
      aside: "默认用户 {user}，密码见 config/host.json。删掉其中的 password 后，该默认密码失效。",
      checking: "正在校验会话…",
    },
    en: {
      title: "Sign in to PC configuration",
      sub: "Continue with the local account",
      username: "Username",
      password: "Password",
      show: "Show",
      hide: "Hide",
      submit: "Sign in",
      submitting: "Signing in…",
      fail: "Sign-in failed",
      network: "Network error",
      aside: "Default user {user}. The password is in config/host.json. Remove password there to revoke it.",
      checking: "Checking session…",
    },
  };

  function locale() {
    return localStorage.getItem("ccs.locale") === "en" ? "en" : "zh";
  }
  function t(key, vars) {
    let text = (copy[locale()] || copy.zh)[key] || key;
    if (vars) {
      Object.keys(vars).forEach((name) => {
        text = text.replace("{" + name + "}", vars[name]);
      });
    }
    return text;
  }
  function applyLocale() {
    document.documentElement.lang = locale() === "zh" ? "zh-CN" : "en";
    titleEl.textContent = t("title");
    subEl.textContent = t("sub");
    document.querySelector('[data-k="username"]').textContent = t("username");
    document.querySelector('[data-k="password"]').textContent = t("password");
    if (!submitEl.disabled) submitEl.textContent = t("submit");
    togglePw.textContent = passEl.type === "password" ? t("show") : t("hide");
    const hint = userEl.value || "ccs";
    asideEl.textContent = t("aside", { user: hint });
    const bootP = boot.querySelector("p");
    if (bootP) bootP.textContent = t("checking");
    document.querySelectorAll(".login-lang-btn").forEach((btn) => {
      btn.classList.toggle("active", btn.getAttribute("data-locale") === locale());
    });
  }

  function sanitizeFrom(raw) {
    const value = raw || "/";
    if (!value.startsWith("/") || value.startsWith("//") || value.startsWith("/login")) return "/";
    return value;
  }
  function fromParam() {
    return sanitizeFrom(new URLSearchParams(location.search).get("from") || "/");
  }
  function showError(msg) {
    errEl.hidden = !msg;
    errEl.textContent = msg || "";
  }
  function setBusy(on) {
    submitEl.disabled = on;
    userEl.disabled = on;
    passEl.disabled = on;
    submitEl.textContent = on ? t("submitting") : t("submit");
  }

  document.querySelectorAll(".login-lang-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      localStorage.setItem("ccs.locale", btn.getAttribute("data-locale") || "zh");
      applyLocale();
    });
  });
  togglePw.addEventListener("click", () => {
    const show = passEl.type === "password";
    passEl.type = show ? "text" : "password";
    togglePw.textContent = show ? t("hide") : t("show");
  });
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    showError("");
    setBusy(true);
    try {
      const res = await fetch("/api/auth/login", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username: userEl.value.trim(), password: passEl.value }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || !data.ok) {
        const raw = data.error || "";
        showError(!raw || /^HTTP \d+$/.test(raw) ? t("fail") : raw);
        return;
      }
      location.replace(fromParam());
    } catch (err) {
      showError(err instanceof Error ? err.message : t("network"));
    } finally {
      setBusy(false);
    }
  });

  applyLocale();
  (async () => {
    try {
      const me = await fetch("/api/auth/me", { credentials: "same-origin" }).then((res) => res.json());
      if (!me.authRequired || me.authenticated) {
        location.replace(fromParam());
        return;
      }
      const status = await fetch("/api/auth/status", { credentials: "same-origin" }).then((res) => res.json());
      boot.hidden = true;
      root.hidden = false;
      userEl.value = status.usernameHint || "ccs";
      applyLocale();
    } catch {
      boot.hidden = true;
      root.hidden = false;
      userEl.value = "ccs";
      applyLocale();
    }
  })();
})();
