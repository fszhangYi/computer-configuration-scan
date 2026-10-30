(() => {
  const boot = document.getElementById("boot");
  const app = document.getElementById("app");
  const hostMeta = document.getElementById("hostMeta");
  const outDir = document.getElementById("outDir");
  const settingsMsg = document.getElementById("settingsMsg");
  const runHint = document.getElementById("runHint");
  const tabs = document.getElementById("tabs");
  const panel = document.getElementById("panel");
  const btnScan = document.getElementById("btnScan");
  const btnDownload = document.getElementById("btnDownload");
  const btnApply = document.getElementById("btnApply");
  const btnExit = document.getElementById("btnExit");
  const btnLogout = document.getElementById("btnLogout");

  const state = { sheets: [], active: 0, page: 0, filter: "", pageSize: 40, reportName: "" };
  let lastStatus = {};

  const statState = document.getElementById("statState");
  const statSheets = document.getElementById("statSheets");
  const statRows = document.getElementById("statRows");
  const statFile = document.getElementById("statFile");

  function goLogin() {
    const from = location.pathname + location.search + location.hash;
    location.replace("/login?from=" + encodeURIComponent(from.startsWith("/") ? from : "/"));
  }

  async function api(path, options) {
    const res = await fetch(path, Object.assign({ credentials: "same-origin" }, options || {}));
    if (res.status === 401) {
      goLogin();
      throw new Error("unauthorized");
    }
    const type = res.headers.get("content-type") || "";
    if (type.includes("json")) {
      const data = await res.json();
      if (!res.ok && data && data.error) throw new Error(data.error);
      return data;
    }
    if (!res.ok) throw new Error("HTTP " + res.status);
    return res;
  }

  function renderSheet() {
    const sheet = state.sheets[state.active];
    if (!sheet) {
      panel.innerHTML =
        '<div class="empty-state">' +
        '<div class="empty-mark" aria-hidden="true"></div>' +
        "<h2>还没有工作簿</h2>" +
        "<p>点击「开始扫描」，采集处理器、硬盘、显卡和已装软件。</p>" +
        "</div>";
      return;
    }
    const headers = sheet.headers || [];
    const isKv = headers[0] === "项目" && headers[1] === "值";
    if (isKv) {
      const cards = (sheet.rows || [])
        .filter((row) => !state.filter || (row.join(" ")).toLowerCase().includes(state.filter))
        .map((row) => "<div><span>" + escapeHtml(row[0] || "") + "</span><b>" + escapeHtml(row[1] || "") + "</b></div>")
        .join("");
      panel.innerHTML =
        '<div class="toolbar"><input id="filter" placeholder="筛选当前表" value="' + escapeAttr(state.filter) + '" /></div>' +
        '<div class="kv">' + (cards || '<p class="empty">没有符合筛选的项</p>') + "</div>";
    } else {
      const filtered = (sheet.rows || []).filter((row) => !state.filter || row.join(" ").toLowerCase().includes(state.filter));
      const pages = Math.max(1, Math.ceil(filtered.length / state.pageSize));
      if (state.page >= pages) state.page = pages - 1;
      const slice = filtered.slice(state.page * state.pageSize, (state.page + 1) * state.pageSize);
      const head = "<tr>" + headers.map((cell) => "<th>" + escapeHtml(cell) + "</th>").join("") + "</tr>";
      const body = slice
        .map((row) => "<tr>" + headers.map((_, index) => "<td>" + escapeHtml(row[index] || "") + "</td>").join("") + "</tr>")
        .join("");
      const pager = pages > 1
        ? '<div class="pager"><button type="button" id="prev">上一页</button><span>' +
          (state.page + 1) + " / " + pages + " · " + filtered.length + " 行</span>" +
          '<button type="button" id="next">下一页</button></div>'
        : '<div class="pager"><span>' + filtered.length + " 行</span></div>";
      panel.innerHTML =
        '<div class="toolbar"><input id="filter" placeholder="筛选当前表" value="' + escapeAttr(state.filter) + '" /></div>' +
        '<div class="table-wrap"><table><thead>' + head + "</thead><tbody>" +
        (body || '<tr><td class="empty" colspan="' + headers.length + '">没有符合筛选的行</td></tr>') +
        "</tbody></table></div>" + pager;
      const prev = document.getElementById("prev");
      const next = document.getElementById("next");
      if (prev) prev.onclick = () => { if (state.page > 0) { state.page -= 1; renderSheet(); } };
      if (next) next.onclick = () => { if (state.page + 1 < pages) { state.page += 1; renderSheet(); } };
    }
    const filter = document.getElementById("filter");
    if (filter) {
      filter.addEventListener("input", () => {
        state.filter = filter.value.trim().toLowerCase();
        state.page = 0;
        renderSheet();
        const again = document.getElementById("filter");
        if (again) { again.focus(); again.setSelectionRange(again.value.length, again.value.length); }
      });
    }
  }

  function renderTabs() {
    tabs.innerHTML = "";
    state.sheets.forEach((sheet, index) => {
      const btn = document.createElement("button");
      btn.type = "button";
      const count = sheet.count || (sheet.rows ? sheet.rows.length : 0);
      btn.innerHTML = '<span class="tab-name">' + escapeHtml(sheet.name) + "</span>" +
        (count ? '<span class="tab-count">' + count + "</span>" : "");
      btn.className = index === state.active ? "active" : "";
      if (index === state.active) btn.setAttribute("aria-current", "true");
      btn.addEventListener("click", () => {
        state.active = index;
        state.page = 0;
        state.filter = "";
        renderTabs();
        renderSheet();
      });
      tabs.appendChild(btn);
    });
  }

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }
  function escapeAttr(value) {
    return escapeHtml(value).replace(/"/g, "&quot;");
  }

  async function loadReport() {
    const data = await api("/api/report");
    if (!data.ok) {
      state.sheets = [];
      state.reportName = "";
      btnDownload.hidden = true;
      paintChrome(lastStatus);
      renderTabs();
      renderSheet();
      return;
    }
    state.sheets = data.sheets || [];
    state.reportName = data.name || "";
    btnDownload.hidden = !state.reportName;
    paintChrome(lastStatus);
    renderTabs();
    renderSheet();
  }

  function paintChrome(status) {
    const scanning = !!(status && status.scanning);
    const failed = !!(status && status.error);
    app.classList.toggle("is-scanning", scanning);
    hostMeta.textContent = scanning ? "采集中" : (state.reportName ? "已载入" : "本机");
    hostMeta.title = state.reportName || "";
    const rows = state.sheets.reduce((sum, sheet) => sum + (sheet.count || (sheet.rows ? sheet.rows.length : 0)), 0);
    statSheets.textContent = state.sheets.length ? String(state.sheets.length) : "—";
    statRows.textContent = rows ? String(rows) : "—";
    statFile.textContent = state.reportName || "还没有结果";
    statFile.title = state.reportName || "";
    if (scanning) {
      statState.textContent = "扫描中";
      statState.dataset.tone = "scan";
      runHint.className = "run-hint is-scan";
    } else if (failed) {
      statState.textContent = "失败";
      statState.dataset.tone = "bad";
      runHint.className = "run-hint is-error";
    } else if (state.reportName) {
      statState.textContent = "就绪";
      statState.dataset.tone = "ok";
      runHint.className = "run-hint";
    } else {
      statState.textContent = "待命";
      statState.dataset.tone = "";
      runHint.className = "run-hint";
    }
  }

  async function refreshStatus() {
    const status = await api("/api/status");
    lastStatus = status;
    if (outDir && document.activeElement !== outDir) outDir.value = status.outputDir || "";
    btnScan.disabled = !!status.scanning;
    btnScan.textContent = status.scanning ? "扫描中…" : "开始扫描";
    if (status.scanning) runHint.textContent = "正在采集本机配置，服务与已装软件会多花一些时间。";
    else if (status.error) runHint.textContent = status.error;
    else if (status.reportName) runHint.textContent = "最近一次工作簿已打开，可按工作表查看或下载。";
    else runHint.textContent = "扫描由本机脚本执行，结果写入 xlsx。";
    paintChrome(status);
    return status;
  }

  btnScan.addEventListener("click", async () => {
    btnScan.disabled = true;
    runHint.textContent = "正在启动扫描…";
    try {
      await api("/api/scan", { method: "POST" });
      const timer = setInterval(async () => {
        try {
          const status = await refreshStatus();
          if (!status.scanning) {
            clearInterval(timer);
            await loadReport();
          }
        } catch {
          clearInterval(timer);
        }
      }, 1000);
    } catch (err) {
      runHint.textContent = err instanceof Error ? err.message : String(err);
      btnScan.disabled = false;
    }
  });

  btnDownload.addEventListener("click", async () => {
    const res = await fetch("/api/report/file", { credentials: "same-origin" });
    if (res.status === 401) { goLogin(); return; }
    if (!res.ok) { runHint.textContent = "没有可下载的工作簿"; return; }
    const blob = await res.blob();
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = state.reportName || "电脑配置.xlsx";
    link.click();
    URL.revokeObjectURL(url);
  });

  btnLogout.addEventListener("click", async () => {
    await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" });
    location.replace("/login");
  });

  btnExit.addEventListener("click", async () => {
    if (!confirm("安全退出将结束本程序。正在进行的扫描会被中断。")) return;
    btnExit.disabled = true;
    runHint.textContent = "正在退出…";
    try {
      await fetch("/api/shutdown", { method: "POST", credentials: "same-origin" });
      runHint.textContent = "退出已发出";
    } catch {
      runHint.textContent = "退出已发出";
    }
  });

  btnApply.addEventListener("click", async () => {
    const path = (outDir.value || "").trim();
    if (!path) { settingsMsg.textContent = "请填写导出目录"; return; }
    if (!confirm("切换到\n" + path + "\n并重启后端？当前登录会失效。")) return;
    btnApply.disabled = true;
    settingsMsg.textContent = "正在重启…";
    try {
      const data = await api("/api/runtime/apply-config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: path }),
      });
      if (!data.ok) {
        settingsMsg.textContent = data.error || "重启失败";
        btnApply.disabled = false;
        return;
      }
      const started = Date.now();
      const poll = async () => {
        if (Date.now() - started > 45000) {
          settingsMsg.textContent = "重启超时，请查看终端日志";
          btnApply.disabled = false;
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, 800));
        try {
          const health = await fetch("/api/health", { cache: "no-store", credentials: "same-origin" });
          if (health.ok) {
            location.reload();
            return;
          }
        } catch { /* process is restarting */ }
        poll();
      };
      poll();
    } catch (err) {
      settingsMsg.textContent = err instanceof Error ? err.message : String(err);
      btnApply.disabled = false;
    }
  });

  (async () => {
    try {
      const me = await fetch("/api/auth/me", { credentials: "same-origin" }).then((res) => res.json());
      if (me.authRequired && !me.authenticated) {
        goLogin();
        return;
      }
      boot.hidden = true;
      app.hidden = false;
      await refreshStatus();
      await loadReport();
    } catch {
      goLogin();
    }
  })();
})();
